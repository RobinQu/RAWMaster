use crate::Result;
use serde::Deserialize;
use serde_json::Value;
use std::collections::HashSet;
use std::io::{self, Write};
use std::path::Path;
use uuid::Uuid;

pub(super) const MAX_ITEMS: usize = 200;
pub(super) const MAX_BYTES: usize = 8 * 1024 * 1024;
const MAX_BOUND_INLINE_BYTES: usize = 1024 * 1024;

pub(super) fn extension(format: Option<&str>) -> Option<&'static str> {
    match format {
        Some("jpeg8") => Some("jpg"),
        Some("tiff16") => Some("tiff"),
        Some("png16") => Some("png"),
        _ => None,
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Manifest<'a> {
    schema: u32,
    #[serde(rename = "batchID")]
    batch_id: &'a str,
    #[serde(rename = "libraryID")]
    library_id: &'a str,
    destination: Destination<'a>,
    #[serde(rename = "sourceContext")]
    _source_context: serde::de::IgnoredAny,
    naming_template: &'a str,
    collision: &'a str,
    #[serde(rename = "configuration")]
    _configuration: serde::de::IgnoredAny,
    #[serde(rename = "items")]
    _items: serde::de::IgnoredAny,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Destination<'a> {
    #[serde(rename = "grantID")]
    grant_id: &'a str,
    path_hint: &'a str,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Item<'a> {
    ordinal: usize,
    #[serde(rename = "assetID")]
    asset_id: &'a str,
    stem: &'a str,
    #[serde(borrow)]
    work: Work<'a>,
    #[serde(borrow)]
    version: Version<'a>,
}

// The native renderer owns the remainder of these Codable values. Persist the original JSON,
// including floating-point adjustments and archive resource references.
#[derive(Deserialize)]
struct Work<'a> {
    id: &'a str,
    #[serde(borrow)]
    source: Source<'a>,
}

#[derive(Deserialize)]
struct Version<'a> {
    id: &'a str,
    #[serde(rename = "workID")]
    work_id: &'a str,
    #[serde(borrow)]
    source: Source<'a>,
}

#[derive(Deserialize, PartialEq)]
struct Source<'a> {
    #[serde(rename = "assetID")]
    asset_id: &'a str,
    #[serde(rename = "projectID")]
    project_id: &'a str,
    #[serde(rename = "contentSHA256")]
    sha256: &'a str,
    #[serde(rename = "byteCount")]
    bytes: i64,
    #[serde(rename = "admissionFingerprint")]
    admission: &'a str,
}

pub(super) fn id(input: &str) -> Result<String> {
    let uuid = Uuid::parse_str(input)?;
    let canonical = uuid.hyphenated().to_string();
    if uuid.is_nil() || !input.eq_ignore_ascii_case(&canonical) {
        return Err("expected a nonempty hyphenated batch UUID".into());
    }
    Ok(canonical)
}

pub(super) fn identifier(value: &str) -> bool {
    !value.trim().is_empty() && value.len() <= 1024 && !value.chars().any(char::is_control)
}

pub(super) fn sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
}

pub(super) fn literal_stem(value: &str) -> bool {
    !value.trim().is_empty()
        && value == value.trim()
        && !matches!(value, "." | "..")
        && value.len() <= 240
        && !value
            .chars()
            .any(|c| c.is_control() || matches!(c, '/' | '\\' | ':'))
}

struct ManifestBytes {
    bytes: Vec<u8>,
    limit: usize,
}

impl Write for ManifestBytes {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        if bytes.len() > self.limit - self.bytes.len() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                if self.limit == MAX_BOUND_INLINE_BYTES {
                    "directory-bound inline workbench manifest exceeds 1 MiB"
                } else {
                    "workbench manifest exceeds 8 MiB"
                },
            ));
        }
        self.bytes.extend_from_slice(bytes);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

pub(super) struct Frozen {
    pub id: String,
    pub library_id: String,
    pub count: usize,
    pub json: String,
    pub digest: String,
    pub objects: Option<super::objects::Set>,
}

impl Frozen {
    pub fn new(raw: &mut Value, bound: bool) -> Result<Self> {
        if !raw["sourceContext"].is_object() || !raw["configuration"].is_object() {
            return Err("missing frozen workbench source context or configuration".into());
        }
        let count = raw["items"]
            .as_array()
            .ok_or("missing workbench items")?
            .len();
        if !(1..=MAX_ITEMS).contains(&count) {
            return Err("expected 1 to 200 workbench items".into());
        }
        let Some(Value::String(uuid)) = raw.get_mut("batchID") else {
            return Err("missing batch UUID".into());
        };
        *uuid = id(uuid)?;
        raw.sort_all_objects();
        let limit = if bound && raw["schema"].as_u64() == Some(1) {
            MAX_BOUND_INLINE_BYTES
        } else {
            MAX_BYTES
        };
        let mut bytes = ManifestBytes {
            bytes: Vec::new(),
            limit,
        };
        serde_json::to_writer(&mut bytes, &*raw)?;
        let value = Manifest::deserialize(&*raw)?;
        let id = value.batch_id.to_owned();
        let path = value.destination.path_hint;
        if !matches!(value.schema, 1 | 2)
            || !identifier(value.library_id)
            || !identifier(value.destination.grant_id)
            || !Path::new(path).is_absolute()
            || path.len() > 4096
            || path.chars().any(char::is_control)
            || !matches!(value.collision, "rename" | "skip")
            || value.naming_template.trim().is_empty()
            || value.naming_template.encode_utf16().count() > 180
        {
            return Err("invalid frozen workbench settings or destination reference".into());
        }
        let objects = if value.schema == 2 {
            Some(super::objects::Set::new(
                &raw["configuration"],
                &raw["items"],
            )?)
        } else {
            validate_inline(raw["items"].as_array().ok_or("missing workbench items")?)?;
            None
        };
        let digest = super::digest(&bytes.bytes);
        Ok(Self {
            id,
            library_id: value.library_id.to_owned(),
            count,
            json: String::from_utf8(bytes.bytes)?,
            digest,
            objects,
        })
    }
}

fn validate_inline(items: &[Value]) -> Result<()> {
    let mut assets = HashSet::with_capacity(items.len());
    for (i, raw) in items.iter().enumerate() {
        let item = Item::deserialize(raw)?;
        let source = &item.work.source;
        if item.ordinal != i + 1
            || !assets.insert(item.asset_id)
            || !identifier(item.asset_id)
            || !literal_stem(item.stem)
            || !identifier(item.work.id)
            || !identifier(item.version.id)
            || item.work.id != item.version.work_id
            || source != &item.version.source
            || source.asset_id != item.asset_id
            || !identifier(source.project_id)
            || !identifier(source.admission)
            || source.bytes <= 0
            || !sha256(source.sha256)
            || !raw["version"]["recipe"].is_object()
        {
            return Err(format!("invalid frozen workbench input at ordinal {}", i + 1).into());
        }
    }
    Ok(())
}
