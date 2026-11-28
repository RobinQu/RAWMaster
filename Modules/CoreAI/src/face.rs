use crate::{Error, Image, PixelFormat, Point};

const CHIP_SIZE: usize = 128;
const CHIP_PIXELS: usize = CHIP_SIZE * CHIP_SIZE;
const TEMPLATE: [[f64; 2]; 5] = [
    [0.3155687500000000, 0.4615741071428571],
    [0.6826229166666667, 0.4615741071428571],
    [0.5002624999999999, 0.6405053571428571],
    [0.3494718750000000, 0.8246919642857142],
    [0.6534364583333333, 0.8246919642857142],
];

/// Produce Intel 0095's planar BGR Float32 input from the upright image.
pub(crate) fn aligned_input(
    image: &Image<'_>,
    landmarks: &[Point; 5],
    check: impl Fn() -> Result<(), Error>,
) -> Result<Vec<f32>, Error> {
    check()?;
    let inverse = inverse_similarity(image, landmarks)?;
    let x_offsets: [[i64; 2]; CHIP_SIZE] = std::array::from_fn(|x| {
        [
            affine_fixed(inverse[0][0] * x as f64),
            affine_fixed(inverse[1][0] * x as f64),
        ]
    });
    let channels = match image.format {
        PixelFormat::Rgba8 => [2, 1, 0],
        PixelFormat::Bgra8 => [0, 1, 2],
    };
    let mut output = vec![0.0; 3 * CHIP_PIXELS];
    for y in 0..CHIP_SIZE {
        check()?;
        let row_x = affine_fixed(inverse[0][1] * y as f64 + inverse[0][2]).saturating_add(16);
        let row_y = affine_fixed(inverse[1][1] * y as f64 + inverse[1][2]).saturating_add(16);
        for (x, &[dx, dy]) in x_offsets.iter().enumerate() {
            let source_x = row_x.saturating_add(dx) >> 5;
            let source_y = row_y.saturating_add(dy) >> 5;
            let source = bilinear(image, source_x, source_y);
            let offset = y * CHIP_SIZE + x;
            for (plane, channel) in channels.into_iter().enumerate() {
                output[plane * CHIP_PIXELS + offset] = f32::from(source[channel]);
            }
        }
    }
    check()?;
    Ok(output)
}

fn inverse_similarity(image: &Image<'_>, landmarks: &[Point; 5]) -> Result<[[f64; 3]; 2], Error> {
    let mut source = [[0.0; 2]; 5];
    let target = TEMPLATE.map(|point| point.map(|value| value * CHIP_SIZE as f64));
    let mut source_center = [0.0; 2];
    let mut target_center = [0.0; 2];
    for ((source, target), point) in source.iter_mut().zip(&target).zip(landmarks) {
        if !(0.0..=1.0).contains(&point.x) || !(0.0..=1.0).contains(&point.y) {
            return Err(Error::InvalidLandmarks);
        }
        *source = [point.x * image.width as f64, point.y * image.height as f64];
        for axis in 0..2 {
            source_center[axis] += source[axis];
            target_center[axis] += target[axis];
        }
    }
    source_center = source_center.map(|value| value / 5.0);
    target_center = target_center.map(|value| value / 5.0);

    let mut variance = 0.0;
    let mut covariance = [[0.0; 2]; 2];
    for ([x, y], [u, v]) in source.into_iter().zip(target) {
        let x = x - source_center[0];
        let y = y - source_center[1];
        let u = u - target_center[0];
        let v = v - target_center[1];
        variance += x * x + y * y;
        covariance[0][0] += x * u;
        covariance[0][1] += x * v;
        covariance[1][0] += y * u;
        covariance[1][1] += y * v;
    }
    if !variance.is_finite() || variance < 1.0 {
        return Err(Error::InvalidLandmarks);
    }
    let [[xx, xy], [yx, yy]] = covariance;
    let real = xx + yy;
    let imaginary = xy - yx;
    let proper = real.hypot(imaginary);
    let reflected = (xx - yy).hypot(xy + yx);
    let largest = (proper + reflected) * 0.5;
    if largest == 0.0 || (xx * yy - xy * yx).abs() / largest <= largest * 1e-6 {
        return Err(Error::InvalidLandmarks);
    }
    // This closed form gives the same orientation-preserving fit as the SVD with
    // the determinant correction. Reflection contributes to the rank test, but
    // the fitted forward matrix is always [a, -b; b, a].
    let a = real / variance;
    let b = imaginary / variance;
    let tx = target_center[0] - (a * source_center[0] - b * source_center[1]);
    let ty = target_center[1] - (b * source_center[0] + a * source_center[1]);
    let determinant = a * a + b * b;
    if determinant <= 0.0 || !determinant.is_finite() || proper <= largest * 1e-12 {
        return Err(Error::InvalidLandmarks);
    }
    let reciprocal = determinant.recip();
    let a = a * reciprocal;
    let b = b * reciprocal;
    Ok([[a, b, -a * tx - b * ty], [-b, a, b * tx - a * ty]])
}

