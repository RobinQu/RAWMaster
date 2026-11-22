use super::*;
use std::fs::File;
use std::io::{Cursor, Read, Seek, SeekFrom};
const MAX_LEVEL: u64 = 128 * 1024 * 1024;
#[derive(Default, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct Look {
    pub candidate: bool,
    pub decoded: bool,
    pub revision_bound: bool,
    pub cache_uuid: Option<String>,
    pub cache_digest: Option<String>,
    pub develop_digest: Option<String>,
    pub level: Option<u32>,
    pub width: Option<u16>,
    pub height: Option<u16>,
    pub resource: Option<Resource>,
    pub state: String,
}
fn decode(bytes: &[u8]) -> Option<(u16, u16)> {
    if !bytes.starts_with(&[0xff, 0xd8, 0xff]) || !bytes.ends_with(&[0xff, 0xd9]) {
        return None;
    }
    let mut decoder = jpeg_decoder::Decoder::new(Cursor::new(bytes));
    decoder.set_max_decoding_buffer_size(256 * 1024 * 1024);
    decoder.read_info().ok()?;
    let i = decoder.info()?;
    if i.width == 0 || i.height == 0 || u64::from(i.width) * u64::from(i.height) > 64 * 1024 * 1024
    {
        return None;
    }
    // Validate the entire compressed scan with reduced IDCT output and retain the full-resolution JPEG.
    decoder.scale(512, 512).ok()?;
    let raster = decoder.decode().ok()?;
    if raster.is_empty() {
        return None;
    }
    Some((i.width, i.height))
}
fn token(s: &str) -> bool {
    (8..=96).contains(&s.len()) && s.bytes().all(|c| c.is_ascii_hexdigit() || c == b'-')
}
fn packed(f: &mut File) -> Result<Vec<(u32, u64, u64)>> {
    let end = f.metadata()?.len();
    let mut offset = 0u64;
    let mut levels = Vec::new();
    while offset < end {
        f.seek(SeekFrom::Start(offset))?;
        let mut header = [0; 24];
        f.read_exact(&mut header)?;
        if &header[..4] != b"AgHg" {
            return Err("Unknown packed cache record".into());
        }
        let len = u16::from_be_bytes([header[4], header[5]]) as u64;
        let size = u64::from_be_bytes(header[8..16].try_into()?);
        let padding = u64::from_be_bytes(header[16..24].try_into()?);
        if !(24..=256).contains(&len) {
            return Err("Invalid packed cache header".into());
        }
        let start = offset
            .checked_add(len)
            .ok_or("Invalid packed cache length")?;
        offset = start
            .checked_add(size)
            .and_then(|n| n.checked_add(padding))
            .filter(|n| *n <= end)
            .ok_or("Truncated packed cache record")?;
        let mut label = vec![0; (len - 24) as usize];
        f.read_exact(&mut label)?;
        if let Ok(s) = std::str::from_utf8(&label) {
            if let Some(n) = s
                .trim_end_matches('\0')
                .strip_prefix("level_")
                .and_then(|v| v.parse::<u32>().ok())
            {
                if (4..=MAX_LEVEL).contains(&size) {
                    levels.push((n, start, size));
                }
            }
        }
    }
    levels.sort_unstable_by(|a, b| b.0.cmp(&a.0));
    Ok(levels)
}
pub(super) fn supported(db: &Connection) -> Result<bool> {
    let e = source::columns(db, "ImageCacheEntry")?;
    let p = source::columns(db, "Pyramid")?;
    Ok(["imageId", "uuid", "digest"]
        .iter()
        .all(|name| e.iter().any(|v| v == name))
        && ["uuid", "digest"]
            .iter()
            .all(|name| p.iter().any(|v| v == name)))
}
pub(super) fn inventory(index: &Connection, pv: Option<&Connection>, cache: &Path) -> Result<()> {
    use std::collections::{BTreeMap, BTreeSet};
    index.execute_batch("CREATE TABLE cache_files(relative_path TEXT PRIMARY KEY,stamp TEXT NOT NULL) WITHOUT ROWID")?;
    let Some(pv) = pv else { return Ok(()) };
    if !supported(pv)? {
        return Ok(());
    }
    let mut paths = BTreeMap::<PathBuf, BTreeSet<String>>::new();
    let mut q=pv.prepare("SELECT DISTINCT CAST(e.uuid AS TEXT),CAST(e.digest AS TEXT) FROM ImageCacheEntry e JOIN Pyramid p ON p.uuid=e.uuid AND p.digest=e.digest WHERE e.uuid IS NOT NULL AND e.digest IS NOT NULL ORDER BY 1,2")?;
    for v in q.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))? {
        let (u, d) = v?;
        if token(&u) && token(&d) {
            paths
                .entry(Path::new(&u[..1].to_ascii_uppercase()).join(u[..4].to_ascii_uppercase()))
                .or_default()
                .insert(format!("{u}-{d}"));
        }
    }
    let base = cache.canonicalize()?;
    let mut write = index.prepare("INSERT INTO cache_files VALUES(?1,?2)")?;
    for (sub, names) in paths {
        let dir = cache.join(&sub);
        if !dir.is_dir() || !dir.canonicalize()?.starts_with(&base) {
            continue;
        }
        let Ok(list) = fs::read_dir(&dir) else {
            continue;
        };
        let mut files = list.filter_map(|v| v.ok()).collect::<Vec<_>>();
        files.sort_by_key(|f| f.file_name());
        for f in files {
            let os = f.file_name();
            let Some(n) = os.to_str() else { continue };
            let stem = n.strip_suffix(".lrprev").or_else(|| {
                n.rsplit_once('_')
                    .filter(|(_, x)| x.parse::<u32>().is_ok())
                    .map(|(v, _)| v)
            });
            if !stem.is_some_and(|v| names.contains(v)) {
                continue;
            }
            if let Ok(Some(stamp)) = source::file_stamp(&f.path()) {
                write.execute(params![
                    sub.join(n).to_str(),
                    serde_json::to_string(&stamp)?
                ])?;
            }
        }
    }
    Ok(())
}
type Decoded = (u32, u16, u16, Vec<u8>, bool);
fn find_level(
    index: &Connection,
    cache: &Path,
    uuid: &str,
    digest: &str,
) -> Result<Option<Decoded>> {
    if !token(uuid) || !token(digest) {
        return Ok(None);
    }
    let dir = cache
        .join(uuid[..1].to_ascii_uppercase())
        .join(uuid[..4].to_ascii_uppercase());
    if !dir.is_dir() || !dir.canonicalize()?.starts_with(cache.canonicalize()?) {
        return Ok(None);
    }
    let observed = |file: &Path, sig: &source::Stamp| -> Result<bool> {
        let prior: Option<String> = index
            .prepare_cached("SELECT stamp FROM cache_files WHERE relative_path=?1")?
            .query_row(
                [file
                    .strip_prefix(cache)?
                    .to_str()
                    .ok_or("Invalid cache path")?],
                |r| r.get(0),
            )
            .optional()?;
        Ok(prior
            .as_deref()
            .map(serde_json::from_str::<source::Stamp>)
            .transpose()?
            .as_ref()
            == Some(sig))
    };
    let name = format!("{uuid}-{digest}");
    let prefix = format!("{name}_");
    let mut levels = Vec::new();
    for entry in fs::read_dir(&dir)? {
        let entry = entry?;
        let s = entry.file_name();
        if let Some(n) = s
            .to_str()
            .and_then(|s| s.strip_prefix(&prefix))
            .and_then(|n| n.parse::<u32>().ok())
        {
            levels.push((n, entry.path()));
        }
    }
    levels.sort_unstable_by(|a, b| b.0.cmp(&a.0));
    for (n, p) in levels {
        if let Some(sig) = source::file_stamp(&p)? {
            if sig.size > MAX_LEVEL {
                continue;
            }
            let bytes = fs::read(&p)?;
            if let Some((w, h)) = decode(&bytes) {
                if source::file_stamp(&p)?.as_ref() == Some(&sig) {
                    return Ok(Some((n, w, h, bytes, observed(&p, &sig)?)));
                }
            }
        }
    }
    let p = dir.join(format!("{name}.lrprev"));
    if let Some(sig) = source::file_stamp(&p)? {
        let mut f = File::open(&p)?;
        for (n, start, len) in packed(&mut f)? {
            f.seek(SeekFrom::Start(start))?;
            let mut bytes = vec![0; len as usize];
            f.read_exact(&mut bytes)?;
            if let Some((w, h)) = decode(&bytes) {
                if source::file_stamp(&p)?.as_ref() == Some(&sig) {
                    return Ok(Some((n, w, h, bytes, observed(&p, &sig)?)));
                }
            }
        }
    }
    Ok(None)
}
pub(super) fn get(ctx: &Context<'_>, image: i64, develop: Option<&str>) -> Result<Look> {
    let mut look = Look {
        state: if ctx.preview_expected {
            "unreadablePreviewIndex"
        } else {
            "noPreviewIndex"
        }
        .into(),
        develop_digest: develop.map(str::to_owned),
        ..Default::default()
    };
    let Some(pv) = ctx.preview.as_ref() else {
        return Ok(look);
    };
    if !ctx.preview_layout {
        look.state = "unsupportedPreviewIndex".into();
        return Ok(look);
    }
    let mut q=pv.prepare_cached("SELECT DISTINCT CAST(e.uuid AS TEXT),CAST(e.digest AS TEXT) FROM ImageCacheEntry e JOIN Pyramid p ON p.uuid=e.uuid AND p.digest=e.digest WHERE e.imageId=?1 ORDER BY 1,2")?;
    let candidates = q
        .query_map([image], |r| {
            Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
        })?
        .collect::<std::result::Result<Vec<_>, _>>()?;
    if candidates.is_empty() {
        look.state = "noImageCandidate".into();
        return Ok(look);
    }
    look.candidate = true;
    let exact = |d: &str| {
        develop.is_some_and(|v| {
            [32, 64].contains(&v.len())
                && v.bytes().all(|c| c.is_ascii_hexdigit())
                && v.eq_ignore_ascii_case(d)
        })
    };
    let selected = if candidates.len() == 1 {
        Some(&candidates[0])
    } else {
        let v = candidates
            .iter()
            .filter(|(_, d)| exact(d))
            .collect::<Vec<_>>();
        if v.len() == 1 {
            Some(v[0])
        } else {
            None
        }
    };
    let Some((uuid, digest)) = selected else {
        look.state = "ambiguousImageCandidates".into();
        return Ok(look);
    };
    look.cache_uuid = Some(uuid.clone());
    look.cache_digest = Some(digest.clone());
    let found = match find_level(
        &ctx.order,
        &source::cache_dir(&ctx.source_path),
        uuid,
        digest,
    ) {
        Ok(v) => v,
        Err(_) => {
            look.state = "damagedOrUnavailablePayload".into();
            return Ok(look);
        }
    };
    let Some((n, w, h, data, payload_unchanged)) = found else {
        look.state = "noDecodableLevel".into();
        return Ok(look);
    };
    look.resource = Some(source::bytes(ctx.catalog, &data, "historicalLook")?);
    look.level = Some(n);
    look.width = Some(w);
    look.height = Some(h);
    look.decoded = true;
    // Index association is per Adobe image ID. Equal independently recorded recipe/cache digests
    // can bind a revision only while both live containers still match their frozen fingerprints.
    look.revision_bound = ctx.coherent && payload_unchanged && exact(digest);
    look.state = if look.revision_bound {
        "revisionBound"
    } else {
        "decodedRevisionUncertain"
    }
    .into();
    Ok(look)
}
