use crate::{Error, FaceDetection, Image, Point};
use ort::session::{RunOptions, Session, SessionOutputs};
use ort::value::{Outlet, Tensor, TensorElementType};

#[path = "face_detector_input.rs"]
mod input;

const SCORE_THRESHOLD: f32 = 0.9;
const NMS_THRESHOLD: f32 = 0.3;
const TOP_K: usize = 5000;
const MAX_ABSOLUTE_COORDINATE: f32 = (1 << 20) as f32;
const STRIDES: [usize; 3] = [8, 16, 32];
const HEADS: [[&str; 4]; 3] = [
    ["cls_8", "obj_8", "bbox_8", "kps_8"],
    ["cls_16", "obj_16", "bbox_16", "kps_16"],
    ["cls_32", "obj_32", "bbox_32", "kps_32"],
];
const COMPONENTS: [usize; 4] = [1, 1, 4, 10];

struct Face {
    bounds: [f32; 4],
    landmarks: [[f32; 2]; 5],
    score: f32,
}

/// The frozen graph declares symbolic H/W and candidate counts. ORT 1.27 retains the old
/// 640-square head counts as inferred metadata. Each run validates the concrete output sizes.
pub(crate) fn matches_session(session: &Session) -> bool {
    let [input] = session.inputs() else {
        return false;
    };
    let outputs = session.outputs();
    matches_tensor(input, "input", [1, 3, -1, -1])
        && outputs.len() == HEADS.len() * COMPONENTS.len()
        && STRIDES.into_iter().zip(HEADS).all(|(stride, group)| {
            let inferred_locations = (640 / stride).pow(2) as i64;
            group.iter().zip(COMPONENTS).all(|(&name, components)| {
                let components = components as i64;
                outputs.iter().any(|head| {
                    matches_tensor(head, name, [1, -1, components])
                        || matches_tensor(head, name, [1, inferred_locations, components])
                })
            })
        })
}

fn matches_tensor(outlet: &Outlet, name: &str, shape: impl AsRef<[i64]>) -> bool {
    outlet.name() == name
        && outlet.dtype().tensor_type() == Some(TensorElementType::Float32)
        && outlet
            .dtype()
            .tensor_shape()
            .is_some_and(|value| &**value == shape.as_ref())
}

pub(crate) fn detect(
    session: &mut Session,
    image: &Image<'_>,
    options: &RunOptions,
    check: impl Fn() -> Result<(), Error>,
) -> Result<Vec<FaceDetection>, Error> {
    let input::DetectorInput {
        width,
        height,
        padded_width,
        padded_height,
        data,
    } = input::prepare(image, &check)?;
    let shape = [1, 3, padded_height as i64, padded_width as i64];
    let tensor = Tensor::from_array((shape, data)).map_err(|_| Error::InferenceFailed)?;
    check()?;
    let outputs = session.run_with_options(ort::inputs!["input" => tensor], options);
    check()?;
    let outputs = outputs.map_err(|_| Error::InferenceFailed)?;
    let faces = decode(&outputs, padded_width, padded_height, &check)?;
    let selected = suppress(faces, &check)?;
    normalized(selected, image.width, image.height, width, height, &check)
}

