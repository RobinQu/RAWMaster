use super::*;
use std::{
    collections::BTreeMap,
    fs::File,
    io::{Read, Seek, SeekFrom},
};
fn read(f: &mut File, at: u64, n: usize) -> Result<Vec<u8>> {
    f.seek(SeekFrom::Start(at))?;
    let mut b = vec![0; n];
    f.read_exact(&mut b)?;
    Ok(b)
}
fn b32(b: &[u8]) -> Result<u32> {
    Ok(u32::from_be_bytes(b.try_into()?))
}
fn le16(b: &[u8]) -> Result<u16> {
    Ok(u16::from_le_bytes(b.try_into()?))
}
fn le32(b: &[u8]) -> Result<u32> {
    Ok(u32::from_le_bytes(b.try_into()?))
}
#[derive(Clone, Copy)]
struct Atom {
    tag: [u8; 4],
    data: u64,
    end: u64,
}
fn atoms(f: &mut File, start: u64, end: u64) -> Result<Vec<Atom>> {
    let mut out = Vec::new();
    let mut cur = start;
    while cur < end {
        if out.len() > 100_000 || end - cur < 8 {
            return Err("Truncated MP4 atom".into());
        }
        let h = read(f, cur, 8)?;
        let n = b32(&h[..4])?;
        let mut header = 8;
        let size = match n {
            0 => end - cur,
            1 => {
                header = 16;
                u64::from_be_bytes(
                    read(f, cur + 8, 8)?
                        .try_into()
                        .map_err(|_| "Invalid extended atom")?,
                )
            }
            v => v as u64,
        };
        if size < header || size > end - cur {
            return Err("Invalid MP4 atom length".into());
        }
        out.push(Atom {
            tag: h[4..8].try_into()?,
            data: cur + header,
            end: cur + size,
        });
        cur += size;
    }
    Ok(out)
}
fn child(f: &mut File, a: Atom, t: &[u8; 4]) -> Result<Atom> {
    atoms(f, a.data, a.end)?
        .into_iter()
        .find(|n| &n.tag == t)
        .ok_or_else(|| "Missing required video atom".into())
}
fn table_bytes(f: &mut File, t: Atom, stride: usize) -> Result<Vec<u8>> {
    if t.end - t.data < 8 {
        return Err("Truncated video index table".into());
    }
    let n = b32(&read(f, t.data + 4, 4)?)? as usize;
    let count = n
        .checked_mul(stride)
        .filter(|n| *n <= 256 * 1024 * 1024)
        .ok_or("Video index exceeds supported size")?;
    if count as u64 > t.end - t.data - 8 {
        return Err("Truncated video index entries".into());
    }
    read(f, t.data + 8, count)
}
fn validate_samples(
    f: &mut File,
    st: Atom,
    sz: Atom,
    n: u32,
    uniform: u32,
    top: &[Atom],
) -> Result<()> {
    let stsc = child(f, st, b"stsc")?;
    let table = table_bytes(f, stsc, 12)?;
    let mut chunks = Vec::new();
    for entry in table.chunks_exact(12) {
        let first = b32(&entry[..4])?;
        let count = b32(&entry[4..8])?;
        if count == 0
            || b32(&entry[8..])? != 1
            || chunks.last().is_some_and(|(prev, _)| *prev >= first)
        {
            return Err("Invalid video sample-to-chunk mapping".into());
        }
        chunks.push((first, count));
    }
    if chunks.first().map(|v| v.0) != Some(1) {
        return Err("Missing video chunks".into());
    }
    let offsets = atoms(f, st.data, st.end)?
        .into_iter()
        .find(|x| matches!(&x.tag, b"stco" | b"co64"))
        .ok_or("Missing video chunk offsets")?;
    let stride = if offsets.tag == *b"co64" { 8 } else { 4 };
    let offset_table = table_bytes(f, offsets, stride)?;
    let sizes = if uniform == 0 {
        let bytes = (n as usize)
            .checked_mul(4)
            .filter(|n| *n <= 256 * 1024 * 1024)
            .ok_or("Video sample index exceeds supported size")?;
        read(f, sz.data + 12, bytes)?
    } else {
        vec![]
    };
    let mut seen = 0usize;
    let mut group = 0usize;
    for (i, v) in offset_table.chunks_exact(stride).enumerate() {
        if chunks.get(group + 1).is_some_and(|g| g.0 as usize == i + 1) {
            group += 1;
        }
        let len = chunks[group].1 as usize;
        let last = seen
            .checked_add(len)
            .filter(|n2| *n2 <= n as usize)
            .ok_or("Video chunk contains unknown samples")?;
        let start = if stride == 8 {
            u64::from_be_bytes(v.try_into()?)
        } else {
            u64::from(b32(v)?)
        };
        let bytes = if uniform != 0 {
            u64::from(uniform) * len as u64
        } else {
            let mut total = 0u64;
            for s in sizes[seen * 4..last * 4].chunks_exact(4) {
                let x = b32(s)?;
                if x == 0 {
                    return Err("Empty encoded video frame".into());
                }
                total += u64::from(x);
            }
            total
        };
        let end = start
            .checked_add(bytes)
            .ok_or("Video data extent overflow")?;
        if !top
            .iter()
            .any(|m| m.tag == *b"mdat" && start >= m.data && end <= m.end)
        {
            return Err("Encoded frame extent is outside video media data".into());
        }
        seen = last;
    }
    if seen != n as usize || group + 1 != chunks.len() {
        return Err("Video sample and chunk totals disagree".into());
    }
    Ok(())
}
fn movie(f: &mut File, end: u64) -> Result<(i64, i64, i64)> {
    let tree = atoms(f, 0, end)?;
    if !tree.iter().any(|n| n.tag == *b"ftyp")
        || !tree.iter().any(|n| n.tag == *b"mdat" && n.end > n.data)
    {
        return Err("Incomplete video payload".into());
    }
    let moov = tree
        .iter()
        .find(|n| n.tag == *b"moov")
        .ok_or("Missing video index")?;
    for track in atoms(f, moov.data, moov.end)?
        .into_iter()
        .filter(|n| n.tag == *b"trak")
    {
        let md = child(f, track, b"mdia")?;
        let handler = child(f, md, b"hdlr")?;
        if handler.end - handler.data < 12 || read(f, handler.data + 8, 4)? != b"vide" {
            continue;
        }
        let min = child(f, md, b"minf")?;
        let st = child(f, min, b"stbl")?;
        let desc = child(f, st, b"stsd")?;
        let sz = child(f, st, b"stsz")?;
        if sz.end - sz.data < 12 || desc.end - desc.data < 8 {
            return Err("Incomplete video sample description".into());
        }
        let n = b32(&read(f, sz.data + 8, 4)?)?;
        let size = b32(&read(f, sz.data + 4, 4)?)?;
        if n == 0 || (size == 0 && u64::from(n) * 4 > sz.end - sz.data - 12) {
            return Err("Invalid video sample count".into());
        }
        validate_samples(f, st, sz, n, size, &tree)?;
        let codec = atoms(f, desc.data + 8, desc.end)?
            .into_iter()
            .find(|v| matches!(&v.tag, b"avc1" | b"avc3" | b"hvc1" | b"hev1"))
            .ok_or("Unsupported timelapse codec")?;
        if codec.end - codec.data < 28 {
            return Err("Incomplete encoded picture description".into());
        }
        let dims = read(f, codec.data + 24, 4)?;
        return Ok((
            u16::from_be_bytes(dims[..2].try_into()?) as i64,
            u16::from_be_bytes(dims[2..].try_into()?) as i64,
            n as i64,
        ));
    }
    Err("Movie has no validated video track".into())
}
struct Tag {
    typ: u16,
    count: u32,
    entry: [u8; 4],
}
fn tvals(f: &mut File, end: u64, t: &Tag) -> Result<Vec<u32>> {
    let unit = match t.typ {
        3 => 2,
        4 => 4,
        _ => return Err("Invalid TIFF numeric field".into()),
    };
    if t.count > 4_000_000 {
        return Err("Unreasonable TIFF element count".into());
    }
    let size = t.count as usize * unit;
    let b = if size <= 4 {
        t.entry[..size].to_vec()
    } else {
        let offset = le32(&t.entry)? as u64;
        if offset + size as u64 > end {
            return Err("Truncated TIFF field".into());
        }
        read(f, offset, size)?
    };
    b.chunks_exact(unit)
        .map(|v| {
            if unit == 2 {
                Ok(le16(v)? as u32)
            } else {
                le32(v)
            }
        })
        .collect()
}
fn linear_profile(p: &[u8]) -> Result<()> {
    if p.len() < 132
        || b32(&p[..4])? as usize > p.len()
        || &p[36..40] != b"acsp"
        || &p[16..20] != b"RGB "
    {
        return Err("Invalid RGB ICC profile".into());
    }
    let count = b32(&p[128..132])? as usize;
    if count > (p.len() - 132) / 12 {
        return Err("Invalid ICC tag directory".into());
    }
    let mut tags = BTreeMap::<[u8; 4], &[u8]>::new();
    for t in p[132..132 + count * 12].chunks_exact(12) {
        let at = b32(&t[4..8])? as usize;
        let n = b32(&t[8..])? as usize;
        let slice = p
            .get(at..at.checked_add(n).ok_or("Invalid ICC tag length")?)
            .ok_or("ICC tag outside profile")?;
        tags.insert(t[..4].try_into()?, slice);
    }
    for k in [*b"rTRC", *b"gTRC", *b"bTRC"] {
        let v = tags.get(&k).ok_or("Missing RGB transfer curve")?;
        let linear = v.len() >= 12
            && (&v[..4] == b"curv"
                && (b32(&v[8..12])? == 0
                    || (b32(&v[8..12])? == 1 && v.get(12..14) == Some(&[1, 0])))
                || &v[..4] == b"para"
                    && v.len() >= 16
                    && v[8..10] == [0, 0]
                    && b32(&v[12..16])? == 65536);
        if !linear {
            return Err("RGB transfer curve is not linear".into());
        }
    }
    for (key, want) in [
        (*b"rXYZ", [0.436, 0.222, 0.014]),
        (*b"gXYZ", [0.385, 0.717, 0.097]),
        (*b"bXYZ", [0.143, 0.061, 0.714]),
    ] {
        let v = tags.get(&key).ok_or("Missing sRGB colorants")?;
        if v.len() < 20 || &v[..4] != b"XYZ " {
            return Err("Invalid RGB colorant".into());
        }
        for (n, target) in want.iter().enumerate() {
            let pos = 8 + n * 4;
            let actual = f64::from(i32::from_be_bytes(v[pos..pos + 4].try_into()?)) / 65536.0;
            if (actual - target).abs() > 0.012 {
                return Err("Unexpected linear RGB primaries".into());
            }
        }
    }
    Ok(())
}
fn tiff(f: &mut File, end: u64) -> Result<(i64, i64, i64)> {
    let h = read(f, 0, 8)?;
    if &h[..4] != b"II*\0" {
        return Err("Expected a little-endian classic TIFF master".into());
    }
    let offset = le32(&h[4..])? as u64;
    let n = le16(&read(f, offset, 2)?)? as usize;
    if offset + 2 + n as u64 * 12 + 4 > end {
        return Err("Truncated TIFF directory".into());
    }
    let mut tags = BTreeMap::new();
    for e in read(f, offset + 2, n * 12)?.chunks_exact(12) {
        tags.insert(
            le16(&e[..2])?,
            Tag {
                typ: le16(&e[2..4])?,
                count: le32(&e[4..8])?,
                entry: e[8..12].try_into()?,
            },
        );
    }
    let mut values =
        |k: u16| -> Result<Vec<u32>> { tvals(f, end, tags.get(&k).ok_or("Missing TIFF tag")?) };
    let w = values(256)?;
    let h = values(257)?;
    if w.len() != 1 || h.len() != 1 || w[0] == 0 || h[0] == 0 {
        return Err("Invalid TIFF dimensions".into());
    }
    if values(258)? != [32, 32, 32]
        || values(277)? != [3]
        || values(339)? != [3, 3, 3]
        || values(262)? != [2]
        || values(259)? != [1]
        || values(274)? != [1]
    {
        return Err(
            "Master is not uncompressed 32-bit floating RGB with normal orientation".into(),
        );
    }
    let offsets = values(273)?;
    let sizes = values(279)?;
    if offsets.len() != sizes.len() || offsets.is_empty() {
        return Err("Incomplete TIFF image strips".into());
    }
    let mut spans = Vec::new();
    let mut length = 0u64;
    for (o, s) in offsets.into_iter().zip(sizes) {
        let o = u64::from(o);
        let size = u64::from(s);
        if size == 0 || o + size > end {
            return Err("Invalid pixel strip extent".into());
        }
        spans.push((o, o + size));
        length += size;
    }
    spans.sort_unstable();
    if spans.windows(2).any(|p| p[0].1 > p[1].0)
        || length
            != u64::from(w[0])
                .checked_mul(u64::from(h[0]))
                .and_then(|n| n.checked_mul(12))
                .ok_or("TIFF dimensions overflow")?
    {
        return Err("Master does not contain all declared RGB pixels".into());
    }
    let icc = tags.get(&34675).ok_or("Master lacks its ICC profile")?;
    let at = u64::from(le32(&icc.entry)?);
    if icc.typ != 7 || icc.count < 128 || at + u64::from(icc.count) > end {
        return Err("Invalid TIFF ICC extent".into());
    }
    if icc.count > 1024 * 1024 {
        return Err("Oversized output ICC profile".into());
    }
    linear_profile(&read(f, at, icc.count as usize)?)?;
    Ok((i64::from(w[0]), i64::from(h[0]), 1))
}
pub(super) fn verify(p: &Path, r: &Value) -> Result<()> {
    if !fs::symlink_metadata(p)?.is_file() {
        return Err("Expected regular rendering output".into());
    }
    let mut f = File::open(p)?;
    let end = f.metadata()?.len();
    let got = match (r["mediaKind"].as_str(), r["format"].as_str()) {
        (Some("derivedVideo"), Some("mp4")) => movie(&mut f, end)?,
        (Some("derivedPhoto"), Some("tiff32f")) => tiff(&mut f, end)?,
        _ => return Err("Unrecognized output receipt format".into()),
    };
    if (
        r["width"].as_i64(),
        r["height"].as_i64(),
        r["frameCount"].as_i64(),
    ) != (Some(got.0), Some(got.1), Some(got.2))
    {
        return Err("Output geometry/sample count differs from rendering receipt".into());
    }
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    #[ignore = "Requires the existing six-RAW timelapse renderer's private JSON report"]
    fn validate_actual_timelapse_sample_tables() -> Result<()> {
        let path = std::env::var("RAWMASTER_TIMELAPSE_REPORT")?;
        let report: Value = serde_json::from_slice(&fs::read(path)?)?;
        let renders = report["renders"]
            .as_array()
            .ok_or("Missing rendered movie list")?;
        assert!(renders.len() >= 2);
        for m in renders {
            let receipt = json!({"mediaKind":"derivedVideo","format":"mp4","width":m["width"],"height":m["height"],"frameCount":m["frameCount"]});
            verify(Path::new(required(m, "path")?), &receipt)?;
        }
        Ok(())
    }
}
