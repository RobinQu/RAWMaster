use super::*;
use std::collections::BTreeSet;
use std::os::unix::fs::MetadataExt;
use unicode_normalization::UnicodeNormalization;

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub(super) struct Stamp {
    device: u64,
    inode: u64,
    bytes: u64,
    changed: i64,
    nanos: i64,
}

pub(super) fn stamp(p: &Path) -> Result<Stamp> {
    let m = io::regular(p)?.metadata()?;
    Ok(Stamp {
        device: m.dev(),
        inode: m.ino(),
        bytes: m.len(),
        changed: m.mtime(),
        nanos: m.mtime_nsec(),
    })
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct Entry {
    #[serde(rename = "assetID")]
    pub asset: String,
    #[serde(rename = "fileID")]
    pub file: String,
    #[serde(rename = "contentID")]
    pub content: String,
    pub role: String,
    pub locator: Option<String>,
    pub source: PathBuf,
    pub destination: PathBuf,
    pub digest: Blob,
    pub stamp: Stamp,
}
pub(super) fn key(p: &Path) -> Result<String> {
    Ok(p.to_str()
        .ok_or("需要 UTF-8 文件名")?
        .nfc()
        .collect::<String>()
        .to_lowercase())
}
fn as_name(p: &Path) -> Result<&str> {
    p.file_name()
        .and_then(|s| s.to_str())
        .ok_or_else(|| "无法读取文件名".into())
}

fn append(
    entries: &mut Vec<Entry>,
    asset: &str,
    file: &str,
    content: &str,
    role: &str,
    source: PathBuf,
    destination: PathBuf,
    expected: Option<&Blob>,
) -> Result<()> {
    if source == destination || io::exists(&destination)? {
        return Err(format!("目标已存在或路径未变：{}", destination.display()).into());
    }
    let initial = stamp(&source)?;
    let digest = io::digest(&source)?;
    if stamp(&source)? != initial || expected.is_some_and(|e| e != &digest) {
        return Err(format!("来源内容已变化：{}", source.display()).into());
    }
    entries.push(Entry {
        asset: asset.into(),
        file: file.into(),
        content: content.into(),
        role: role.into(),
        locator: None,
        source,
        destination,
        digest,
        stamp: initial,
    });
    Ok(())
}

fn companions(entries: &mut Vec<Entry>, db: &Connection, original: &Entry) -> Result<()> {
    let dir = io::parent(&original.source)?;
    let target = io::parent(&original.destination)?;
    let old = as_name(&original.source)?;
    let new = as_name(&original.destination)?;
    let stem = original
        .source
        .file_stem()
        .and_then(|s| s.to_str())
        .ok_or("无法读取源文件干名")?;
    let to_stem = original
        .destination
        .file_stem()
        .and_then(|s| s.to_str())
        .ok_or("无法读取目标干名")?;
    let mut paths = std::fs::read_dir(dir)?
        .map(|r| r.map(|e| e.path()))
        .collect::<std::io::Result<Vec<_>>>()?;
    paths.sort();
    for p in paths {
        let Some(ext) = p.extension().and_then(|s| s.to_str()) else {
            continue;
        };
        if !matches!(ext.to_ascii_lowercase().as_str(), "xmp" | "acr") {
            continue;
        }
        let side_stem = p.file_stem().and_then(|s| s.to_str()).unwrap_or("");
        let to = if side_stem.eq_ignore_ascii_case(old) {
            new
        } else if side_stem.eq_ignore_ascii_case(stem) {
            let mut st=db.prepare("SELECT DISTINCT current_path FROM lc_asset_input WHERE current_path IS NOT NULL AND current_path!=?1 AND current_path LIKE ?2 ESCAPE '\\'")?;
            let prefix = dir
                .to_string_lossy()
                .replace('\\', "\\\\")
                .replace('%', "\\%")
                .replace('_', "\\_");
            let mut rows = st.query(params![original.source.to_str(), format!("{prefix}/%")])?;
            while let Some(row) = rows.next()? {
                let other = PathBuf::from(row.get::<_, String>(0)?);
                if other.parent() == Some(dir)
                    && other
                        .file_stem()
                        .and_then(|s| s.to_str())
                        .is_some_and(|s| s.eq_ignore_ascii_case(stem))
                {
                    return Err(format!("同名原件共用旁车，请先明确归属：{}", p.display()).into());
                }
            }
            to_stem
        } else {
            continue;
        };
        append(
            entries,
            &original.asset,
            &original.file,
            &original.content,
            "sidecar",
            p.clone(),
            target.join(format!("{to}.{ext}")),
            None,
        )?;
    }
    Ok(())
}

pub(super) fn materialize(db: &Connection, body: &Value) -> Result<(Vec<Entry>, String)> {
    let requests = body["items"]
        .as_array()
        .filter(|a| !a.is_empty())
        .ok_or("请选择受管文件")?;
    let mut entries = vec![];
    let mut names = BTreeSet::new();
    for item in requests {
        let asset = field(item, "assetID")?;
        let dir = io::absolute(Path::new(field(item, "directory")?))?;
        io::directory(&dir, false)?;
        let name = field(item, "filename")?;
        io::part(name)?;
        let (file,content,source,sha,length):(String,String,String,String,i64)=db.query_row(
            "SELECT s.file_id,s.content_id,i.current_path,c.sha256,c.byte_count FROM lc_scopes s
            JOIN lc_asset_input i USING(asset_id) JOIN lc_contents c ON c.content_id=s.content_id
            WHERE s.asset_id=?1 AND i.content_id=s.content_id AND EXISTS(SELECT 1 FROM lc_replicas r
              WHERE r.file_id=s.file_id AND r.content_id=s.content_id AND r.state='available' AND r.path=i.current_path AND r.kind IN ('managed','restored'))
            AND NOT EXISTS(SELECT 1 FROM lc_asset_input ref WHERE ref.source_path=i.current_path OR ref.original_path=i.current_path)
            LIMIT 1",[asset],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?))).optional()?.ok_or("只能移动已核验、已纳入且与来源分开存放的受管原件")?;
        let from = io::absolute(Path::new(&source))?;
        let dest = dir.join(name);
        if from
            .extension()
            .and_then(|s| s.to_str())
            .map(str::to_lowercase)
            != dest
                .extension()
                .and_then(|s| s.to_str())
                .map(str::to_lowercase)
        {
            return Err("改名需保留原有文件格式".into());
        }
        append(
            &mut entries,
            asset,
            &file,
            &content,
            "original",
            from,
            dest,
            Some(&Blob::new(sha, length)?),
        )?;
        entries.last_mut().unwrap().locator = Some(source);
        let original = entries.last().unwrap().clone();
        companions(&mut entries, db, &original)?;
    }
    for e in &entries {
        for p in [&e.source, &e.destination] {
            if !names.insert(key(p)?) {
                return Err("文件清单中有重名、共享路径或冲突的目标".into());
            }
        }
    }
    entries.sort_by(|a, b| a.source.cmp(&b.source));
    let digest = hex::encode(sha2::Sha256::digest(serde_json::to_vec(&entries)?));
    Ok((entries, digest))
}
