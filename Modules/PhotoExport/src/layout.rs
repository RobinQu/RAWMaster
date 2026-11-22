use crate::{ExportError, Result};
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct Dimensions {
    pub width: u32,
    pub height: u32,
}

impl Dimensions {
    pub(crate) fn area(self) -> Result<usize> {
        if self.width == 0 || self.height == 0 || self.width > 100_000 || self.height > 100_000 {
            return Err(ExportError::Geometry);
        }
        let area = u64::from(self.width) * u64::from(self.height);
        // Bound allocation and reject a malformed extent before casting to the host size.
        if area > 260_000_000 {
            return Err(ExportError::Geometry);
        }
        Ok(area as usize)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct Rect {
    pub x: u32,
    pub y: u32,
    pub width: u32,
    pub height: u32,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize)]
pub struct Frame {
    /// Use null to keep the source ratio. Both sides are positive integers.
    pub ratio: Option<[u32; 2]>,
    pub margin_percent: u8,
    /// Millipercent of final short edge, after applying the requested text scale.
    pub footer_per_mille: u16,
    pub cover: bool,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize)]
pub struct GeometryRequest {
    pub source: Dimensions,
    pub long_edge: Option<u32>,
    pub frame: Option<Frame>,
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct Geometry {
    pub canvas: Dimensions,
    /// Top-left origin. A cover resize may extend beyond this visible rectangle.
    pub photo: Rect,
    pub footer: Rect,
    /// Composited at photo.x/y. For cover, this centering crop is applied before sampling.
    pub crop: [f64; 4],
}

pub fn geometry(request: GeometryRequest) -> Result<Geometry> {
    let Dimensions { width, height } = request.source;
    request.source.area()?;
    if request
        .long_edge
        .is_some_and(|value| value == 0 || value > 100_000)
    {
        return Err(ExportError::Geometry);
    }
    if let Some(frame) = request.frame {
        if frame.margin_percent > 16
            || frame.footer_per_mille > 320
            || frame
                .ratio
                .is_some_and(|[w, h]| w == 0 || h == 0 || w > 100_000 || h > 100_000)
        {
            return Err(ExportError::Geometry);
        }
    }
    let limit = request
        .long_edge
        .unwrap_or(width.max(height))
        .min(width.max(height));
    let measure = |edge| {
        let frame = request.frame;
        let [aspect_w, aspect_h] = frame.and_then(|f| f.ratio).unwrap_or([width, height]);
        let scale = f64::from(edge) / f64::from(aspect_w.max(aspect_h));
        let w = (scale * f64::from(aspect_w)).round().max(1.0) as u32;
        let h = (scale * f64::from(aspect_h)).round().max(1.0) as u32;
        let short = w.min(h);
        let margin = frame.map_or(0, |f| {
            ((short * u32::from(f.margin_percent) + 50) / 100).min((short - 1) / 2)
        });
        let footer = frame.map_or(0, |f| {
            ((short * u32::from(f.footer_per_mille) + 500) / 1000).min(h - 2 * margin - 1)
        });
        let (area_w, area_h) = (w - 2 * margin, h - 2 * margin - footer);
        let (sx, sy) = (
            f64::from(area_w) / f64::from(width),
            f64::from(area_h) / f64::from(height),
        );
        let cover = frame.is_some_and(|f| f.cover);
        let zoom = if cover { sx.max(sy) } else { sx.min(sy) };
        let (pw, ph) = if cover || frame.is_none() {
            (area_w, area_h)
        } else {
            (
                (f64::from(width) * zoom).round().max(1.0) as u32,
                (f64::from(height) * zoom).round().max(1.0) as u32,
            )
        };
        let (crop_w, crop_h) = if cover {
            (
                (f64::from(area_w) / zoom).min(f64::from(width)),
                (f64::from(area_h) / zoom).min(f64::from(height)),
            )
        } else {
            (f64::from(width), f64::from(height))
        };
        (
            zoom,
            Geometry {
                canvas: Dimensions {
                    width: w,
                    height: h,
                },
                photo: Rect {
                    x: margin + (area_w - pw) / 2,
                    y: margin + (area_h - ph) / 2,
                    width: pw,
                    height: ph,
                },
                footer: Rect {
                    x: margin,
                    y: h - margin - footer,
                    width: area_w,
                    height: footer,
                },
                crop: [
                    (f64::from(width) - crop_w) / 2.0,
                    (f64::from(height) - crop_h) / 2.0,
                    crop_w,
                    crop_h,
                ],
            },
        )
    };
    let (zoom, proposed) = measure(limit);
    let plan = if request.frame.is_some_and(|f| f.cover) && zoom > 1.0 {
        let (mut low, mut high) = (1, limit);
        while low < high {
            let mid = low + (high - low).div_ceil(2);
            if measure(mid).0 <= 1.0 {
                low = mid;
            } else {
                high = mid - 1;
            }
        }
        measure(low).1
    } else {
        proposed
    };
    plan.canvas.area()?;
    Ok(plan)
}
