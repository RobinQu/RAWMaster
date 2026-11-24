use super::files::{absolute, hexsum, part, relative};
use super::{Blob, Mode, Result};
use rusqlite::{Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};
use std::io::Read;
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, Ord, PartialOrd, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Original {
    pub file_id: String,
    pub asset_id: String,
    pub project_id: String,
    pub content_id: String,
    pub scope_id: String,
    pub filename: String,
    pub relative_path: String,
    pub object: Blob,
}

impl Original {
    pub fn restored_path(&self) -> PathBuf {
        let key = hexsum(
            &serde_json::to_vec(&[&self.file_id, &self.content_id, &self.filename])
                .expect("string serialization"),
        );
        Path::new("Originals").join(key).join(&self.filename)
    }
}

#[derive(Clone, Debug, Ord, PartialOrd, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Resource {
    pub id: String,
    pub kind: String,
    pub target: String,
    pub object: Blob,
    pub asset_id: Option<String>,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct RootSummary {
    #[serde(rename = "rootID")]
    pub root_id: String,
    pub kind: String,
    pub files: i64,
    pub path_hint: Option<String>,
}

#[derive(Clone)]
pub(super) enum Source {
    File(PathBuf),
    Bytes(Vec<u8>),
}

#[derive(Default)]
pub(super) struct Inventory {
    pub library_id: String,
    pub originals: BTreeSet<Original>,
    pub roots: Vec<RootSummary>,
    png_inputs: BTreeMap<Blob, (u32, u32)>,
    pub resources: BTreeSet<Resource>,
    pub deferred: BTreeSet<String>,
    pub copies: BTreeMap<Blob, Vec<Source>>,
    pub locations: BTreeMap<Original, BTreeSet<PathBuf>>,
    original_hashes: BTreeSet<String>,
    archive_root: Option<PathBuf>,
    active_assets: BTreeSet<String>,
    targets: BTreeMap<String, Blob>,
}

pub(super) fn has(db: &Connection, name: &str) -> Result<bool> {
    Ok(db.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_schema WHERE name=? AND type IN ('view','table'))",
        [name],
        |r| r.get(0),
    )?)
}
pub(super) fn text<'a>(v: &'a Value, key: &str) -> Result<&'a str> {
    v[key]
        .as_str()
        .filter(|t| !t.is_empty())
        .ok_or_else(|| format!("missing or invalid {key}").into())
}

fn artifact_blob(data: &Value) -> Result<Blob> {
    Blob::new(
        text(data, "sha256")?.into(),
        data["byteCount"]
            .as_i64()
            .ok_or("invalid artifact length")?,
    )
}

fn safe_resource_path(value: &str) -> Result<()> {
    relative(value)?;
    if value.split('/').any(|p| {
        p.starts_with('.')
            || matches!(
                p.to_ascii_lowercase().as_str(),
                "staging" | "cache" | "caches" | "originals" | "rawcache" | "raw-cache"
            )
    }) {
        return Err("cache or staging paths cannot be package resources".into());
    }
    Ok(())
}

