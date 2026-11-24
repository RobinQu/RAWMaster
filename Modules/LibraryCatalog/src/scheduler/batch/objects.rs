//! V2 keeps the ordered batch small. Configuration and work/version JSON are independently
//! content-addressed and verified against their declared role and frozen source identity.
use super::manifest::{identifier, literal_stem, sha256};
use crate::{resources, Result};
use rusqlite::{params, Connection};
use serde::{de::IgnoredAny, Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs::{self, File, Metadata};
use std::io::{BufReader, Read};
use std::path::{Path, PathBuf};

// Two complete native recipes (work and version) can each contain 3 global plus 32 local
// 64³ Float32 LUTs. Their Codable size allowance is 214 MiB each, before the item envelope.
const MAX_BODY_BYTES: i64 = 512 * 1024 * 1024;

#[derive(Clone, Copy, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase")]
pub enum Role {
    Configuration,
    Item,
}

#[derive(Clone, Deserialize, Serialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Reference {
    sha256: String,
    byte_count: i64,
}

impl Reference {
    fn check(&self) -> Result<()> {
        if !sha256(&self.sha256) || !(1..=MAX_BODY_BYTES).contains(&self.byte_count) {
            return Err("invalid workbench resource digest or size".into());
        }
        Ok(())
    }
    fn resource(&self) -> Result<resources::Resource> {
        self.check()?;
        Ok(resources::Resource {
            resource_id: format!("wb032:sha256:{}", self.sha256),
            kind: "recipeResource".into(),
            relative_path: resources::object_path(&self.sha256)?
                .to_str()
                .ok_or("invalid resource path")?
                .into(),
            sha256: self.sha256.clone(),
            byte_count: self.byte_count,
            source_asset_id: None,
        })
    }
}

