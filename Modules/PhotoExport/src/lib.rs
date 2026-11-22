//! Cross-platform final delivery. A host supplies the developed sRGB raster and verified capture labels.
mod ffi;
mod layout;
mod pixels;
mod preset;

pub use layout::{geometry, Dimensions, Frame, Geometry, GeometryRequest, Rect};
pub use pixels::{encode, encode_rgbx8, render, Format, Matte, Overlay, Raster, SRGB_PROFILE};
pub use preset::{normalize_preset, Appearance, Logo, Preset, Settings};

use serde::{Deserialize, Serialize};
use std::{collections::HashSet, fs, io, path::Path};

pub const MAX_BATCH_PHOTOS: usize = 200;

#[derive(Debug, thiserror::Error)]
pub enum ExportError {
    #[error("a batch requires 1 to {MAX_BATCH_PHOTOS} photos; received {0}")]
    Count(usize),
    #[error("a selected photo is missing from the current scope or is repeated")]
    Selection,
    #[error("invalid filename template or output name")]
    Filename,
    #[error("the filename template requires a capture date")]
    CaptureDate,
    #[error("unsupported or invalid export geometry")]
    Geometry,
    #[error("invalid output pixels or stride")]
    Pixels,
    #[error("invalid export preset: {0}")]
    Preset(&'static str),
    #[error("unsupported output parameters")]
    Options,
    #[error("image encoding failed: {0}")]
    Encoding(String),
    #[error(transparent)]
    Io(#[from] io::Error),
}

pub type Result<T> = std::result::Result<T, ExportError>;

/// Counts input photos, independent of generated files, online state and visible rows.
pub fn validate_count(count: usize) -> Result<()> {
    if (1..=MAX_BATCH_PHOTOS).contains(&count) {
        Ok(())
    } else {
        Err(ExportError::Count(count))
    }
}

/// Return a frozen input plan in the order used by the caller's catalog.
pub fn ordered_selection(candidates: &[String], requested: &[String]) -> Result<Vec<String>> {
    validate_count(requested.len())?;
    let mut wanted: HashSet<_> = requested.iter().map(String::as_str).collect();
    if wanted.len() != requested.len() || wanted.contains("") {
        return Err(ExportError::Selection);
    }
    let ordered: Vec<_> = candidates
        .iter()
        .filter(|value| wanted.remove(value.as_str()))
        .cloned()
        .collect();
    if !wanted.is_empty() {
        return Err(ExportError::Selection);
    }
    Ok(ordered)
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct NameRequest {
    pub template: String,
    /// Source stem without the extension. It may contain interior dots or literal braces.
    pub stem: String,
    pub index: usize,
    pub export_date: String,
    pub capture_date: Option<String>,
}

fn safe_name(value: &str) -> bool {
    !matches!(value, "" | "." | "..")
        && !value
            .chars()
            .any(|ch| ch.is_control() || matches!(ch, '/' | '\\' | ':'))
}

fn visit_template(template: &str, mut visit: impl FnMut(&str, bool) -> Result<()>) -> Result<()> {
    let mut rest = template.trim();
    if !safe_name(rest) || template.encode_utf16().count() > 180 {
        return Err(ExportError::Filename);
    }
    while let Some(split) = rest.find(['{', '}']) {
        let (literal, token) = rest.split_at(split);
        let Some((token, tail)) = token.strip_prefix('{').and_then(|s| s.split_once('}')) else {
            return Err(ExportError::Filename);
        };
        if !matches!(token, "name" | "index" | "date" | "captureDate") {
            return Err(ExportError::Filename);
        }
        visit(literal, false)?;
        visit(token, true)?;
        rest = tail;
    }
    visit(rest, false)
}

pub fn validate_template(template: &str) -> Result<()> {
    visit_template(template, |_, _| Ok(()))
}

pub fn output_stem(request: &NameRequest) -> Result<String> {
    let index = format!("{:04}", request.index);
    let mut result = String::new();
    visit_template(&request.template, |value, token| {
        let text = if !token {
            value
        } else {
            match value {
                "name" => &request.stem,
                "index" => &index,
                "date" => &request.export_date,
                "captureDate" => request
                    .capture_date
                    .as_deref()
                    .ok_or(ExportError::CaptureDate)?,
                _ => return Err(ExportError::Filename),
            }
        };
        result.push_str(text);
        Ok(())
    })?;
    let result = result.trim();
    if !safe_name(result) || result.len() > 240 {
        return Err(ExportError::Filename);
    }
    Ok(result.to_owned())
}

/// Install a closed staging file without replacing a file created by another job.
/// The caller places both paths on the same volume and owns staging cleanup.
pub fn publish(stage: &Path, destination: &Path) -> Result<()> {
    #[cfg(target_os = "macos")]
    {
        use std::{ffi::CString, os::unix::ffi::OsStrExt};
        let from = CString::new(stage.as_os_str().as_bytes()).map_err(|_| ExportError::Filename)?;
        let to =
            CString::new(destination.as_os_str().as_bytes()).map_err(|_| ExportError::Filename)?;
        // Both C strings are valid through the call. RENAME_EXCL provides atomic no-replace.
        if unsafe { libc::renamex_np(from.as_ptr(), to.as_ptr(), libc::RENAME_EXCL) } == 0 {
            return Ok(());
        }
        let failure = io::Error::last_os_error();
        if failure.raw_os_error() != Some(libc::ENOTSUP) {
            return Err(failure.into());
        }
    }
    fs::hard_link(stage, destination)?;
    Ok(())
}

/// Standalone Rust entry point for a prepared raster. Existing destinations are never replaced.
pub fn write_photo(
    destination: &Path,
    source: Raster<'_>,
    geometry: &Geometry,
    matte: Matte,
    overlays: &[Overlay<'_>],
    format: Format,
    quality: u8,
) -> Result<()> {
    let folder = destination
        .parent()
        .filter(|path| !path.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    let mut stage = tempfile::NamedTempFile::new_in(folder)?;
    let canvas = render(source, geometry, matte, overlays)?;
    encode(
        stage.as_file_mut(),
        Raster {
            pixels: &canvas,
            size: geometry.canvas,
        },
        format,
        quality,
    )?;
    publish(stage.path(), destination)
}