fn decode(
    outputs: &SessionOutputs<'_>,
    width: usize,
    height: usize,
    check: &impl Fn() -> Result<(), Error>,
) -> Result<Vec<Face>, Error> {
    if outputs.len() != HEADS.len() * COMPONENTS.len() {
        return Err(Error::ModelRejected);
    }
    let mut faces = Vec::new();
    for (stride, names) in STRIDES.into_iter().zip(HEADS) {
        let columns = width / stride;
        let rows = height / stride;
        let [cls, obj, boxes, landmarks] = heads(outputs, names, columns * rows, check)?;
        for y in 0..rows {
            check()?;
            for x in 0..columns {
                let index = y * columns + x;
                let score = (cls[index].clamp(0., 1.) * obj[index].clamp(0., 1.)).sqrt();
                if score < SCORE_THRESHOLD {
                    continue;
                }
                let dimensions = &boxes[index * 4..][..4];
                let (x, y, scale) = (x as f32, y as f32, stride as f32);
                let center_x = (x + dimensions[0]) * scale;
                let center_y = (y + dimensions[1]) * scale;
                let width = dimensions[2].exp() * scale;
                let height = dimensions[3].exp() * scale;
                let bounds = [center_x - width / 2., center_y - height / 2., width, height];
                let landmarks = std::array::from_fn(|point| {
                    let start = index * 10 + point * 2;
                    [
                        (landmarks[start] + x) * scale,
                        (landmarks[start + 1] + y) * scale,
                    ]
                });
                if !bounds
                    .iter()
                    .chain(landmarks.iter().flatten())
                    .all(|value| value.is_finite() && value.abs() < MAX_ABSOLUTE_COORDINATE)
                {
                    return Err(Error::InferenceFailed);
                }
                faces.push(Face {
                    bounds,
                    landmarks,
                    score,
                });
            }
        }
    }
    Ok(faces)
}

fn heads<'a>(
    outputs: &'a SessionOutputs<'_>,
    names: [&str; 4],
    count: usize,
    check: &impl Fn() -> Result<(), Error>,
) -> Result<[&'a [f32]; 4], Error> {
    let mut slices: [&[f32]; 4] = [&[]; 4];
    for ((slot, name), components) in slices.iter_mut().zip(names).zip(COMPONENTS) {
        check()?;
        let value = outputs.get(name).ok_or(Error::ModelRejected)?;
        let (shape, data) = value
            .try_extract_tensor::<f32>()
            .map_err(|_| Error::ModelRejected)?;
        if &**shape != [1, count as i64, components as i64] || data.len() != count * components {
            return Err(Error::ModelRejected);
        }
        for chunk in data.chunks(1024) {
            check()?;
            if !chunk.iter().all(|value| value.is_finite()) {
                return Err(Error::InferenceFailed);
            }
        }
        *slot = data;
    }
    Ok(slices)
}

#[derive(Clone, Copy)]
struct IntegerBox([i64; 4]);

impl IntegerBox {
    fn new(bounds: [f32; 4]) -> Self {
        // Rect2i truncates each field towards zero before overlap is calculated.
        Self(bounds.map(|coordinate| coordinate as i64))
    }

    fn overlap(self, other: Self) -> f32 {
        let [ax, ay, aw, ah] = self.0;
        let [bx, by, bw, bh] = other.0;
        let area = aw * ah + bw * bh;
        if area == 0 {
            return 1.;
        }
        let intersection = ((ax + aw).min(bx + bw) - ax.max(bx)).max(0)
            * ((ay + ah).min(by + bh) - ay.max(by)).max(0);
        // OpenCV converts Jaccard distance to F32, then subtracts it from one.
        1. - (1. - intersection as f64 / (area - intersection) as f64) as f32
    }
}

fn suppress(
    mut faces: Vec<Face>,
    check: &impl Fn() -> Result<(), Error>,
) -> Result<Vec<Face>, Error> {
    check()?;
    // A lone candidate exactly on the detector threshold skips OpenCV's stricter NMS filter.
    if faces.len() < 2 {
        return Ok(faces);
    }
    faces.retain(|face| face.score > SCORE_THRESHOLD);
    faces.sort_by(|a, b| b.score.total_cmp(&a.score));
    faces.truncate(TOP_K);
    let mut selected = Vec::<(IntegerBox, Face)>::new();
    for face in faces {
        check()?;
        let bounds = IntegerBox::new(face.bounds);
        if selected
            .iter()
            .all(|(earlier, _)| bounds.overlap(*earlier) <= NMS_THRESHOLD)
        {
            selected.push((bounds, face));
        }
    }
    check()?;
    Ok(selected.into_iter().map(|(_, face)| face).collect())
}