#[derive(Deserialize, Eq, PartialEq)]
struct Source {
    #[serde(rename = "projectID")]
    project: String,
    #[serde(rename = "assetID")]
    asset: String,
    #[serde(rename = "contentSHA256")]
    sha: String,
    #[serde(rename = "byteCount")]
    bytes: i64,
    #[serde(rename = "admissionFingerprint")]
    admission: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Item {
    ordinal: usize,
    #[serde(rename = "assetID")]
    asset_id: String,
    stem: String,
    #[serde(rename = "workID")]
    work_id: String,
    #[serde(rename = "versionID")]
    version_id: String,
    source: Source,
    body: Reference,
}

pub(super) struct Set {
    configuration: Reference,
    items: Vec<Item>,
}

enum Expected<'a> {
    Configuration,
    Item(&'a Item),
}

impl Set {
    pub fn new(configuration: &Value, items: &Value) -> Result<Self> {
        let set = Self {
            configuration: Reference::deserialize(configuration)?,
            items: Vec::<Item>::deserialize(items)?,
        };
        set.configuration.check()?;
        let mut assets = HashSet::new();
        for (i, item) in set.items.iter().enumerate() {
            item.body.check()?;
            if item.ordinal != i + 1
                || !assets.insert(&item.asset_id)
                || !identifier(&item.asset_id)
                || !literal_stem(&item.stem)
                || !identifier(&item.work_id)
                || !identifier(&item.version_id)
                || item.source.asset != item.asset_id
                || !identifier(&item.source.project)
                || !identifier(&item.source.admission)
                || item.source.bytes <= 0
                || !sha256(&item.source.sha)
            {
                return Err(format!("invalid compact workbench item at ordinal {}", i + 1).into());
            }
        }
        Ok(set)
    }
    fn select(&self, role: Role, ordinal: Option<usize>) -> Result<(&Reference, Expected<'_>)> {
        match (role, ordinal) {
            (Role::Configuration, None) => Ok((&self.configuration, Expected::Configuration)),
            (Role::Item, Some(n)) if n > 0 && n <= self.items.len() => {
                let item = &self.items[n - 1];
                Ok((&item.body, Expected::Item(item)))
            }
            _ => Err("invalid workbench resource role or ordinal".into()),
        }
    }
    pub fn verify(&self, catalog: &Path) -> Result<Vec<Verified>> {
        let members = std::iter::once((&self.configuration, Expected::Configuration))
            .chain(self.items.iter().map(|i| (&i.body, Expected::Item(i))));
        let mut seen = BTreeMap::<&str, (Verified, Identity)>::new();
        for (reference, expected) in members {
            if !seen.contains_key(reference.sha256.as_str()) {
                let (mut verified, identity) = read(catalog, reference, true, |input| {
                    identify_reader(input, &expected)
                })?;
                if let Identity::Configuration(extension) = &identity {
                    verified.extension = *extension;
                }
                seen.insert(&reference.sha256, (verified, identity));
            }
            let (verified, identity) = &seen[reference.sha256.as_str()];
            if verified.receipt.byte_count != reference.byte_count {
                return Err("inconsistent workbench resource sizes".into());
            }
            identity.matches(&expected)?;
        }
        Ok(seen.into_values().map(|(verified, _)| verified).collect())
    }
    pub fn load(
        &self,
        db: &Connection,
        catalog: &Path,
        role: Role,
        ordinal: Option<usize>,
    ) -> Result<Value> {
        let (reference, expected) = self.select(role, ordinal)?;
        require_registered(db, &reference.resource()?)?;
        let (_, body) = read(catalog, reference, false, |reader| {
            Ok(serde_json::from_reader::<_, Value>(reader)?)
        })?;
        let identity = match expected {
            Expected::Configuration => ConfigurationBody::deserialize(&body)?.identity()?,
            Expected::Item(_) => ItemBody::deserialize(&body)?.identity()?,
        };
        identity.matches(&expected)?;
        Ok(body)
    }
}

// Inspect only identity and role on a full-batch verification. Ignored adjustment payloads
// (including multi-MiB LUT strings) are streamed past instead of retained for every photograph.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ConfigurationBody {
    schema: u32,
    role: Role,
    #[serde(rename = "configuration", deserialize_with = "settings")]
    settings: Settings,
}
struct Settings {
    format: Option<Value>,
}
fn settings<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> std::result::Result<Settings, D::Error> {
    struct SettingsMap;
    impl<'de> serde::de::Visitor<'de> for SettingsMap {
        type Value = Settings;
        fn expecting(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            f.write_str("a workbench configuration object")
        }
        fn visit_map<A: serde::de::MapAccess<'de>>(
            self,
            mut map: A,
        ) -> std::result::Result<Self::Value, A::Error> {
            let mut format = None;
            while let Some(key) = map.next_key::<String>()? {
                if key == "format" {
                    if format.is_some() {
                        return Err(serde::de::Error::duplicate_field("format"));
                    }
                    format = Some(map.next_value()?);
                } else {
                    map.next_value::<IgnoredAny>()?;
                }
            }
            Ok(Settings { format })
        }
    }
    deserializer.deserialize_map(SettingsMap)
}
#[derive(Deserialize)]
struct Work {
    id: String,
    source: Source,
}
#[derive(Deserialize)]
struct Version {
    id: String,
    #[serde(rename = "workID")]
    work_id: String,
    source: Source,
    #[serde(rename = "recipe")]
    _recipe: HashMap<String, IgnoredAny>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ItemBody {
    schema: u32,
    role: Role,
    work: Work,
    version: Version,
}
enum Identity {
    Configuration(Option<&'static str>),
    Item {
        work: String,
        version: String,
        source: Source,
    },
}
impl ConfigurationBody {
    fn identity(self) -> Result<Identity> {
        if self.schema != 1 || self.role != Role::Configuration {
            return Err("invalid workbench configuration body".into());
        }
        Ok(Identity::Configuration(super::manifest::extension(
            self.settings.format.as_ref().and_then(Value::as_str),
        )))
    }
}
impl ItemBody {
    fn identity(self) -> Result<Identity> {
        if self.schema != 1
            || self.role != Role::Item
            || self.work.id != self.version.work_id
            || self.work.source != self.version.source
        {
            return Err("workbench body contains unrelated work or version".into());
        }
        Ok(Identity::Item {
            work: self.work.id,
            version: self.version.id,
            source: self.work.source,
        })
    }
}
impl Identity {
    fn matches(&self, expected: &Expected<'_>) -> Result<()> {
        match (self, expected) {
            (Identity::Configuration(_), Expected::Configuration) => Ok(()),
            (
                Identity::Item {
                    work,
                    version,
                    source,
                },
                Expected::Item(i),
            ) if work == &i.work_id && version == &i.version_id && source == &i.source => Ok(()),
            _ => Err(
                "workbench resource differs from its frozen role, work, version or source".into(),
            ),
        }
    }
}

fn identify_reader(reader: &mut dyn Read, expected: &Expected<'_>) -> Result<Identity> {
    match expected {
        Expected::Configuration => {
            serde_json::from_reader::<_, ConfigurationBody>(reader)?.identity()
        }
        Expected::Item(_) => serde_json::from_reader::<_, ItemBody>(reader)?.identity(),
    }
}

struct HashingReader<R> {
    source: R,
    hash: Sha256,
    bytes: u64,
}
impl<R: Read> Read for HashingReader<R> {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        let size = self.source.read(buf)?;
        self.hash.update(&buf[..size]);
        self.bytes += size as u64;
        Ok(size)
    }
}

pub(super) struct Verified {
    pub extension: Option<&'static str>,
    receipt: resources::Resource,
    path: PathBuf,
    metadata: Metadata,
}
impl Verified {
    fn unchanged(&self) -> Result<()> {
        let current = fs::symlink_metadata(&self.path)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt;
            if current.dev() != self.metadata.dev()
                || current.ino() != self.metadata.ino()
                || current.ctime() != self.metadata.ctime()
                || current.ctime_nsec() != self.metadata.ctime_nsec()
            {
                return Err("workbench resource identity changed during verification".into());
            }
        }
        if !current.is_file()
            || current.len() != self.metadata.len()
            || current.modified()? != self.metadata.modified()?
        {
            return Err("workbench resource changed during verification".into());
        }
        Ok(())
    }
    pub fn register(&self, db: &Connection) -> Result<()> {
        self.unchanged()?;
        resources::register(db, &self.receipt)
    }
    pub fn check(&self, db: &Connection) -> Result<()> {
        self.unchanged()?;
        require_registered(db, &self.receipt)
    }
}