impl Inventory {
    pub fn from_snapshot(db: &Connection, source_catalog: &Path, mode: Mode) -> Result<Self> {
        if !crate::readable_schema(db.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))?)
        {
            return Err("package operations require a supported catalog".into());
        }
        crate::validate_catalog_objects(db)?;
        if db.query_row("SELECT EXISTS(SELECT 1 FROM sqlite_schema WHERE type IN ('view','trigger') AND name NOT GLOB 'lc_*')",[],|r|r.get::<_,bool>(0))? {
            return Err("catalog contains an unrecognized executable schema object".into());
        }
        let mut inv = Self {
            library_id: super::library_id(db)?,
            ..Self::default()
        };
        let mut stmt = db.prepare("SELECT q.file_id,q.asset_id,q.project_id,q.content_id,q.scope_id,
            q.sha256,q.byte_count,q.path,a.data,o.host_snapshot FROM lc_archive_files q LEFT JOIN assets a ON a.id=q.asset_id
            JOIN lc_scopes s ON s.scope_id=q.scope_id JOIN lc_occurrences o ON o.session_id=s.session_id AND o.occurrence_id=s.occurrence_id
            ORDER BY q.file_id,q.asset_id,q.project_id,q.content_id,q.scope_id,q.path")?;
        let mut rows = stmt.query([])?;
        while let Some(row) = rows.next()? {
            let a: Value = serde_json::from_str(&row.get::<_, String>(8)?)?;
            let frozen = row
                .get::<_, Option<String>>(9)?
                .map(|v| serde_json::from_str::<Value>(&v))
                .transpose()?;
            let name_source = frozen.as_ref().unwrap_or(&a);
            let entry = Original {
                file_id: row.get(0)?,
                asset_id: row.get(1)?,
                project_id: row.get(2)?,
                content_id: row.get(3)?,
                scope_id: row.get(4)?,
                object: Blob::new(row.get(5)?, row.get(6)?)?,
                filename: text(name_source, "filename")?.to_owned(),
                relative_path: text(name_source, "relativePath")?.to_owned(),
            };
            part(&entry.filename)?;
            relative(&entry.relative_path)?;
            if [
                &entry.file_id,
                &entry.asset_id,
                &entry.content_id,
                &entry.project_id,
                &entry.scope_id,
            ]
            .iter()
            .any(|k| k.is_empty())
            {
                return Err("incomplete original eligibility".into());
            }
            if text(&a, "id")? != entry.asset_id
                || frozen.as_ref().is_some_and(|v| {
                    v["fileSize"].as_i64() != Some(entry.object.bytes as i64)
                        || !v["contentHash"]
                            .as_str()
                            .is_some_and(|h| h.eq_ignore_ascii_case(&entry.object.sha256))
                })
                || (a["contentHash"]
                    .as_str()
                    .is_some_and(|hash| hash.eq_ignore_ascii_case(&entry.object.sha256))
                    && a["fileSize"].as_i64() != Some(entry.object.bytes as i64))
                || Path::new(&entry.relative_path)
                    .file_name()
                    .and_then(|n| n.to_str())
                    != Some(entry.filename.as_str())
            {
                return Err("original metadata conflicts with the authorized file".into());
            }
            inv.original_hashes.insert(entry.object.sha256.clone());
            inv.active_assets.insert(entry.asset_id.clone());
            inv.originals.insert(entry.clone());
            if let Some(p) = row.get::<_, Option<String>>(7)? {
                let Ok(path) = absolute(Path::new(&p)) else {
                    continue;
                };
                inv.locations
                    .entry(entry.clone())
                    .or_default()
                    .insert(path.clone());
                if mode == Mode::Full {
                    inv.copies
                        .entry(entry.object.clone())
                        .or_default()
                        .push(Source::File(path));
                }
            }
        }
        drop(rows);
        drop(stmt);
        if has(db, "lc_replicas")? {
            let mut q=db.prepare("SELECT r.root_id,r.kind,count(DISTINCT r.file_id),
              coalesce(max(nullif(roots.local_path,'')),min(CASE WHEN r.path LIKE '/%' AND r.relative_path!=''
                AND substr(r.path,-length(r.relative_path)-1)='/'||r.relative_path THEN
                CASE WHEN length(r.path)=length(r.relative_path)+1 THEN '/' ELSE substr(r.path,1,length(r.path)-length(r.relative_path)-1) END END))
              FROM lc_replicas r LEFT JOIN lc_roots roots ON roots.root_id=r.root_id WHERE EXISTS
              (SELECT 1 FROM lc_archive_files a WHERE a.file_id=r.file_id AND a.content_id=r.content_id)
              AND (r.source_asset_id IS NULL OR EXISTS(SELECT 1 FROM lc_scopes s WHERE s.asset_id=r.source_asset_id AND s.content_id=r.content_id))
              GROUP BY r.root_id,r.kind ORDER BY r.root_id,r.kind")?;
            let mut rows = q.query([])?;
            while let Some(r) = rows.next()? {
                inv.roots.push(RootSummary {
                    root_id: r.get(0)?,
                    kind: r.get(1)?,
                    files: r.get(2)?,
                    path_hint: r.get(3)?,
                });
            }
        }

        // Digest-only exclusion fence. No historical/excluded directory is read or traversed.
        if has(db, "lc_contents")? {
            let mut q = db.prepare("SELECT sha256 FROM lc_contents WHERE sha256 IS NOT NULL")?;
            let hashes = q.query_map([], |r| r.get::<_, String>(0))?;
            for hash in hashes {
                inv.original_hashes.insert(hash?.to_lowercase());
            }
        }
        let mut q = db.prepare("SELECT json_extract(data,'$.contentHash') FROM assets WHERE json_type(data,'$.contentHash')='text'")?;
        for hash in q.query_map([], |r| r.get::<_, String>(0))? {
            inv.original_hashes.insert(hash?.to_lowercase());
        }
        for (table, field) in [
            ("editing_versions", "$.source.contentSHA256"),
            ("processing_jobs", "$.request.source.contentSHA256"),
        ] {
            if has(db, table)? {
                let mut q=db.prepare(&format!("SELECT DISTINCT json_extract(data,?1) FROM {table} WHERE json_type(data,?1)='text'"))?;
                for hash in q.query_map([field], |r| r.get::<_, String>(0))? {
                    inv.original_hashes.insert(hash?.to_lowercase());
                }
            }
        }
        let base = source_catalog.parent().ok_or("missing catalog root")?;
        if has(db, "lc_resources")? {
            let mut stmt = db.prepare("SELECT resource_id,kind,relative_path,sha256,byte_count,source_asset_id FROM lc_resources ORDER BY resource_id")?;
            let mut rows = stmt.query([])?;
            while let Some(row) = rows.next()? {
                let id: String = row.get(0)?;
                let kind: String = row.get(1)?;
                let rel: String = row.get(2)?;
                let asset: Option<String> = row.get(5)?;
                let blob = Blob::new(row.get(3)?, row.get(4)?)?;
                if !matches!(
                    kind.as_str(),
                    "historicalLook"
                        | "adobePayload"
                        | "sidecar"
                        | "derivedPhoto"
                        | "derivedVideo"
                        | "recipeResource"
                ) {
                    return Err(format!("unknown managed resource kind: {kind}").into());
                }
                if id.is_empty() {
                    return Err("missing resource identity".into());
                }
                safe_resource_path(&rel)?;
                if crate::resources::object_path(&blob.sha256)? != Path::new(&rel) {
                    return Err("unregistered managed object path".into());
                }
                if let Some(a) = &asset {
                    if !db.query_row(
                        "SELECT EXISTS(SELECT 1 FROM assets WHERE id=?)",
                        [a],
                        |r| r.get::<_, bool>(0),
                    )? {
                        return Err("managed resource owner is absent from the catalog".into());
                    }
                }
                if kind == "sidecar"
                    && asset
                        .as_ref()
                        .is_some_and(|a| !inv.active_assets.contains(a))
                {
                    inv.deferred.insert(format!("excludedResource/{id}"));
                    continue;
                }
                inv.add(
                    Resource {
                        id,
                        kind,
                        target: format!("LibraryResources/{rel}"),
                        object: blob,
                        asset_id: asset,
                    },
                    Some(Source::File(base.join("LibraryResources").join(rel))),
                    mode,
                )?;
            }
        }
        if has(db, "metadata")? {
            let raw: Option<String> = db
                .query_row(
                    "SELECT value FROM metadata WHERE key='editingArchiveRoot'",
                    [],
                    |r| r.get(0),
                )
                .optional()?;
            inv.archive_root = raw.map(|s| absolute(Path::new(&s))).transpose()?;
        }
        inv.editing(db, mode)?;
        let mut lengths = BTreeMap::new();
        for obj in inv
            .originals
            .iter()
            .map(|o| &o.object)
            .chain(inv.resources.iter().map(|r| &r.object))
        {
            if lengths
                .insert(&obj.sha256, obj.bytes)
                .is_some_and(|old| old != obj.bytes)
            {
                return Err("one digest claims conflicting lengths".into());
            }
        }
        Ok(inv)
    }

    pub fn required(&self, mode: Mode) -> BTreeSet<Blob> {
        let mut out: BTreeSet<_> = self.resources.iter().map(|r| r.object.clone()).collect();
        if mode == Mode::Full {
            out.extend(self.originals.iter().map(|o| o.object.clone()));
        }
        out
    }

    pub fn check_input(&self, obj: &Blob, path: &Path) -> Result<()> {
        if let Some((width, height)) = self.png_inputs.get(obj) {
            let mut bytes = [0u8; 29];
            super::files::regular(path)?.read_exact(&mut bytes)?;
            if &bytes[..16] != b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR"
                || bytes[16..20] != width.to_be_bytes()
                || bytes[20..24] != height.to_be_bytes()
                || bytes[24] != 8
                || !matches!(bytes[25], 2 | 6)
                || bytes[26] != 0
                || bytes[27] != 0
                || bytes[28] > 1
            {
                return Err("frozen processing input differs from its bounded RGB render".into());
            }
        }
        Ok(())
    }

    fn add(&mut self, resource: Resource, source: Option<Source>, mode: Mode) -> Result<()> {
        let mut source = source;
        if self.original_hashes.contains(&resource.object.sha256) {
            let qualified = self.originals.iter().any(|r| {
                Some(&r.asset_id) == resource.asset_id.as_ref() && r.object == resource.object
            });
            if !qualified || mode == Mode::Catalog {
                self.deferred.insert(format!("sourceBytes/{}", resource.id));
                return Ok(());
            }
            // An original may only be supplied by lc_archive_files, even when a job cached it.
            source = None;
        }
        if self
            .targets
            .insert(resource.target.clone(), resource.object.clone())
            .is_some_and(|old| old != resource.object)
        {
            return Err("two resource records claim different bytes at the same path".into());
        }
        if let Some(s) = source {
            self.copies
                .entry(resource.object.clone())
                .or_default()
                .push(s);
        }
        self.resources.insert(resource);
        Ok(())
    }

    fn artifact(
        &mut self,
        id: &str,
        kind: &str,
        asset: &str,
        a: &Value,
        prefix: &str,
        mode: Mode,
    ) -> Result<()> {
        let rel = text(a, "relativePath")?;
        relative(rel)?;
        if !rel.starts_with(prefix)
            || rel[prefix.len()..].is_empty()
            || rel[prefix.len()..].contains('/')
        {
            return Err("invalid editing artifact ownership or relative path".into());
        }
        let blob = artifact_blob(a)?;
        let encoding = text(a, "encoding")?.to_lowercase();
        let allowable = matches!(
            encoding.as_str(),
            "png"
                | "public.png"
                | "image/png"
                | "jpeg"
                | "jpg"
                | "public.jpeg"
                | "image/jpeg"
                | "tiff"
                | "tif"
                | "public.tiff"
                | "image/tiff"
                | "heic"
                | "public.heic"
                | "image/heic"
                | "webp"
                | "image/webp"
                | "openexr"
                | "exr"
        );
        if kind == "processingInput" && !self.active_assets.contains(asset)
            || !allowable && !self.original_hashes.contains(&blob.sha256)
        {
            self.deferred.insert(format!("unarchivedEditingInput/{id}"));
            if kind != "processingInput" {
                return Err(
                    "unknown editing result encoding; recover or register its resource first"
                        .into(),
                );
            }
            return Ok(());
        }
        let root = self
            .archive_root
            .as_ref()
            .ok_or("editing archive root is missing")?;
        self.add(
            Resource {
                id: id.into(),
                kind: kind.into(),
                target: format!("EditingArchive/{rel}"),
                object: blob,
                asset_id: Some(asset.into()),
            },
            Some(Source::File(root.join(rel))),
            mode,
        )
    }

    fn receipt(
        &mut self,
        id: &str,
        rel: &str,
        value: &Value,
        asset: &str,
        mode: Mode,
    ) -> Result<()> {
        let bytes = serde_json::to_vec(value)?;
        self.add(
            Resource {
                id: id.into(),
                kind: "editingReceipt".into(),
                target: format!("EditingArchive/{rel}"),
                object: Blob {
                    sha256: hexsum(&bytes),
                    bytes: bytes.len() as u64,
                },
                asset_id: Some(asset.into()),
            },
            Some(Source::Bytes(bytes)),
            mode,
        )
    }

    fn editing(&mut self, db: &Connection, mode: Mode) -> Result<()> {
        if has(db, "editing_versions")? {
            let mut q = db.prepare("SELECT id,work_id,data FROM editing_versions ORDER BY id")?;
            let mut rows = q.query([])?;
            while let Some(r) = rows.next()? {
                let id: String = r.get(0)?;
                let work: String = r.get(1)?;
                let v: Value = serde_json::from_str(&r.get::<_, String>(2)?)?;
                if v["artifact"].is_null() {
                    continue;
                }
                if text(&v, "id")? != id || text(&v, "workID")? != work || v["kind"] == "original" {
                    return Err("invalid editing version".into());
                }
                let owner = text(&v["source"], "assetID")?;
                self.original_hashes
                    .insert(text(&v["source"], "contentSHA256")?.to_lowercase());
                let rec: String = db.query_row(
                    "SELECT data FROM archive_publications WHERE version_id=?",
                    [&id],
                    |x| x.get(0),
                )?;
                let receipt: Value = serde_json::from_str(&rec)?;
                let rid = text(&receipt, "id")?;
                part(rid)?;
                part(&id)?;
                part(&work)?;
                if receipt["version"] != v {
                    return Err(
                        "editing publication does not describe its persisted version".into(),
                    );
                }
                self.artifact(
                    &id,
                    "editingVersion",
                    owner,
                    &v["artifact"],
                    &format!("artifacts/{work}/{id}/{rid}."),
                    mode,
                )?;
                if self.targets.contains_key(&format!(
                    "EditingArchive/{}",
                    text(&v["artifact"], "relativePath")?
                )) {
                    self.receipt(
                        &format!("receipt/{rid}"),
                        &format!("receipts/{rid}.json"),
                        &receipt,
                        owner,
                        mode,
                    )?;
                }
            }
        }
        if has(db, "processing_jobs")? {
            let mut q = db.prepare("SELECT id,data FROM processing_jobs ORDER BY id")?;
            let mut rows = q.query([])?;
            while let Some(r) = rows.next()? {
                let id: String = r.get(0)?;
                let job: Value = serde_json::from_str(&r.get::<_, String>(1)?)?;
                if text(&job, "id")? != id {
                    return Err("job identity mismatch".into());
                }
                part(&id)?;
                let req = &job["request"];
                let owner = text(&req["source"], "assetID")?;
                self.original_hashes
                    .insert(text(&req["source"], "contentSHA256")?.to_lowercase());
                let input = &req["inputArtifact"];
                let rel = text(input, "relativePath")?;
                let fields: Vec<_> = rel.split('/').collect();
                if fields.len() != 3 || fields[0] != ".inputs" {
                    return Err("unrecognized frozen job input".into());
                }
                relative(rel)?;
                let input_blob = artifact_blob(input)?;
                let input_id = format!("job/{id}");
                let dimensions = input["pixelWidth"]
                    .as_u64()
                    .zip(input["pixelHeight"].as_u64())
                    .filter(|&(w, h)| {
                        w > 0 && h > 0 && w.checked_mul(h).is_some_and(|pixels| pixels <= 1_048_576)
                    });
                let bounded_rgb = req["configuration"]["inputPolicy"] == "bounded-png8-srgb-1mp-v1"
                    && matches!(
                        input["encoding"]
                            .as_str()
                            .map(str::to_ascii_lowercase)
                            .as_deref(),
                        Some("png" | "public.png" | "image/png")
                    )
                    && input["bitDepth"] == 8
                    && dimensions.is_some();
                if self.original_hashes.contains(&input_blob.sha256) || bounded_rgb {
                    self.artifact(
                        &input_id,
                        "processingInput",
                        owner,
                        input,
                        &format!(".inputs/{}/", fields[1]),
                        mode,
                    )?;
                    if bounded_rgb
                        && !self.original_hashes.contains(&input_blob.sha256)
                        && self.targets.contains_key(&format!("EditingArchive/{rel}"))
                    {
                        if let Some((w, h)) = dimensions {
                            self.png_inputs.insert(input_blob, (w as u32, h as u32));
                        }
                    }
                } else {
                    self.deferred
                        .insert(format!("unarchivedEditingInput/{input_id}"));
                }
                for attempt in job["attempts"].as_array().ok_or("missing job attempts")? {
                    if !attempt["pendingReceivedOutput"].is_null() {
                        return Err("reconcile pending editing receipts before backup".into());
                    }
                    let got = &attempt["receivedOutput"];
                    if got.is_null() {
                        continue;
                    }
                    let rid = text(got, "id")?;
                    let aid = text(attempt, "id")?;
                    part(rid)?;
                    part(aid)?;
                    if text(got, "jobID")? != id
                        || text(got, "attemptID")? != aid
                        || got["runID"] != attempt["runID"]
                    {
                        return Err("received output does not belong to its job attempt".into());
                    }
                    self.artifact(
                        &format!("received/{rid}"),
                        "receivedOutput",
                        owner,
                        &got["artifact"],
                        &format!(".received/{id}/{aid}/{rid}."),
                        mode,
                    )?;
                    if self.targets.contains_key(&format!(
                        "EditingArchive/{}",
                        text(&got["artifact"], "relativePath")?
                    )) {
                        self.receipt(
                            &format!("receivedReceipt/{rid}"),
                            &format!("received-receipts/{rid}.json"),
                            got,
                            owner,
                            mode,
                        )?;
                    }
                }
            }
        }
        Ok(())
    }
}
