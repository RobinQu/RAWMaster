use crate::{Dimensions, ExportError, Geometry, Rect, Result};
use fast_image_resize::{
    images::{Image, ImageRef},
    FilterType, PixelType, ResizeAlg, ResizeOptions, Resizer,
};
use serde::{Deserialize, Serialize};
use std::{
    borrow::Cow,
    io::{Seek, Write},
};

pub const SRGB_PROFILE: &[u8] = include_bytes!("../profiles/srgb.icc");

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Format {
    Jpeg,
    Png,
    Tiff,
}

#[derive(Clone, Copy)]
pub struct Raster<'a> {
    /// Top-down, straight alpha, tightly interleaved RGBA in host-endian 16-bit sRGB.
    pub pixels: &'a [u16],
    pub size: Dimensions,
}

impl Raster<'_> {
    fn validate(self) -> Result<()> {
        if self.size.area()?.checked_mul(4) != Some(self.pixels.len()) {
            return Err(ExportError::Pixels);
        }
        Ok(())
    }
}

#[derive(Clone, Copy)]
pub enum Matte {
    Transparent,
    Solid([u16; 4]),
    Blur,
}

pub struct Overlay<'a> {
    pub raster: Raster<'a>,
    pub x: u32,
    pub y: u32,
}

fn encoding(err: impl std::fmt::Display) -> ExportError {
    ExportError::Encoding(err.to_string())
}

fn resize(
    source: Raster<'_>,
    target: Dimensions,
    crop: [f64; 4],
    filter: FilterType,
) -> Result<Vec<u16>> {
    let view = ImageRef::new(
        source.size.width,
        source.size.height,
        bytemuck::cast_slice(source.pixels),
        PixelType::U16x4,
    )
    .map_err(encoding)?;
    let mut result = Image::new(target.width, target.height, PixelType::U16x4);
    let options = ResizeOptions::new()
        .resize_alg(ResizeAlg::Convolution(filter))
        .crop(crop[0], crop[1], crop[2], crop[3]);
    Resizer::new()
        .resize(&view, &mut result, &options)
        .map_err(encoding)?;
    let samples: &[u16] = bytemuck::try_cast_slice(result.buffer()).map_err(encoding)?;
    Ok(samples.to_vec())
}

fn compose(canvas: &mut [u16], size: Dimensions, image: Raster<'_>, x: u32, y: u32) -> Result<()> {
    image.validate()?;
    if x.checked_add(image.size.width)
        .is_none_or(|right| right > size.width)
        || y.checked_add(image.size.height)
            .is_none_or(|bottom| bottom > size.height)
    {
        return Err(ExportError::Geometry);
    }
    let stride = size.width as usize * 4;
    let row = image.size.width as usize * 4;
    for (index, input) in image.pixels.chunks_exact(row).enumerate() {
        let begin = (y as usize + index) * stride + x as usize * 4;
        let output = &mut canvas[begin..begin + row];
        for (dest, source) in output.chunks_exact_mut(4).zip(input.chunks_exact(4)) {
            if source[3] == u16::MAX || dest[3] == 0 {
                dest.copy_from_slice(source);
            } else if source[3] != 0 {
                let sa = u64::from(source[3]);
                let da = (u64::from(dest[3]) * (65535 - sa) + 32767) / 65535;
                let sum = sa + da;
                for channel in 0..3 {
                    dest[channel] = ((u64::from(source[channel]) * sa
                        + u64::from(dest[channel]) * da
                        + sum / 2)
                        / sum) as u16;
                }
                dest[3] = sum as u16;
            }
        }
    }
    Ok(())
}

fn blur(source: Raster<'_>, target: Dimensions) -> Result<Vec<u16>> {
    let factor = 24.0 / f64::from(target.width.max(target.height));
    let size = Dimensions {
        width: (f64::from(target.width) * factor).round().max(1.0) as u32,
        height: (f64::from(target.height) * factor).round().max(1.0) as u32,
    };
    let sw = f64::from(source.size.width);
    let sh = f64::from(source.size.height);
    let ratio = f64::from(target.width) / f64::from(target.height);
    let w = sw.min(sh * ratio);
    let h = sh.min(sw / ratio);
    let mut small = resize(
        source,
        size,
        [(sw - w) / 2.0, (sh - h) / 2.0, w, h],
        FilterType::Box,
    )?;
    // An opaque matte guarantees the same transparent-edge treatment as the desktop renderer.
    for pixel in small.chunks_exact_mut(4) {
        let alpha = u32::from(pixel[3]);
        for color in &mut pixel[..3] {
            *color = ((u32::from(*color) * alpha + 65535 * (65535 - alpha) + 32767) / 65535) as u16;
        }
        pixel[3] = u16::MAX;
    }
    resize(
        Raster {
            pixels: &small,
            size,
        },
        target,
        [0.0, 0.0, f64::from(size.width), f64::from(size.height)],
        FilterType::Bilinear,
    )
}

