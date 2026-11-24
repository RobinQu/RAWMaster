use crate::Pixel;
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::{
    collections::{HashMap, HashSet},
    fs::OpenOptions,
    io::Read,
    path::Path,
};

pub const ATLAS_PIXELS: usize = 64 * 64 * 64;
const ATLAS_BYTES: usize = ATLAS_PIXELS * 16;
const CLASSIC: &[u32] = &[1, 25, 50, 100];
const FILM: &[u32] = &[100];
const CLASSIC_VERSION: &str = "photo-filter-v1/observed-delta64/planes0-1-25-50-100/manual-trilinear-f32/linear-strength/HDR-boundary-residual-mono-noir-endpoint-v2/alpha-bypass65535";
const FILM_VERSION: &str = "spektrafilm-v1/srgb-axis64/linear-delta/endpoint-strength/HDR-boundary-residual/alpha-bypass65535";
const INPUT_PROFILE: &str = "2b3aa1645779a9e634744faf9b01e9102b0c9b88fd6deced7934df86b949af7e";

pub fn exposure_gain(ev: f64) -> f64 {
    let gain = libm::exp2(ev);
    if ev.is_finite() && gain.is_finite() && gain > 0.0 {
        gain
    } else {
        f64::NAN
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
#[repr(C)]
pub struct FilterBinding {
    pub low_percent: u32,
    pub high_percent: u32,
    pub weight: f32,
    pub normalized_amount: f32,
    pub hdr_mode: u32,
    pub repair_raw_alpha: u32,
}
impl FilterBinding {
    pub fn new(family: u32, amount: f64, repair: u32) -> Result<Self, String> {
        if family > 2 || repair > 1 || !(0.0..=100.0).contains(&amount) {
            return Err("invalid filter family, amount or RAW transport flag".into());
        }
        let mut result = Self {
            repair_raw_alpha: repair,
            ..Self::default()
        };
        if amount == 0.0 {
            return Ok(result);
        }
        let stops = if family == 2 { FILM } else { CLASSIC };
        let index = stops.partition_point(|&p| f64::from(p) < amount);
        let high = stops[index];
        let low = if amount == f64::from(high) {
            high
        } else if index == 0 {
            0
        } else {
            stops[index - 1]
        };
        result.low_percent = low;
        result.high_percent = high;
        result.weight = if low == high {
            0.0
        } else {
            ((amount - f64::from(low)) / f64::from(high - low)) as f32
        };
        result.normalized_amount = (amount / 100.0) as f32;
        result.hdr_mode = if family != 1 {
            0
        } else if amount == 100.0 {
            2
        } else {
            1
        };
        Ok(result)
    }
}
fn family(look: &str) -> Result<u32, String> {
    match look {
        "original" | "vivid" | "vividWarm" | "vividCool" | "dramatic" | "dramaticWarm"
        | "dramaticCool" | "silvertone" => Ok(0),
        "mono" | "noir" => Ok(1),
        "spektraPortra400Endura" | "spektraVelvia100" | "spektraVision250D2383" => Ok(2),
        _ => Err(format!("unknown photo filter {look}")),
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct Catalog {
    schema_version: u32,
    operator_version: String,
    representation: String,
    cube_dimension: u32,
    atlas_width: u32,
    atlas_height: u32,
    axis_codes: Vec<u32>,
    #[serde(rename = "inputICCsha256")]
    input_profile: String,
    alpha_policy: String,
    hdr_policy: String,
    #[serde(rename = "sourceBindingsSHA256")]
    source_hash: String,
    #[serde(rename = "builderSHA256")]
    builder_hash: String,
    looks: Vec<Look>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Look {
    id: String,
    planes: Vec<Plane>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct Plane {
    intensity_percent: u32,
    file: String,
    byte_count: usize,
    sha256: String,
}

fn digest_valid(s: &str) -> bool {
    s.len() == 64
        && s.bytes()
            .all(|v| v.is_ascii_hexdigit() && !v.is_ascii_uppercase())
}
fn bounded_file(path: &Path, max: usize) -> Result<Vec<u8>, String> {
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        // The installed catalog accepts regular files, including when an asset is replaced.
        options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    let file = options
        .open(path)
        .map_err(|e| format!("{}: {e}", path.display()))?;
    let meta = file.metadata().map_err(|e| e.to_string())?;
    if !meta.is_file() || meta.len() > max as u64 {
        return Err("invalid resource length".into());
    }
    let mut data = Vec::with_capacity(meta.len() as usize);
    file.take(max as u64 + 1)
        .read_to_end(&mut data)
        .map_err(|e| e.to_string())?;
    if data.len() > max {
        return Err("resource grew while reading".into());
    }
    Ok(data)
}
impl Catalog {
    fn read(directory: &Path, film: bool) -> Result<Self, String> {
        let bytes = bounded_file(&directory.join("catalog-v1.json"), 65536)?;
        let c: Self =
            serde_json::from_slice(&bytes).map_err(|e| format!("invalid filter catalog: {e}"))?;
        let stops = if film { FILM } else { CLASSIC };
        if c.schema_version != 1
            || c.cube_dimension != 64
            || (c.atlas_width, c.atlas_height) != (512, 512)
            || !c
                .axis_codes
                .iter()
                .copied()
                .eq((0..64).map(|i| (65535 * i + 31) / 63))
            || c.input_profile != INPUT_PROFILE
            || c.representation != "linear-delta64-rgba32f-v1"
            || c.alpha_policy != "source-alpha-preserved/lowalpha-1over65535-bypass"
            || c.operator_version != if film { FILM_VERSION } else { CLASSIC_VERSION }
            || c.hdr_policy
                != if film {
                    "boundary-residual-v1"
                } else {
                    "boundary-residual-mono-noir-endpoint-v2"
                }
            || !digest_valid(&c.source_hash)
            || !digest_valid(&c.builder_hash)
            || c.looks.is_empty()
            || c.looks.len() > if film { 3 } else { 9 }
        {
            return Err("unsupported filter catalog contract".into());
        }
        let mut ids = HashSet::new();
        for look in &c.looks {
            let mut levels = look
                .planes
                .iter()
                .map(|p| p.intensity_percent)
                .collect::<Vec<_>>();
            levels.sort_unstable();
            if look.id == "original"
                || (family(&look.id)? == 2) != film
                || !ids.insert(&look.id)
                || levels != stops
            {
                return Err("invalid look or endpoints in catalog".into());
            }
            for p in &look.planes {
                if p.file != format!("{}-{:03}.delta64.rgba32f", look.id, p.intensity_percent)
                    || p.byte_count != ATLAS_BYTES
                    || !digest_valid(&p.sha256)
                {
                    return Err("invalid plane metadata".into());
                }
            }
        }
        Ok(c)
    }
}
#[derive(Default)]
pub(crate) struct AtlasSet {
    pub pixels: Vec<Pixel>,
    pub digests: Vec<String>,
}
impl AtlasSet {
    fn load_plane(&mut self, directory: &Path, plane: &Plane) -> Result<usize, String> {
        if let Some(index) = self.digests.iter().position(|s| s == &plane.sha256) {
            return Ok(index);
        }
        let data = bounded_file(&directory.join(&plane.file), ATLAS_BYTES)?;
        if data.len() != ATLAS_BYTES || format!("{:x}", Sha256::digest(&data)) != plane.sha256 {
            return Err(format!("invalid payload {}", plane.file));
        }
        self.pixels.reserve(ATLAS_PIXELS);
        for b in data.as_chunks::<16>().0 {
            let pixel: [f32; 4] = std::array::from_fn(|n| {
                f32::from_le_bytes(b[n * 4..n * 4 + 4].try_into().unwrap())
            });
            if pixel[3].to_bits() != 1.0f32.to_bits()
                || !pixel[..3].iter().all(|v| (-1.0..=1.0).contains(v))
            {
                return Err("invalid atlas node".into());
            }
            self.pixels.push(pixel);
        }
        let index = self.digests.len();
        self.digests.push(plane.sha256.clone());
        Ok(index)
    }
}
pub(crate) struct AtlasLoader<'a> {
    root: Option<&'a Path>,
    catalogs: HashMap<bool, Catalog>,
    pub assets: AtlasSet,
}
impl<'a> AtlasLoader<'a> {
    pub fn new(root: Option<&'a Path>) -> Self {
        Self {
            root,
            catalogs: HashMap::new(),
            assets: AtlasSet::default(),
        }
    }
    pub fn parameters(
        &mut self,
        look: &str,
        amount: f64,
        repair: bool,
    ) -> Result<[[f32; 4]; 3], String> {
        let family = family(look)?;
        let mut binding = FilterBinding::new(family, amount, repair as u32)?;
        if look == "original" {
            binding = FilterBinding::default();
        }
        let mut rows = [[0.0; 4]; 3];
        if binding.high_percent == 0 {
            rows[1][3] = 1.0;
            return Ok(rows);
        }
        let root = self
            .root
            .ok_or("active photo filter requires a catalog resource root")?;
        let film = family == 2;
        let directory = if film {
            root.join("Spektrafilm")
        } else {
            root.to_path_buf()
        };
        let catalog = match self.catalogs.entry(film) {
            std::collections::hash_map::Entry::Occupied(e) => e.into_mut(),
            std::collections::hash_map::Entry::Vacant(e) => {
                e.insert(Catalog::read(&directory, film)?)
            }
        };
        let planes = &catalog
            .looks
            .iter()
            .find(|v| v.id == look)
            .ok_or("filter unavailable in catalog")?
            .planes;
        let mut load = |level| {
            self.assets.load_plane(
                &directory,
                planes
                    .iter()
                    .find(|p| p.intensity_percent == level)
                    .ok_or("missing filter plane")?,
            )
        };
        let high = load(binding.high_percent)?;
        let low = if binding.low_percent == 0 || binding.low_percent == binding.high_percent {
            high
        } else {
            load(binding.low_percent)?
        };
        rows[0] = [
            binding.weight,
            binding.normalized_amount,
            binding.hdr_mode as f32,
            binding.repair_raw_alpha as f32,
        ];
        rows[1] = [
            low as f32,
            high as f32,
            (binding.low_percent == 0) as u8 as f32,
            0.0,
        ];
        Ok(rows)
    }
}