// OpenCV quantizes the row and column terms separately at 10 bits, then
// rounds their sum to the 5-bit fraction used by the bilinear lookup.
fn affine_fixed(value: f64) -> i64 {
    (value * 1024.0).round_ties_even() as i64
}

fn bilinear(image: &Image<'_>, x: i64, y: i64) -> [u8; 3] {
    let column = x >> 5;
    let row = y >> 5;
    let fx = (x & 31) as u32;
    let fy = (y & 31) as u32;
    let weights = [
        (32 - fx) * (32 - fy),
        fx * (32 - fy),
        (32 - fx) * fy,
        fx * fy,
    ];
    let pixels = [
        pixel(image, column, row),
        pixel(image, column + 1, row),
        pixel(image, column, row + 1),
        pixel(image, column + 1, row + 1),
    ];
    std::array::from_fn(|channel| {
        let sum = u32::from(pixels[0][channel]) * weights[0]
            + u32::from(pixels[1][channel]) * weights[1]
            + u32::from(pixels[2][channel]) * weights[2]
            + u32::from(pixels[3][channel]) * weights[3];
        ((sum + 512) >> 10) as u8
    })
}

fn pixel(image: &Image<'_>, x: i64, y: i64) -> [u8; 3] {
    let (Ok(x), Ok(y)) = (usize::try_from(x), usize::try_from(y)) else {
        return [0; 3];
    };
    if x >= image.width || y >= image.height {
        return [0; 3];
    }
    let offset = y * image.stride + x * 4;
    let data = &image.data[offset..offset + 3];
    [data[0], data[1], data[2]]
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;

    fn input(data: &[u8], format: PixelFormat) -> Image<'_> {
        Image {
            data,
            width: CHIP_SIZE,
            height: CHIP_SIZE,
            stride: CHIP_SIZE * 4 + 8,
            format,
        }
    }

    fn landmarks() -> [Point; 5] {
        TEMPLATE.map(|[x, y]| Point { x, y })
    }

    #[test]
    fn rejects_nonfinite_out_of_range_and_degenerate_landmarks() {
        let image = input(&[], PixelFormat::Rgba8);
        let mut points = landmarks();
        points[0].x = f64::NAN;
        assert!(matches!(
            inverse_similarity(&image, &points),
            Err(Error::InvalidLandmarks)
        ));
        points[0].x = 1.01;
        assert!(matches!(
            inverse_similarity(&image, &points),
            Err(Error::InvalidLandmarks)
        ));
        let points = std::array::from_fn(|i| Point {
            x: 0.25 + i as f64 * 1e-4,
            y: 0.5,
        });
        assert!(matches!(
            inverse_similarity(&image, &points),
            Err(Error::InvalidLandmarks)
        ));
        let points = std::array::from_fn(|i| Point {
            x: 0.25 + i as f64 * 0.1,
            y: 0.5,
        });
        assert!(matches!(
            inverse_similarity(&image, &points),
            Err(Error::InvalidLandmarks)
        ));
        let points = std::array::from_fn(|i| Point {
            x: 0.25 + i as f64 * 0.1,
            y: 0.5 + (i % 2) as f64 * 1e-10,
        });
        assert!(matches!(
            inverse_similarity(&image, &points),
            Err(Error::InvalidLandmarks)
        ));
    }

    #[test]
    fn rejects_reflection_with_no_invertible_proper_similarity() {
        let image = input(&[], PixelFormat::Rgba8);
        let center = [
            TEMPLATE.iter().map(|p| p[0]).sum::<f64>() / 5.0,
            TEMPLATE.iter().map(|p| p[1]).sum::<f64>() / 5.0,
        ];
        let centered = TEMPLATE.map(|[x, y]| [x - center[0], y - center[1]]);
        let xx = centered.iter().map(|[x, _]| x * x).sum::<f64>();
        let yy = centered.iter().map(|[_, y]| y * y).sum::<f64>();
        let xy = centered.iter().map(|[x, y]| x * y).sum::<f64>();
        let factor = 0.025 / (xx * yy - xy * xy);
        // Intentionally give the fit one positive and one equally large negative axis.
        let points = centered.map(|[x, y]| Point {
            x: 0.5 + (yy * x - xy * y) * factor,
            y: 0.5 + (xy * x - xx * y) * factor,
        });
        assert_eq!(
            inverse_similarity(&image, &points),
            Err(Error::InvalidLandmarks)
        );
    }

    #[test]
    fn reflected_landmarks_still_fit_a_proper_transform() {
        let image = input(&[], PixelFormat::Rgba8);
        let points = TEMPLATE.map(|[x, y]| Point { x: 1.0 - x, y });
        let Ok([[a, b, _], [c, d, _]]) = inverse_similarity(&image, &points) else {
            panic!("the reflected, full-rank landmarks should still align");
        };
        assert!(a * d - b * c > 0.0);
        assert_eq!(c, -b);
        assert_eq!(a, d);
    }

    #[test]
    fn produces_planar_bgr_and_ignores_alpha_and_stride_padding() {
        let stride = CHIP_SIZE * 4 + 8;
        let mut rgba = vec![255; stride * CHIP_SIZE];
        let mut bgra = rgba.clone();
        for y in 0..CHIP_SIZE {
            for x in 0..CHIP_SIZE {
                let offset = y * stride + x * 4;
                rgba[offset..offset + 4].copy_from_slice(&[x as u8, y as u8, 61, 0]);
                bgra[offset..offset + 4].copy_from_slice(&[61, y as u8, x as u8, 173]);
            }
        }
        let Ok(rgba) = aligned_input(&input(&rgba, PixelFormat::Rgba8), &landmarks(), || Ok(()))
        else {
            panic!("could not align the RGBA input");
        };
        let Ok(bgra) = aligned_input(&input(&bgra, PixelFormat::Bgra8), &landmarks(), || Ok(()))
        else {
            panic!("could not align the BGRA input");
        };
        assert_eq!(bgra, rgba);
        for y in 0..CHIP_SIZE {
            for x in 0..CHIP_SIZE {
                let index = y * CHIP_SIZE + x;
                assert_eq!(rgba[index], 61.0);
                assert_eq!(rgba[CHIP_PIXELS + index], y as f32);
                assert_eq!(rgba[2 * CHIP_PIXELS + index], x as f32);
            }
        }
    }

    #[test]
    fn samples_black_beyond_the_last_pixel() {
        let image = Image {
            data: &[0, 0, 0, 0, 255, 127, 63, 0],
            width: 2,
            height: 1,
            stride: 8,
            format: PixelFormat::Rgba8,
        };
        assert_eq!(bilinear(&image, 32, 0), [255, 127, 63]);
        assert_eq!(bilinear(&image, 48, 0), [128, 64, 32]);
        assert_eq!(bilinear(&image, 64, 0), [0; 3]);
    }

    #[test]
    fn polls_cancellation_during_alignment_without_returning_partial_input() {
        let data = vec![0; (CHIP_SIZE * 4 + 8) * CHIP_SIZE];
        let image = input(&data, PixelFormat::Rgba8);
        let checks = Cell::new(0);
        let result = aligned_input(&image, &landmarks(), || {
            let count = checks.get() + 1;
            checks.set(count);
            if count == 5 {
                Err(Error::Cancelled)
            } else {
                Ok(())
            }
        });
        assert!(matches!(result, Err(Error::Cancelled)));
        assert_eq!(checks.get(), 5);
    }
}
