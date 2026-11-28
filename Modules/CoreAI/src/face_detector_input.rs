use crate::{Error, Image, PixelFormat};

const DETECTION_LONG_EDGE: usize = 1024;
const PADDING: usize = 32;

pub(super) struct DetectorInput {
    pub(super) width: usize,
    pub(super) height: usize,
    pub(super) padded_width: usize,
    pub(super) padded_height: usize,
    pub(super) data: Vec<f32>,
}

pub(super) fn prepare(
    image: &Image<'_>,
    check: impl Fn() -> Result<(), Error>,
) -> Result<DetectorInput, Error> {
    check()?;
    if image.width == 0 || image.height == 0 {
        return Err(Error::InvalidImage);
    }
    let row_bytes = image.width.checked_mul(4).ok_or(Error::BudgetExceeded)?;
    let required = image
        .stride
        .checked_mul(image.height - 1)
        .and_then(|offset| offset.checked_add(row_bytes))
        .ok_or(Error::BudgetExceeded)?;
    if image.stride < row_bytes || image.data.len() < required {
        return Err(Error::InvalidImage);
    }

    let ratio = (DETECTION_LONG_EDGE as f64 / image.width.max(image.height) as f64).min(1.0);
    let width = ((image.width as f64 * ratio).round_ties_even() as usize).max(1);
    let height = ((image.height as f64 * ratio).round_ties_even() as usize).max(1);
    let padded_width = width.next_multiple_of(PADDING);
    let padded_height = height.next_multiple_of(PADDING);
    let plane_pixels = padded_width * padded_height;
    let mut data = vec![0.; plane_pixels * 3];
    let channels = match image.format {
        PixelFormat::Rgba8 => [2, 1, 0],
        PixelFormat::Bgra8 => [0, 1, 2],
    };
    let mut write = |x, y, pixel: [u8; 3]| {
        let index = y * padded_width + x;
        for (plane, &color) in channels.iter().enumerate() {
            data[plane * plane_pixels + index] = f32::from(pixel[color]);
        }
    };
    if width == image.width && height == image.height {
        for y in 0..height {
            check()?;
            let row = &image.data[y * image.stride..][..row_bytes];
            for (x, pixel) in row.chunks_exact(4).enumerate() {
                write(x, y, [pixel[0], pixel[1], pixel[2]]);
            }
        }
    } else if image.width % width == 0 && image.height % height == 0 {
        let width_factor = image.width / width;
        let height_factor = image.height / height;
        let scale = (1.0 / (width_factor * height_factor) as f64) as f32;
        for y in 0..height {
            check()?;
            for x in 0..width {
                let mut sum = [0_u64; 3];
                for dy in 0..height_factor {
                    let row_start = (y * height_factor + dy) * image.stride;
                    for dx in 0..width_factor {
                        let pixel_start = row_start + (x * width_factor + dx) * 4;
                        for (channel, accumulator) in sum.iter_mut().enumerate() {
                            *accumulator += u64::from(image.data[pixel_start + channel]);
                        }
                    }
                }
                // OpenCV's dedicated two-by-two area path rounds integer half steps up.
                let average = if width_factor == 2 && height_factor == 2 {
                    sum.map(|value| ((value + 2) / 4) as u8)
                } else {
                    sum.map(|value| (value as f32 * scale).round_ties_even() as u8)
                };
                write(x, y, average);
            }
        }
    } else {
        let columns = area_spans(image.width, width);
        let rows = area_spans(image.height, height);
        let mut totals = vec![[0f32; 3]; width];
        for (y, row_weights) in rows.iter().enumerate() {
            check()?;
            totals.fill([0.; 3]);
            for &(source_y, row_weight) in row_weights {
                let row = &image.data[source_y * image.stride..][..row_bytes];
                for (pixel, column_weights) in totals.iter_mut().zip(&columns) {
                    let mut horizontal = [0.; 3];
                    for &(x, column_weight) in column_weights {
                        for (channel, accumulator) in horizontal.iter_mut().enumerate() {
                            // Match OpenCV on arm64: horizontal accumulation fuses, vertical does not.
                            *accumulator = column_weight
                                .mul_add(f32::from(row[x * 4 + channel]), *accumulator);
                        }
                    }
                    for (sum, channel) in pixel.iter_mut().zip(horizontal) {
                        *sum += row_weight * channel;
                    }
                }
            }
            for (x, pixel) in totals.iter().enumerate() {
                write(x, y, pixel.map(|value| value.round_ties_even() as u8));
            }
        }
    }
    check()?;
    Ok(DetectorInput {
        width,
        height,
        padded_width,
        padded_height,
        data,
    })
}

fn area_spans(source: usize, destination: usize) -> Vec<Vec<(usize, f32)>> {
    let scale = 1.0 / (destination as f64 / source as f64);
    (0..destination)
        .map(|output| {
            let start = output as f64 * scale;
            let end = start + scale;
            let width = scale.min(source as f64 - start);
            let middle = (start.ceil() as usize).min(source - 1);
            let last = (end.floor() as usize).min(source - 1);
            let middle = middle.min(last);
            let mut weights = Vec::new();
            if middle as f64 - start > 1e-3 {
                weights.push((middle - 1, ((middle as f64 - start) / width) as f32));
            }
            weights.extend((middle..last).map(|input| (input, (1.0 / width) as f32)));
            if end - last as f64 > 1e-3 {
                weights.push((
                    last,
                    ((end - last as f64).min(1.0).min(width) / width) as f32,
                ));
            }
            weights
        })
        .collect()
}
