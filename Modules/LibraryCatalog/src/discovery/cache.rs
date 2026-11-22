use super::{
    digest,
    geometry::{valid, Fence},
    Input,
};
use crate::Result;
use rusqlite::{params, Connection, OpenFlags, OptionalExtension};
use serde_json::Value;
use std::{collections::BTreeSet, fs, path::Path, time::Duration};
const APP: i64 = 0x524D4449;
pub fn open(db: &Connection, create: bool) -> Result<Option<Connection>> {
    let path = Path::new(
        db.path()
            .ok_or("discovery requires a file-backed library")?,
    );
    let id: String = db.query_row("SELECT value FROM lc_meta WHERE key='libraryID'", [], |r| {
        r.get(0)
    })?;
    let dir = path
        .parent()
        .ok_or("no catalog parent")?
        .join("LibraryIndexes");
    let generation:i64=db.query_row("SELECT coalesce((SELECT CAST(value AS INTEGER) FROM lc_meta WHERE key='discoveryCacheGeneration'),0)",[],|r|r.get(0))?;
    let target = dir.join(format!("discovery-v2-{}-{generation}.sqlite", digest(&id)));
    crate::query::separate_files(path, &target)?;
    if !target.try_exists()? && !create {
        return Ok(None);
    }
    if create {
        fs::create_dir_all(&dir)?;
    }
    let flag = if create {
        OpenFlags::SQLITE_OPEN_CREATE | OpenFlags::SQLITE_OPEN_READ_WRITE
    } else {
        OpenFlags::SQLITE_OPEN_READ_ONLY
    };
    let c = Connection::open_with_flags(&target, flag)?;
    c.busy_timeout(Duration::from_secs(3))?;
    let app: i64 = c.query_row("PRAGMA application_id", [], |r| r.get(0))?;
    if app == 0 && create {
        let tx = c.unchecked_transaction()?;
        let app: i64 = tx.query_row("PRAGMA application_id", [], |r| r.get(0))?;
        if app == 0 {
            if tx.query_row("SELECT count(*) FROM sqlite_schema", [], |r| {
                r.get::<_, i64>(0)
            })? != 0
            {
                return Err("foreign discovery cache file".into());
            }
            tx.execute_batch("PRAGMA application_id=1380795465; PRAGMA user_version=2;
    CREATE TABLE cache_owner(id TEXT NOT NULL,spatial_tip INTEGER NOT NULL);
    CREATE TABLE features(key TEXT PRIMARY KEY NOT NULL,model TEXT NOT NULL,dimension INTEGER NOT NULL,checksum TEXT NOT NULL,vector BLOB NOT NULL);
    CREATE TABLE places(id INTEGER PRIMARY KEY,work_id TEXT NOT NULL UNIQUE);CREATE VIRTUAL TABLE bounds USING rtree(id, minLat,maxLat,minLon,maxLon);")?;
            tx.execute("INSERT INTO cache_owner VALUES(?,-1)", [&id])?;
        }
        tx.commit()?;
    }
    let app: i64 = c.query_row("PRAGMA application_id", [], |r| r.get(0))?;
    let format: i64 = c.query_row("PRAGMA user_version", [], |r| r.get(0))?;
    if app != APP
        || format != 2
        || c.query_row("SELECT id FROM cache_owner", [], |r| r.get::<_, String>(0))? != id
    {
        return Err("foreign or incompatible discovery cache".into());
    }
    Ok(Some(c))
}
pub fn normalized(v: &Value, dim: usize) -> Result<Vec<f32>> {
    let vals = v
        .as_array()
        .filter(|v| v.len() == dim)
        .ok_or("wrong feature dimension")?;
    let mut nums = Vec::with_capacity(dim);
    let mut total = 0.;
    for a in vals {
        let n = a
            .as_f64()
            .filter(|v| v.is_finite() && v.abs() < 1e10)
            .ok_or("invalid feature value")?;
        total += n * n;
        nums.push(n as f32);
    }
    if total < 1e-12 {
        return Err("empty feature".into());
    }
    for n in &mut nums {
        *n /= total.sqrt() as f32;
    }
    Ok(nums)
}
pub fn put(c: &Connection, key: &str, model: &str, v: &[f32]) -> Result<()> {
    let bytes = v.iter().flat_map(|f| f.to_le_bytes()).collect::<Vec<_>>();
    c.execute(
        "INSERT INTO features VALUES(?,?,?,?,?) ON CONFLICT(key) DO UPDATE SET checksum=excluded.checksum,vector=excluded.vector WHERE features.model=excluded.model AND features.dimension=excluded.dimension",
        params![key, model, v.len() as i64, digest(&bytes),bytes],
    )?;
    Ok(())
}
pub fn get(c: Option<&Connection>, key: &str, model: &str, dim: usize) -> Result<Option<Vec<f32>>> {
    let Some(c) = c else {
        return Ok(None);
    };
    let b: Option<(Vec<u8>, String)> = c
        .prepare_cached(
            "SELECT vector,checksum FROM features WHERE key=? AND model=? AND dimension=?",
        )?
        .query_row(params![key, model, dim as i64], |r| {
            Ok((r.get(0)?, r.get(1)?))
        })
        .optional()?;
    Ok(b.and_then(|(b, checksum)| {
        if b.len() != dim * 4 || digest(&b) != checksum {
            return None;
        }
        let v: Vec<_> = b
            .chunks_exact(4)
            .map(|s| f32::from_le_bytes(s.try_into().unwrap()))
            .collect();
        let n: f32 = v.iter().map(|x| x * x).sum();
        (n.is_finite() && (n - 1.).abs() < 0.005).then_some(v)
    }))
}
pub fn cosine(a: &[f32], b: &[f32]) -> f64 {
    a.iter()
        .zip(b)
        .map(|(a, b)| f64::from(*a) * f64::from(*b))
        .sum::<f64>()
        .clamp(-1., 1.)
}
pub fn tip(db: &Connection) -> Result<i64> {
    Ok(
        db.query_row("SELECT coalesce(max(seq),0) FROM lc_changes", [], |r| {
            r.get(0)
        })?,
    )
}
pub fn spatial(db: &Connection, inputs: &[Input]) -> Result<usize> {
    let c = open(db, true)?.ok_or("missing feature cache")?;
    let tx = c.unchecked_transaction()?;
    tx.execute_batch("DELETE FROM bounds;DELETE FROM places;")?;
    let mut count = 0;
    for item in inputs {
        if let Some((a, b)) = item
            .latitude
            .zip(item.longitude)
            .filter(|(a, b)| valid(*a, *b))
        {
            tx.execute("INSERT INTO places(work_id) VALUES(?)", [&item.work_id])?;
            tx.execute(
                "INSERT INTO bounds VALUES(?,?,?,?,?)",
                params![tx.last_insert_rowid(), a, a, b, b],
            )?;
            count += 1;
        }
    }
    tx.execute("UPDATE cache_owner SET spatial_tip=?", [tip(db)?])?;
    tx.commit()?;
    Ok(count)
}
pub fn shortlist(
    db: &Connection,
    c: Option<&Connection>,
    g: &Fence,
) -> Result<Option<BTreeSet<String>>> {
    let Some(c) = c else {
        return Ok(None);
    };
    let w: i64 = c.query_row("SELECT spatial_tip FROM cache_owner", [], |r| r.get(0))?;
    if w != tip(db)? {
        return Ok(None);
    }
    let mut ids = BTreeSet::new();
    let mut st=c.prepare("SELECT p.work_id FROM bounds b JOIN places p ON p.id=b.id WHERE b.maxLat>=? AND b.minLat<=? AND b.maxLon>=? AND b.minLon<=?")?;
    for (lo, hi, left, right) in g.bounds() {
        for id in st.query_map(params![lo, hi, left, right], |r| r.get::<_, String>(0))? {
            ids.insert(id?);
        }
    }
    Ok(Some(ids))
}

pub fn rebuild(db: &Connection) -> Result<()> {
    db.execute("INSERT INTO lc_meta VALUES('discoveryCacheGeneration','1') ON CONFLICT(key) DO UPDATE SET value=CAST(CAST(value AS INTEGER)+1 AS TEXT)",[])?;
    open(db, true)?;
    db.execute("DELETE FROM lc_discover_schedule", [])?;
    db.execute(
        "UPDATE lc_discover_state SET revision=revision+1 WHERE id=1",
        [],
    )?;
    Ok(())
}
