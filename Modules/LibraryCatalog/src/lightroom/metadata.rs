use super::*;
use std::collections::{BTreeMap, HashSet};
use std::io::Read;
const XML_LIMIT: u64 = 16 * 1024 * 1024;
fn xmp(packet: &[u8]) -> Result<String> {
    if packet.len() as u64 > XML_LIMIT {
        return Err("XMP packet exceeds the extraction limit".into());
    }
    if let Ok(s) = std::str::from_utf8(packet) {
        let s = s.trim_start_matches('\u{feff}').trim_start();
        if s.starts_with('<') {
            return Ok(s.into());
        }
    }
    if packet.len() < 6 {
        return Err("Unknown Adobe XMP container".into());
    }
    let size = u32::from_be_bytes(packet[..4].try_into()?) as u64;
    if size == 0 || size > XML_LIMIT {
        return Err("Unknown Adobe XMP size".into());
    }
    let mut out = Vec::new();
    flate2::read::ZlibDecoder::new(&packet[4..])
        .take(size + 1)
        .read_to_end(&mut out)?;
    if out.len() as u64 != size {
        return Err("Adobe XMP payload length mismatch".into());
    }
    Ok(String::from_utf8(out)?)
}
fn properties(text: &str) -> Result<BTreeMap<String, String>> {
    let xml = roxmltree::Document::parse(text)?;
    let mut out = BTreeMap::new();
    let dc = "http://purl.org/dc/elements/1.1/";
    for node in xml
        .descendants()
        .filter(|n| n.is_element() && n.tag_name().namespace() == Some(dc))
    {
        let key = match node.tag_name().name() {
            "title" => "title",
            "description" => "caption",
            "creator" => "creator",
            "rights" => "copyright",
            _ => continue,
        };
        let list = node
            .descendants()
            .filter(|n| {
                n.is_element()
                    && n.tag_name().namespace()
                        == Some("http://www.w3.org/1999/02/22-rdf-syntax-ns#")
                    && n.tag_name().name() == "li"
            })
            .collect::<Vec<_>>();
        let default = list
            .iter()
            .find(|n| {
                n.attribute(("http://www.w3.org/XML/1998/namespace", "lang")) == Some("x-default")
            })
            .copied();
        let values = if key == "creator" {
            list.iter()
                .filter_map(|n| n.text())
                .collect::<Vec<_>>()
                .join(", ")
        } else {
            default
                .or_else(|| list.first().copied())
                .and_then(|n| n.text())
                .or_else(|| node.text())
                .unwrap_or("")
                .to_owned()
        };
        if !values.trim().is_empty() {
            out.entry(key.into()).or_insert(values);
        }
    }
    Ok(out)
}
fn get_interned(db: &Connection, t: &str, val: &Value) -> Result<Option<String>> {
    let Some(id) = integer(val) else {
        return Ok(None);
    };
    if !source::exists(db, t)? {
        return Ok(None);
    }
    Ok(db
        .query_row(
            &format!("SELECT CAST(value AS TEXT) FROM {t} WHERE id_local=?1"),
            [id],
            |r| r.get::<_, Option<String>>(0),
        )
        .optional()?
        .flatten())
}
fn keyword_path(db: &Connection, id: i64) -> Result<Option<Vec<String>>> {
    let mut visited = HashSet::new();
    let mut path = Vec::new();
    let mut next = Some(id);
    while let Some(key) = next {
        if visited.len() > 128 || !visited.insert(key) {
            return Ok(None);
        }
        let Some(v) = source::record(db, "AgLibraryKeyword", key)? else {
            return Ok(None);
        };
        let name = v["name"].as_str().unwrap_or("");
        if !name.is_empty() {
            path.push(name.to_owned());
        }
        next = integer(&v["parent"]).filter(|v| *v > 0);
    }
    path.reverse();
    Ok(Some(path))
}
fn nonempty(fields: &mut Value, k: &str, v: &Value) {
    if v.as_str().is_some_and(|s| !s.trim().is_empty()) {
        fields[k] = v.clone();
    }
}
pub(super) fn image(
    ctx: &Context<'_>,
    id: i64,
    row: &Value,
    work: &str,
    item: &mut Item,
) -> Result<Value> {
    let db = &ctx.source;
    let mut fields = json!({});
    if let Some(r) = integer(&row["rating"]) {
        if (0..=5).contains(&r) {
            fields["rating"] = json!(r);
        } else {
            item.report(
                "metadata",
                "rating",
                "unsupported",
                "Invalid Lightroom rating",
                row["rating"].clone(),
            );
        }
    }
    if let Some(n) = integer(&row["pick"]) {
        match n {
            -1 => fields["flag"] = json!("rejected"),
            0 => fields["flag"] = json!("unflagged"),
            1 => fields["flag"] = json!("picked"),
            _ => item.report(
                "metadata",
                "flag",
                "unsupported",
                "Unrecognized source pick value",
                row["pick"].clone(),
            ),
        }
    }
    if let Some(label) = row["colorLabels"].as_str().filter(|s| !s.is_empty()) {
        fields["colorLabelRaw"] = json!(label);
        let color = label.trim().to_lowercase();
        if ["red", "yellow", "green", "blue", "purple"].contains(&color.as_str()) {
            fields["colorLabel"] = json!(color);
        } else {
            item.report(
                "metadata",
                "colorLabel",
                "archivedOnly",
                "Custom label text preserved without assigning a color",
                json!(label),
            );
        }
    }
    nonempty(&mut fields, "capturedLocal", &row["captureTime"]);
    let iptc = source::related(db, "AgLibraryIPTC", "image", id)?.unwrap_or(Value::Null);
    nonempty(&mut fields, "caption", &iptc["caption"]);
    nonempty(&mut fields, "copyright", &iptc["copyright"]);
    let harvested =
        source::related(db, "AgHarvestedIptcMetadata", "image", id)?.unwrap_or(Value::Null);
    if let Some(creator) = get_interned(db, "AgInternedIptcCreator", &harvested["creatorRef"])? {
        nonempty(&mut fields, "creator", &json!(creator));
    }
    let mut places = Vec::new();
    for (t, k) in [
        ("AgInternedIptcLocation", "locationRef"),
        ("AgInternedIptcCity", "cityRef"),
        ("AgInternedIptcState", "stateRef"),
        ("AgInternedIptcCountry", "countryRef"),
    ] {
        if let Some(s) = get_interned(db, t, &harvested[k])? {
            if !s.is_empty() && !places.contains(&s) {
                places.push(s);
            }
        }
    }
    if !places.is_empty() {
        fields["place"] = json!(places.join(", "));
    }
    let exif = source::related(db, "AgHarvestedExifMetadata", "image", id)?.unwrap_or(Value::Null);
    if let (Some(lat), Some(lon)) = (
        numeric(&exif["gpsLatitude"]),
        numeric(&exif["gpsLongitude"]),
    ) {
        if (-90.0..=90.0).contains(&lat) && (-180.0..=180.0).contains(&lon) {
            fields["latitude"] = json!(lat);
            fields["longitude"] = json!(lon);
        } else {
            item.report(
                "metadata",
                "gps",
                "unsupported",
                "GPS coordinates outside valid range",
                json!([lat, lon]),
            );
        }
    } else if !exif["gpsLatitude"].is_null()
        || !exif["gpsLongitude"].is_null()
        || integer(&exif["hasGPS"]) == Some(1)
    {
        item.report(
            "metadata",
            "gps",
            "missing",
            "Incomplete or nonnumeric source coordinates",
            json!([exif["gpsLatitude"], exif["gpsLongitude"]]),
        );
    }
    if source::exists(db, "AgLibraryKeywordImage")? && source::exists(db, "AgLibraryKeyword")? {
        let mut s = db.prepare_cached(
            "SELECT DISTINCT tag FROM AgLibraryKeywordImage WHERE image=?1 ORDER BY tag",
        )?;
        let mut keywords = Vec::new();
        for r in s.query_map([id], |r| r.get::<_, i64>(0))? {
            let k = r?;
            if let Some(path) = keyword_path(db, k)?.filter(|p| !p.is_empty()) {
                keywords.push(json!({"id":ctx.id("keyword",k)?,"path":path}));
            } else {
                item.report(
                    "metadata",
                    &format!("keyword:{k}"),
                    "missing",
                    "Missing or cyclic keyword ancestry",
                    json!(k),
                );
            }
        }
        fields["keywords"] = json!(keywords);
    }
    if source::exists(db, "Adobe_AdditionalMetadata")? {
        let packet:Option<Vec<u8>>=db.query_row("SELECT CAST(xmp AS BLOB) FROM Adobe_AdditionalMetadata WHERE image=?1 AND length(xmp)>0 ORDER BY id_local LIMIT 1",[id],|r|r.get(0)).optional()?;
        if let Some(p) = packet {
            match xmp(&p).and_then(|s|properties(&s)){
                Ok(extracted)=>for(k,v)in extracted{if fields[&k].is_null(){fields[&k]=json!(v);}},
                Err(_)=>item.report("metadata","xmpFields","archivedOnly","The original XMP container is retained in the frozen catalog; its properties could not be decoded",Value::Null),
            }
            // The original packet and all per-image opaque fields are also preserved in the source SQLite resource.
            item.link(
                "sourceXmp",
                "Adobe_AdditionalMetadata.xmp",
                source::bytes(ctx.catalog, &p, "adobePayload")?,
            );
        }
    }
    let mut optical = json!({});
    for (key, r) in [
        ("aperture", "aperture"),
        ("iso", "isoSpeedRating"),
        ("shutterSpeed", "shutterSpeed"),
        ("focalLength", "focalLength"),
        ("flashFired", "flashFired"),
    ] {
        if !exif[r].is_null() {
            optical[key] = exif[r].clone();
        }
    }
    for (k, t, f) in [
        ("camera", "AgInternedExifCameraModel", "cameraModelRef"),
        ("lens", "AgInternedExifLens", "lensRef"),
        ("cameraSerial", "AgInternedExifCameraSN", "cameraSNRef"),
    ] {
        if let Some(v) = get_interned(db, t, &exif[f])? {
            optical[k] = json!(v);
        }
    }
    for (k, source) in [("camera", "camera"), ("lens", "lens")] {
        nonempty(&mut fields, k, &optical[source]);
    }
    for (k, val) in [
        ("width", &row["fileWidth"]),
        ("height", &row["fileHeight"]),
        ("iso", &exif["isoSpeedRating"]),
    ] {
        if let Some(n) = integer(val).filter(|v| *v > 0 && *v <= i32::MAX as i64) {
            fields[k] = json!(n);
        }
    }
    if let Some(n) = numeric(&exif["focalLength"]).filter(|v| *v > 0.0) {
        fields["focalLength"] = json!(n);
    }
    item.metadata = Some((work.into(), fields.clone()));
    for f in [
        "rating",
        "flag",
        "colorLabelRaw",
        "title",
        "caption",
        "creator",
        "copyright",
        "keywords",
        "latitude",
        "longitude",
        "place",
        "capturedLocal",
        "camera",
        "lens",
        "width",
        "height",
        "iso",
        "focalLength",
    ] {
        let present = fields.get(f).is_some_and(|v| !v.is_null());
        item.report(
            "metadata",
            f,
            if present { "mapped" } else { "missing" },
            if present {
                "Source field recorded"
            } else {
                "No value in this source work"
            },
            Value::Null,
        );
    }
    Ok(json!({"fields":fields,"lightroomExif":optical,"sourceIptc":iptc,"harvestedIptc":harvested}))
}