fn require_registered(db: &Connection, receipt: &resources::Resource) -> Result<()> {
    let present: bool = db.query_row(
        "SELECT EXISTS(SELECT 1 FROM lc_resources WHERE resource_id=?1 AND kind='recipeResource'
        AND relative_path=?2 AND sha256=?3 AND byte_count=?4 AND source_asset_id IS NULL)",
        params![
            receipt.resource_id,
            receipt.relative_path,
            receipt.sha256,
            receipt.byte_count
        ],
        |r| r.get(0),
    )?;
    if !present {
        return Err("workbench resource is missing its catalog registration".into());
    }
    Ok(())
}

fn read<T>(
    catalog: &Path,
    reference: &Reference,
    durable: bool,
    decode: impl FnOnce(&mut dyn Read) -> Result<T>,
) -> Result<(Verified, T)> {
    let receipt = reference.resource()?;
    let root = catalog.parent().ok_or("missing catalog root")?;
    let storage = root.join("LibraryResources");
    let objects = storage.join("objects");
    let shard = objects.join(&receipt.sha256[..2]);
    let dirs = [root, storage.as_path(), objects.as_path(), shard.as_path()];
    for dir in dirs {
        if !fs::symlink_metadata(dir)?.is_dir() {
            return Err("expected a real workbench resource directory".into());
        }
    }
    let path = storage.join(&receipt.relative_path);
    let file = resources::open_regular(&path)?;
    let metadata = file.metadata()?;
    if metadata.len() != reference.byte_count as u64 {
        return Err("workbench resource has a different size".into());
    }
    let mut checked = HashingReader {
        source: (&file).take(metadata.len() + 1),
        hash: Sha256::new(),
        bytes: 0,
    };
    let body = decode(&mut BufReader::with_capacity(128 * 1024, &mut checked))?;
    if checked.bytes != metadata.len() || hex::encode(checked.hash.finalize()) != reference.sha256 {
        return Err("workbench resource SHA-256 mismatch".into());
    }
    if durable {
        file.sync_all()?;
        for dir in dirs.into_iter().rev() {
            File::open(dir)?.sync_all()?;
        }
    }
    let verified = Verified {
        extension: None,
        receipt,
        path,
        metadata,
    };
    verified.unchanged()?;
    Ok((verified, body))
}

pub(super) fn stage(catalog: &Path, path: &Path, sha: String, bytes: i64) -> Result<Value> {
    if !path.is_absolute() {
        return Err("workbench resource input requires an absolute path".into());
    }
    let reference = Reference {
        sha256: sha,
        byte_count: bytes,
    };
    let receipt = reference.resource()?;
    resources::stage_expected(
        catalog,
        path,
        &receipt.resource_id,
        &reference.sha256,
        reference.byte_count,
    )?;
    Ok(serde_json::json!({"resource":reference}))
}
