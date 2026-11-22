use crate::{validate_template, ExportError, Result};
use base64::{engine::general_purpose::STANDARD, Engine};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

const KIND: &str = "rawmaster.export-preset";
const MAX_BYTES: usize = 2 * 1024 * 1024;

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Preset {
    kind: String,
    schema_version: u8,
    pub name: String,
    pub settings: Settings,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Settings {
    pub mode: String,
    pub copy_mode: String,
    pub original_format: String,
    pub format: crate::Format,
    pub size: String,
    pub edge: String,
    pub quality: String,
    pub color: String,
    pub template: String,
    pub collision: String,
    pub metadata: String,
    pub gps: bool,
    pub layout: Appearance,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Appearance {
    pub builtin: String,
    pub frame: String,
    pub ratio: String,
    pub fit: String,
    pub paper: String,
    pub margin: u8,
    pub stroke: u8,
    pub stroke_color: String,
    pub shadow: bool,
    pub mark: String,
    pub place: String,
    pub anchor: String,
    pub signature: String,
    pub fields: Vec<String>,
    pub font: String,
    pub ink: String,
    pub opacity: u8,
    pub scale: u8,
    pub logo: Option<Logo>,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Logo {
    pub mime: String,
    pub sha256: String,
    pub base64: String,
}

impl Preset {
    pub fn parse(input: &[u8]) -> Result<Self> {
        if input.len() > MAX_BYTES {
            return Err(ExportError::Preset("file exceeds 2 MiB"));
        }
        let mut data: serde_json::Value =
            serde_json::from_slice(input).map_err(|_| ExportError::Preset("invalid JSON"))?;
        match data
            .get("schemaVersion")
            .and_then(serde_json::Value::as_u64)
        {
            Some(1) => {
                let settings = data["settings"]
                    .as_object_mut()
                    .ok_or(ExportError::Preset("missing settings"))?;
                for (key, value) in [
                    ("mode", "render"),
                    ("copyMode", "files"),
                    ("originalFormat", "all"),
                ] {
                    if settings.insert(key.to_owned(), value.into()).is_some() {
                        return Err(ExportError::Preset("unknown v1 setting"));
                    }
                }
                let layout = settings
                    .get_mut("layout")
                    .and_then(serde_json::Value::as_object_mut)
                    .ok_or(ExportError::Preset("missing layout"))?;
                let builtin = match (
                    layout.get("frame").and_then(|v| v.as_str()),
                    layout.get("mark").and_then(|v| v.as_str()),
                ) {
                    (Some("solid"), _) => "paper",
                    (Some("blur"), _) => "mist",
                    (_, Some("signature")) => "sign",
                    _ => "plain",
                };
                if layout
                    .insert("builtin".to_owned(), builtin.into())
                    .is_some()
                {
                    return Err(ExportError::Preset("unknown v1 layout field"));
                }
                data["schemaVersion"] = 2.into();
            }
            Some(2) => {}
            _ => return Err(ExportError::Preset("unsupported schema")),
        }
        if data["settings"]["layout"].get("logo").is_none() {
            return Err(ExportError::Preset("missing logo field"));
        }
        let mut preset: Self = serde_json::from_value(data)
            .map_err(|_| ExportError::Preset("unknown or missing field"))?;
        preset.validate()?;
        preset.name = preset.name.trim().to_owned();
        Ok(preset)
    }

    fn validate(&self) -> Result<()> {
        let name = self.name.trim();
        if self.kind != KIND
            || name.is_empty()
            || name.encode_utf16().count() > 70
            || self.name.chars().any(char::is_control)
        {
            return Err(ExportError::Preset("invalid preset kind or name"));
        }
        let s = &self.settings;
        if !matches!(s.mode.as_str(), "render" | "original")
            || !matches!(s.copy_mode.as_str(), "files" | "manifest")
            || !matches!(s.original_format.as_str(), "all" | "both" | "jpeg" | "raw")
            || !matches!(
                s.size.as_str(),
                "0" | "1080" | "1350" | "2048" | "4096" | "custom"
            )
            || !digits(&s.edge, 64, 100_000)
            || !digits(&s.quality, 5, 100)
            || s.color != "srgb"
            || !matches!(s.collision.as_str(), "rename" | "skip")
            || !matches!(s.metadata.as_str(), "rights" | "photo" | "none")
        {
            return Err(ExportError::Preset("unsupported format or settings"));
        }
        validate_template(&s.template)?;
        s.layout.validate()
    }
}

fn digits(s: &str, minimum: u32, maximum: u32) -> bool {
    s.bytes().all(|byte| byte.is_ascii_digit())
        && s.parse::<u32>()
            .is_ok_and(|value| (minimum..=maximum).contains(&value))
}

impl Appearance {
    fn validate(&self) -> Result<()> {
        let fields = [
            "camera", "lens", "focal", "aperture", "shutter", "iso", "date",
        ];
        let hex = |s: &str| {
            s.len() == 7
                && s.starts_with('#')
                && s.as_bytes()[1..].iter().all(u8::is_ascii_hexdigit)
        };
        if !matches!(
            self.builtin.as_str(),
            "plain" | "paper" | "split" | "mist" | "sign" | "date"
        ) || !matches!(self.frame.as_str(), "none" | "solid" | "blur")
            || !matches!(
                self.ratio.as_str(),
                "source" | "1:1" | "4:5" | "3:2" | "16:9"
            )
            || !matches!(self.fit.as_str(), "contain" | "cover")
            || !matches!(
                self.mark.as_str(),
                "off" | "signature" | "exif" | "both" | "logo"
            )
            || !matches!(self.place.as_str(), "photo" | "footer")
            || !matches!(
                self.anchor.as_str(),
                "tl" | "tc" | "tr" | "cl" | "cc" | "cr" | "bl" | "bc" | "br"
            )
            || !matches!(self.font.as_str(), "sans" | "serif" | "mono")
            || self.signature.encode_utf16().count() > 100
            || self.margin > 16
            || self.stroke > 5
            || self.opacity > 100
            || !(60..=160).contains(&self.scale)
            || ![&self.paper, &self.stroke_color, &self.ink]
                .into_iter()
                .all(|s| hex(s))
            || (self.frame == "none" && self.place == "footer")
            || (self.place == "footer" && !self.anchor.starts_with('b'))
            || !self.fields.iter().enumerate().all(|(i, field)| {
                fields.contains(&field.as_str()) && !self.fields[..i].contains(field)
            })
            || (matches!(self.mark.as_str(), "signature" | "both")
                && self.signature.trim().is_empty())
            || (matches!(self.mark.as_str(), "exif" | "both") && self.fields.is_empty())
            || (self.mark == "logo" && self.logo.is_none())
        {
            return Err(ExportError::Preset("invalid watermark settings"));
        }
        if let Some(logo) = &self.logo {
            logo.check()?;
        }
        Ok(())
    }
}

impl Logo {
    fn check(&self) -> Result<()> {
        let invalid = ExportError::Preset("invalid or damaged PNG logo");
        if self.mime != "image/png" || self.base64.is_empty() || self.base64.len() > 1_500_000 {
            return Err(invalid);
        }
        let png = STANDARD
            .decode(&self.base64)
            .map_err(|_| ExportError::Preset("invalid logo base64"))?;
        if format!("{:x}", Sha256::digest(&png)) != self.sha256 {
            return Err(invalid);
        }
        let mut reader = png::Decoder::new(std::io::Cursor::new(png))
            .read_info()
            .map_err(|_| ExportError::Preset("invalid PNG header"))?;
        let info = reader.info();
        if info.width > 512 || info.height > 512 || info.animation_control.is_some() {
            return Err(invalid);
        }
        let size = reader
            .output_buffer_size()
            .filter(|size| *size <= 512 * 512 * 8)
            .ok_or(invalid)?;
        reader
            .next_frame(&mut vec![0; size])
            .map_err(|_| ExportError::Preset("invalid PNG pixels"))?;
        reader
            .finish()
            .map_err(|_| ExportError::Preset("invalid PNG trailing data"))?;
        Ok(())
    }
}

pub fn normalize_preset(input: &[u8]) -> Result<Vec<u8>> {
    serde_json::to_vec(&Preset::parse(input)?).map_err(|_| ExportError::Preset("encoding failed"))
}