fn normalized(
    mut faces: Vec<Face>,
    width: usize,
    height: usize,
    resized_width: usize,
    resized_height: usize,
    check: &impl Fn() -> Result<(), Error>,
) -> Result<Vec<FaceDetection>, Error> {
    // Preserve the worker's stable (F32 x, F32 y) order before clipping or scaling.
    faces.sort_by(|a, b| {
        a.bounds[0]
            .partial_cmp(&b.bounds[0])
            .unwrap()
            .then_with(|| a.bounds[1].partial_cmp(&b.bounds[1]).unwrap())
    });
    let (width, height) = (width as f64, height as f64);
    let x_scale = (width / resized_width as f64) as f32;
    let y_scale = (height / resized_height as f64) as f32;
    let to_unit_x = |coordinate: f64| (coordinate / width).clamp(0., 1.);
    let to_unit_y = |coordinate: f64| (coordinate / height).clamp(0., 1.);
    let mut result = Vec::with_capacity(faces.len());
    for face in faces {
        check()?;
        // The old worker rescales the detector's F32 slice in-place, then normalizes in F64.
        let [x, y, w, h] = face.bounds;
        let (x, w) = (f64::from(x * x_scale), f64::from(w * x_scale));
        let (y, h) = (f64::from(y * y_scale), f64::from(h * y_scale));
        let (left, right) = (to_unit_x(x), to_unit_x(x + w));
        let (top, bottom) = (to_unit_y(y), to_unit_y(y + h));
        if left >= right || top >= bottom {
            continue;
        }
        result.push(FaceDetection {
            bounds: [left, top, right - left, bottom - top],
            landmarks: face.landmarks.map(|[x, y]| Point {
                x: to_unit_x(f64::from(x * x_scale)),
                y: to_unit_y(f64::from(y * y_scale)),
            }),
            confidence: f64::from(face.score),
        });
    }
    check()?;
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::PixelFormat;
    use std::cell::Cell;

    fn face(bounds: [f32; 4], score: f32) -> Face {
        Face {
            bounds,
            score,
            landmarks: [[-3., 900.]; 5],
        }
    }

    #[test]
    fn lone_threshold_equal_candidate_survives_but_multiple_candidates_use_strict_nms_score() {
        let first = [0., 0., 4., 4.];
        let second = [20., 20., 4., 4.];
        assert_eq!(
            suppress(vec![face(first, SCORE_THRESHOLD)], &|| Ok(()))
                .unwrap()
                .len(),
            1
        );
        let faces = suppress(
            vec![face(first, SCORE_THRESHOLD), face(second, 0.95)],
            &|| Ok(()),
        )
        .unwrap();
        assert_eq!(faces.len(), 1);
        assert_eq!(faces[0].bounds, second);
        assert!(
            suppress(
                vec![face(first, SCORE_THRESHOLD), face(second, SCORE_THRESHOLD)],
                &|| Ok(())
            )
            .unwrap()
            .is_empty()
        );
    }

    #[test]
    fn nms_truncates_boxes_and_keeps_overlap_exactly_on_threshold() {
        let first = [1.9, 0., 4., 4.];
        let second = [4.01, 0., 4., 4.];
        let admitted = suppress(vec![face(first, 1.), face(second, 1.)], &|| Ok(())).unwrap();
        assert_eq!(admitted.len(), 2);

        let first = [0., 0., 3., 10.];
        let second = [0., 0., 10., 10.];
        assert_eq!(
            IntegerBox::new(first).overlap(IntegerBox::new(second)),
            NMS_THRESHOLD
        );
        assert_eq!(
            suppress(vec![face(first, 1.), face(second, 1.)], &|| Ok(()))
                .unwrap()
                .len(),
            2
        );
    }

    #[test]
    fn equal_scores_preserve_model_order_before_top_k_and_nms() {
        let first = [0.3, 0., 4., 4.];
        let mut candidates = vec![face(first, 0.95)];
        candidates.extend((1..TOP_K).map(|_| face([0.7, 0., 4., 4.], 0.95)));
        candidates.push(face([40., 40., 4., 4.], 0.95));
        let admitted = suppress(candidates, &|| Ok(())).unwrap();
        assert_eq!(admitted.len(), 1);
        assert_eq!(admitted[0].bounds, first);
    }

    #[test]
    fn raw_xy_order_precedes_clip_and_coordinates_use_resized_unpadded_domain() {
        let faces = vec![
            face([-1., 10., 9., 10.], 0.91),
            face([-3., 30., 8., 15.], 0.92),
            face([-9., 10., 1., 10.], 1.),
            face([-3., 20., 8., 15.], 0.93),
        ];
        let result = normalized(faces, 1365, 2048, 682, 1024, &|| Ok(())).unwrap();
        assert_eq!(result.len(), 3);
        assert_eq!(result[0].confidence, f64::from(0.93_f32));
        assert_eq!(result[1].confidence, f64::from(0.92_f32));
        assert_eq!(result[2].confidence, f64::from(0.91_f32));
        assert_eq!(result[0].bounds[0], 0.);
        assert_eq!(result[0].bounds[1], 20. / 1024.);
        let legacy_scale = (1365_f64 / 682.) as f32;
        assert_eq!(
            result[0].bounds[2],
            (f64::from(-3. * legacy_scale) + f64::from(8. * legacy_scale)) / 1365.
        );
        assert_eq!(result[0].landmarks[0].x, 0.);
        assert_eq!(result[0].landmarks[0].y, 900. / 1024.);
    }

    #[test]
    fn both_upright_layouts_produce_unscaled_bgr_with_zero_padding() {
        for (format, pixels) in [
            (
                PixelFormat::Rgba8,
                [1, 2, 3, 0, 4, 5, 6, 0, 99, 7, 8, 9, 0, 10, 11, 12, 0],
            ),
            (
                PixelFormat::Bgra8,
                [3, 2, 1, 0, 6, 5, 4, 0, 99, 9, 8, 7, 0, 12, 11, 10, 0],
            ),
        ] {
            let image = Image {
                format,
                data: &pixels,
                width: 2,
                height: 2,
                stride: 9,
            };
            let prepared = input::prepare(&image, || Ok(())).unwrap();
            assert_eq!((prepared.width, prepared.height), (2, 2));
            assert_eq!((prepared.padded_width, prepared.padded_height), (32, 32));
            for (plane, expected) in [[3., 6., 9., 12.], [2., 5., 8., 11.], [1., 4., 7., 10.]]
                .into_iter()
                .enumerate()
            {
                let plane = &prepared.data[plane * 1024..][..1024];
                assert_eq!([plane[0], plane[1], plane[32], plane[33]], expected);
                assert!(
                    plane
                        .iter()
                        .enumerate()
                        .all(|(i, &value)| [0, 1, 32, 33].contains(&i) || value == 0.)
                );
            }
        }
    }

    #[test]
    fn cancellation_is_honored_inside_image_and_nms_traversal() {
        let count = Cell::new(0);
        let check = || {
            count.set(count.get() + 1);
            if count.get() > 2 {
                Err(Error::Cancelled)
            } else {
                Ok(())
            }
        };
        let image = Image {
            format: PixelFormat::Rgba8,
            data: &[0; 16],
            width: 2,
            height: 2,
            stride: 8,
        };
        assert!(matches!(
            input::prepare(&image, check),
            Err(Error::Cancelled)
        ));
        count.set(0);
        let faces = vec![face([0., 0., 4., 4.], 1.), face([40., 40., 4., 4.], 1.)];
        assert!(matches!(suppress(faces, &check), Err(Error::Cancelled)));
    }
}
