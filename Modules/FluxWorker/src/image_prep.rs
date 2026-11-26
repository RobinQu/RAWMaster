use anyhow::Result;
use image::imageops::FilterType;
use std::path::Path;

pub struct PreparedImage {
    pub pixels: Vec<f32>,
    pub width: u32,
    pub height: u32,
}

fn round_to_multiple(value: f64) -> u32 {
    let ceiled = ((value / 16.0).ceil() * 16.0) as i64;
    ceiled.clamp(64, 4096) as u32
}

fn pad_pixel(source: &image::RgbImage, x: i64, y: i64, mode_reflect: bool) -> image::Rgb<u8> {
    let w = source.width() as i64;
    let h = source.height() as i64;
    let map = |mut v: i64, len: i64| -> usize {
        if len <= 1 {
            return 0;
        }
        loop {
            if v < 0 {
                v = if mode_reflect { -v } else { -v - 1 };
            } else if v >= len {
                v = if mode_reflect {
                    2 * len - 2 - v
                } else {
                    2 * len - 1 - v
                };
            } else {
                return v as usize;
            }
        }
    };
    *source.get_pixel(map(x, w) as u32, map(y, h) as u32)
}

pub fn prepare_reference(path: &Path) -> Result<PreparedImage> {
    let image = image::open(path)?.to_rgb8();
    let (source_w, source_h) = image.dimensions();
    let mut scale = 1.0f64
        .min(((4.0 * 1024.0 * 1024.0) / (source_w as f64 * source_h as f64)).sqrt())
        .min(4096.0 / source_w.max(source_h) as f64);
    let mut fit_w = ((source_w as f64 * scale).round() as u32).max(1);
    let mut fit_h = ((source_h as f64 * scale).round() as u32).max(1);
    let mut target_w = round_to_multiple(fit_w as f64);
    let mut target_h = round_to_multiple(fit_h as f64);
    while target_w as u64 * target_h as u64 > 4 * 1024 * 1024 {
        scale *= 0.995;
        fit_w = (source_w as f64 * scale).round() as u32;
        fit_h = (source_h as f64 * scale).round() as u32;
        target_w = round_to_multiple(fit_w as f64);
        target_h = round_to_multiple(fit_h as f64);
    }
    let resized = if (fit_w, fit_h) != (source_w, source_h) {
        image::imageops::resize(&image, fit_w, fit_h, FilterType::Lanczos3)
    } else {
        image.clone()
    };
    let reflect = fit_w.min(fit_h) > 16;
    let left = ((target_w as i64 - fit_w as i64) / 2) as i64;
    let top = ((target_h as i64 - fit_h as i64) / 2) as i64;
    let mut pixels = Vec::with_capacity(target_w as usize * target_h as usize * 3);
    for y in 0..target_h as i64 {
        for x in 0..target_w as i64 {
            let pixel = pad_pixel(&resized, x - left, y - top, reflect);
            for channel in pixel.0 {
                pixels.push(channel as f32 / 127.5 - 1.0);
            }
        }
    }
    Ok(PreparedImage {
        pixels,
        width: target_w,
        height: target_h,
    })
}