/// Produce photo and overlays in their shared canvas coordinates. A host may supply glyph,
/// border line or shadow rasters as overlays. No platform graphics API is required.
pub fn render(
    source: Raster<'_>,
    geometry: &Geometry,
    matte: Matte,
    overlays: &[Overlay<'_>],
) -> Result<Vec<u16>> {
    source.validate()?;
    let len = geometry.canvas.area()? * 4;
    let Rect {
        x,
        y,
        width,
        height,
    } = geometry.photo;
    let size = Dimensions { width, height };
    size.area()?;
    let sw = f64::from(source.size.width);
    let sh = f64::from(source.size.height);
    let [left, top, w, h] = geometry.crop;
    if !geometry.crop.iter().all(|n| n.is_finite())
        || left < 0.0
        || top < 0.0
        || w <= 0.0
        || h <= 0.0
        || left + w > sw + 1e-8
        || top + h > sh + 1e-8
    {
        return Err(ExportError::Geometry);
    }
    let resized;
    let foreground = if source.size == size && geometry.crop == [0.0, 0.0, sw, sh] {
        source
    } else {
        resized = resize(source, size, geometry.crop, FilterType::Lanczos3)?;
        Raster {
            pixels: &resized,
            size,
        }
    };
    let mut canvas = match matte {
        Matte::Transparent => vec![0; len],
        Matte::Solid(color) => {
            let mut buffer = vec![0; len];
            for pixel in buffer.chunks_exact_mut(4) {
                pixel.copy_from_slice(&color);
            }
            buffer
        }
        Matte::Blur => blur(source, geometry.canvas)?,
    };
    compose(&mut canvas, geometry.canvas, foreground, x, y)?;
    for overlay in overlays {
        compose(
            &mut canvas,
            geometry.canvas,
            overlay.raster,
            overlay.x,
            overlay.y,
        )?;
    }
    Ok(canvas)
}

/// Write an already composited, opaque sRGB bitmap without a color or depth conversion.
pub fn encode_rgbx8(
    mut output: impl Write,
    pixels: &[u8],
    size: Dimensions,
    stride: usize,
    quality: u8,
) -> Result<()> {
    size.area()?;
    let (width, height) = (size.width as usize, size.height as usize);
    if !(5..=100).contains(&quality)
        || width > 65_500
        || height > 65_500
        || stride < width * 4
        || stride.checked_mul(height) != Some(pixels.len())
    {
        return Err(ExportError::Options);
    }
    let image = turbojpeg::Image {
        pixels,
        width,
        pitch: stride,
        height,
        format: turbojpeg::PixelFormat::RGBX,
    };
    let jpeg = turbojpeg::compress(image, i32::from(quality), turbojpeg::Subsamp::Sub2x2)
        .map_err(encoding)?;
    output.write_all(&jpeg[..2])?;
    output.write_all(&[0xff, 0xe2])?;
    let length = (SRGB_PROFILE.len() + 16) as u16;
    output.write_all(&length.to_be_bytes())?;
    output.write_all(b"ICC_PROFILE\0\x01\x01")?;
    output.write_all(SRGB_PROFILE)?;
    output.write_all(&jpeg[2..])?;
    output.flush()?;
    Ok(())
}

pub fn encode(
    mut output: impl Write + Seek,
    raster: Raster<'_>,
    format: Format,
    quality: u8,
) -> Result<()> {
    raster.validate()?;
    let Dimensions { width, height } = raster.size;
    match format {
        Format::Jpeg => {
            let mut opaque = Vec::with_capacity(raster.pixels.len());
            for pixel in raster.pixels.chunks_exact(4) {
                let a = u32::from(pixel[3]);
                for value in &pixel[..3] {
                    let white = (u32::from(*value) * a + 65535 * (65535 - a) + 32767) / 65535;
                    opaque.push(((white + 128) / 257) as u8);
                }
                opaque.push(255);
            }
            encode_rgbx8(output, &opaque, raster.size, width as usize * 4, quality)
        }
        Format::Png => {
            let mut info = png::Info::with_size(width, height);
            info.bit_depth = png::BitDepth::Sixteen;
            info.color_type = png::ColorType::Rgba;
            info.icc_profile = Some(Cow::Borrowed(SRGB_PROFILE));
            let mut encoder = png::Encoder::with_info(&mut output, info).map_err(encoding)?;
            encoder.set_compression(png::Compression::Fast);
            let mut writer = encoder.write_header().map_err(encoding)?;
            let mut stream = writer.stream_writer().map_err(encoding)?;
            let mut row = vec![0; width as usize * 8];
            for line in raster.pixels.chunks_exact(width as usize * 4) {
                for (bytes, value) in row.chunks_exact_mut(2).zip(line) {
                    bytes.copy_from_slice(&value.to_be_bytes());
                }
                stream.write_all(&row)?;
            }
            stream.finish().map_err(encoding)?;
            writer.finish().map_err(encoding)?;
            Ok(())
        }
        Format::Tiff => {
            use tiff::{
                encoder::{colortype::RGB16, TiffEncoder},
                tags::{ExtraSamples, Tag},
            };
            let mut encoder = TiffEncoder::new(&mut output).map_err(encoding)?;
            let mut image = encoder
                .new_image::<RGB16>(width, height)
                .map_err(encoding)?;
            image
                .extra_samples(&[ExtraSamples::UnassociatedAlpha])
                .map_err(encoding)?;
            image
                .encoder()
                .write_tag(Tag::IccProfile, SRGB_PROFILE)
                .map_err(encoding)?;
            image.write_data(raster.pixels).map_err(encoding)
        }
    }
}
