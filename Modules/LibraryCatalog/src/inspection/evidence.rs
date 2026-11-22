use super::*;

fn finite(v: &Value, key: &str, min: f64, max: f64) -> Result<f64> {
    v[key]
        .as_f64()
        .filter(|x| x.is_finite() && (*x >= min) && (*x <= max))
        .ok_or_else(|| format!("Invalid {key} measurement").into())
}
fn focus_code(v: &Value) -> bool {
    matches!(v.as_str(), Some("clear" | "suspectedBlur" | "unknown"))
}
fn current<'a>(db: &Connection, r: &'a Value) -> Result<(&'a str, &'a str)> {
    let f = string(r, "fileID")?;
    let c = string(r, "contentID")?;
    file_scope(db, f, c, r["sessionID"].as_str())?;
    Ok((f, c))
}
fn checked_af(af: &Value) -> Result<()> {
    match af["state"].as_str() {
        Some("available") => {
            if af["tag"] != "Sony:FocusLocation"
                || !af["model"].as_str().is_some_and(|m| !m.is_empty())
                || af["coordinateSpace"] != "unorientedTopLeft"
                || !matches!(af["orientation"].as_u64(), Some(1..=8))
            {
                return Err("Unqualified AF location".into());
            }
            let a = af["tuple"]
                .as_array()
                .filter(|v| v.len() == 4)
                .ok_or("Missing native Sony focus dimensions")?;
            let nums = a
                .iter()
                .map(|v| v.as_u64().ok_or("Invalid Sony focus tuple"))
                .collect::<std::result::Result<Vec<_>, _>>()?;
            if nums[0] == 0
                || nums[1] == 0
                || nums[2] >= nums[0]
                || nums[3] >= nums[1]
                || nums[0] > 65535
                || nums[1] > 65535
                || (nums[2] == nums[0] / 2 && nums[3] == nums[1] / 2)
            {
                return Err("Invalid or ambiguous Sony playback focus location".into());
            }
        }
        Some("unavailable") => {
            string(af, "reason")?;
        }
        _ => return Err("Missing AF evidence state".into()),
    }
    Ok(())
}
pub(super) fn capture(db: &Connection, r: &Value) -> Result<Value> {
    let (file, content) = current(db, r)?;
    let extractor = string(r, "extractor")?;
    let fields = r["fields"]
        .as_object()
        .ok_or("No embedded metadata object")?;
    const ALLOWED: &[&str] = &[
        "make",
        "camera",
        "lens",
        "iso",
        "aperture",
        "shutterSeconds",
        "focalLength",
        "exposureCompensation",
        "width",
        "height",
        "colorSpace",
        "capturedAt",
        "capturedLocal",
        "offsetTime",
        "orientation",
        "latitude",
        "longitude",
        "title",
        "caption",
        "creator",
        "copyright",
        "keywords",
        "place",
    ];
    for (key, value) in fields {
        if !ALLOWED.contains(&key.as_str()) || !metadata::validate(key, value, true) {
            return Err(format!("Invalid embedded field {key}").into());
        }
    }
    checked_af(&r["af"])?;
    let old: Option<(String, String)> = db
        .query_row(
            "SELECT fields_json,af_json FROM lc_inspect_files WHERE file_id=? AND content_id=?",
            params![file, content],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()?;
    let mut merged = old
        .as_ref()
        .map(|(raw, _)| serde_json::from_str::<Map<String, Value>>(raw))
        .transpose()?
        .unwrap_or_default();
    for (k, v) in fields {
        if !v.is_null() {
            merged.insert(k.clone(), v.clone());
        }
    }
    let mut af = r["af"].clone();
    if af["state"] == "unavailable" && af["reason"] == "readerUnavailable" {
        if let Some((_, prior)) = old {
            let prior: Value = serde_json::from_str(&prior)?;
            if prior["state"] == "available" {
                af = prior;
            }
        }
    }
    let n=db.execute("INSERT INTO lc_inspect_files VALUES(?1,?2,?3,?4,?5) ON CONFLICT(file_id,content_id) DO UPDATE SET fields_json=excluded.fields_json,
        af_json=excluded.af_json,extractor=excluded.extractor WHERE fields_json!=excluded.fields_json OR af_json!=excluded.af_json OR extractor!=excluded.extractor",
        params![file,content,serde_json::to_string(&merged)?,af.to_string(),extractor])?;
    if n > 0 {
        file_change(db, file)?;
    }
    Ok(json!({"fileID":file,"contentID":content,"fields":merged.len(),"afState":af["state"]}))
}
pub(super) fn histogram(db: &Connection, r: &Value) -> Result<Value> {
    let (file, content) = current(db, r)?;
    let s = &r["sample"];
    let id = string(s, "sampleID")?;
    let kind = string(s, "kind")?;
    if !matches!(kind, "cameraJPEG" | "proxy" | "render") || s["encoding"] != "sRGB8" {
        return Err("Unknown histogram source or transfer function".into());
    }
    let sha = string(s, "sourceSHA256")?;
    if sha.len() != 64
        || !sha
            .bytes()
            .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c) || (b'A'..=b'F').contains(&c))
        || (kind == "render" && s["versionID"].as_str().is_none_or(str::is_empty))
    {
        return Err("Unversioned histogram source".into());
    }
    let n = s["sampledPixels"]
        .as_u64()
        .filter(|&n| n > 0 && n <= 4_194_304)
        .ok_or("Invalid histogram sample count")?;
    let area = s["sampleWidth"]
        .as_u64()
        .zip(s["sampleHeight"].as_u64())
        .and_then(|(w, h)| w.checked_mul(h));
    if area != Some(n) {
        return Err("Histogram dimensions do not match sample count".into());
    }
    for channel in ["red", "green", "blue"] {
        let bins = s[channel]
            .as_array()
            .filter(|a| a.len() == 256)
            .ok_or("Histogram requires 256 bins per channel")?;
        let total = bins
            .iter()
            .try_fold(0u64, |sum, v| v.as_u64().and_then(|q| sum.checked_add(q)));
        if total != Some(n) {
            return Err("Histogram plane sample count mismatch".into());
        }
    }
    let old: Option<String> = db
        .query_row(
            "SELECT data FROM lc_inspect_samples WHERE file_id=? AND content_id=? AND sample_id=?",
            params![file, content, id],
            |r| r.get(0),
        )
        .optional()?;
    if let Some(old) = old {
        if serde_json::from_str::<Value>(&old)? != *s {
            return Err("Histogram source changed under its sample identity".into());
        }
    } else {
        db.execute(
            "INSERT INTO lc_inspect_samples VALUES(?,?,?,?,?)",
            params![file, content, id, kind, s.to_string()],
        )?;
        file_change(db, file)?;
    }
    Ok(json!({"sampleID":id,"kind":kind}))
}
pub(super) fn manual(db: &Connection, r: &Value) -> Result<Value> {
    let (file, content) = current(db, r)?;
    if r.get("value").is_none() {
        return Err("Specify an explicit focus verdict or null to clear".into());
    }
    if !r["value"].is_null() && !focus_code(&r["value"]) {
        return Err("Invalid human focus verdict".into());
    }
    let prior: Option<String> = db
        .query_row(
            "SELECT manual_command FROM lc_inspect_focus WHERE file_id=? AND content_id=?",
            params![file, content],
            |r| r.get(0),
        )
        .optional()?
        .flatten();
    if let Some(expected) = r.get("expectedCommand") {
        if expected.as_str() != prior.as_deref() {
            return Err("Human focus assessment changed".into());
        }
    }
    let cmd = string(r, "commandID")?;
    db.execute("INSERT INTO lc_inspect_focus(file_id,content_id,manual,manual_command) VALUES(?1,?2,?3,?4) ON CONFLICT(file_id,content_id)
        DO UPDATE SET manual=excluded.manual,manual_command=excluded.manual_command",params![file,content,r["value"].as_str(),cmd])?;
    file_change(db, file)?;
    Ok(json!({"fileID":file,"contentID":content,"manual":r["value"],"commandID":cmd}))
}
fn median(v: &mut [f64]) -> f64 {
    v.sort_by(f64::total_cmp);
    let n = v.len();
    (v[(n - 1) / 2] + v[n / 2]) / 2.0
}
struct Frame<'a> {
    source: &'a Value,
    file: &'a str,
    content: &'a str,
    score: f64,
    reason: Option<&'static str>,
    cohort: Option<String>,
}
pub(super) fn burst(db: &Connection, r: &Value) -> Result<Value> {
    let gid = string(r, "groupID")?;
    let definition:Option<(String,i64)>=db.query_row("SELECT kind,revision FROM lc_group_versions g
        WHERE group_id=?1 AND revision=(SELECT max(revision) FROM lc_group_versions WHERE group_id=?1) AND tombstoned=0
        AND NOT EXISTS(SELECT 1 FROM lc_group_dirty WHERE group_id=?1) UNION ALL
        SELECT json_extract(data,'$.kind'),coalesce(json_extract(data,'$.groupRevision'),0) FROM groups_data WHERE id=?1 AND
        (NOT EXISTS(SELECT 1 FROM lc_group_versions WHERE group_id=?1) OR EXISTS(SELECT 1 FROM lc_group_dirty WHERE group_id=?1)) LIMIT 1",
        [gid],|q|Ok((q.get(0)?,q.get(1)?))).optional()?;
    let (kind, revision) = definition.ok_or("Burst group is unavailable")?;
    if !matches!(kind.as_str(), "burst" | "连拍")
        || r.get("expectedGroupRevision")
            .is_some_and(|v| v.as_i64() != Some(revision))
    {
        return Err("Burst group type or reviewed revision changed".into());
    }
    let frames = r["frames"]
        .as_array()
        .filter(|a| !a.is_empty() && a.len() <= 2048)
        .ok_or("Expected 1 to 2048 reviewed group frames")?;
    let mut parsed = Vec::new();
    let mut seen = BTreeSet::new();
    let mut cohorts = std::collections::BTreeMap::<String, Vec<f64>>::new();
    for source in frames {
        let f = string(source, "fileID")?;
        let c = string(source, "contentID")?;
        file_scope(db, f, c, r["sessionID"].as_str())?;
        if !seen.insert((f, c)) {
            return Err("Duplicate frame in burst assessment".into());
        }
        let inside:bool=db.query_row("SELECT EXISTS(SELECT 1 FROM lc_group_file_members gm JOIN lc_group_versions g USING(group_id,revision)
          WHERE gm.group_id=?1 AND gm.file_id=?2 AND gm.revision=(SELECT max(revision) FROM lc_group_versions WHERE group_id=?1) AND g.tombstoned=0
          AND NOT EXISTS(SELECT 1 FROM lc_group_dirty WHERE group_id=?1))
          OR EXISTS(SELECT 1 FROM membership m JOIN lc_asset_files a USING(asset_id) WHERE m.group_id=?1 AND a.file_id=?2
           AND (NOT EXISTS(SELECT 1 FROM lc_group_versions WHERE group_id=?1) OR EXISTS(SELECT 1 FROM lc_group_dirty WHERE group_id=?1)))",params![gid,f],|r|r.get(0))?;
        if !inside {
            return Err("Measurement does not belong to the reviewed group".into());
        }
        let mut score = 0.0;
        let mut cohort = None;
        let reason = if let Some(reason) = source["unavailable"].as_str() {
            if !matches!(
                reason,
                "noAFOrSubject"
                    | "unavailable"
                    | "proxyOnly"
                    | "outsideCrop"
                    | "insufficientPixels"
                    | "changed"
            ) {
                return Err("Unrecognized missing focus evidence".into());
            }
            Some("unavailable")
        } else {
            let m = &source["measurements"];
            let region = &source["region"];
            let x = finite(region, "x", 0.0, 1.0)?;
            let y = finite(region, "y", 0.0, 1.0)?;
            let w = finite(region, "width", 0.0, 1.0)?;
            let h = finite(region, "height", 0.0, 1.0)?;
            if w <= 0.0 || h <= 0.0 || x + w > 1.000001 || y + h > 1.000001 {
                return Err("Native focus region extends outside the frame".into());
            }
            let pixels = m["pixels"]
                .as_u64()
                .ok_or("Missing native patch pixel count")?;
            let mean = finite(m, "luma", 0.0, 1.0)?;
            let contrast = finite(m, "contrast", 0.0, 1.0)?;
            let grad = finite(m, "gradient", 0.0, 2.0)?;
            let lap = finite(m, "laplacian", 0.0, 16.0)?;
            let anisotropy = finite(m, "anisotropy", 0.0, 1.0)?;
            let clipping = finite(m, "clippedFraction", 0.0, 1.0)?;
            let basis = string(source, "regionBasis")?;
            if !matches!(basis, "cameraAF" | "manualSubject" | "manualEye") {
                return Err("Unsupported focus region basis".into());
            }
            if basis == "cameraAF" {
                let tuple:Option<String>=db.query_row("SELECT json_extract(af_json,'$.tuple') FROM lc_inspect_files
                    WHERE file_id=?1 AND content_id=?2 AND json_extract(af_json,'$.state')='available'",params![f,c],|r|r.get(0)).optional()?;
                let a: Vec<u32> = serde_json::from_str(
                    tuple
                        .as_deref()
                        .ok_or("No verified camera AF location for this file version")?,
                )?;
                if a.len() != 4
                    || a[0] == 0
                    || a[1] == 0
                    || (x + w / 2.0 - f64::from(a[2]) / f64::from(a[0])).abs() > w / 40.0
                    || (y + h / 2.0 - f64::from(a[3]) / f64::from(a[1])).abs() > h / 40.0
                {
                    return Err("Patch does not cover the recorded camera AF point".into());
                }
            }
            if source["pixelScale"] != 1
                || !matches!(
                    source["inputKind"].as_str(),
                    Some("nativeJPEG" | "nativeRAW")
                )
            {
                Some("proxyOnly")
            } else if pixels < 1024 {
                Some("insufficientPixels")
            } else if !(0.03..=0.97).contains(&mean) || clipping > 0.45 {
                Some("underOrOverexposed")
            } else if mean < 0.10 && contrast < 0.045 {
                // In dim, weakly structured patches sensor noise can dominate the fine-detail ratio.
                Some("lowSignalShadow")
            } else if contrast < 0.025 || grad < 0.004 {
                Some("lowTexture")
            } else if anisotropy > 0.82 {
                Some("directionalEdgesOrMotion")
            } else {
                score = lap.sqrt() / contrast.max(0.025);
                let key = format!(
                    "{}|{}|{}|{}",
                    basis,
                    string(source, "comparisonKey")?,
                    string(source, "inputKind")?,
                    pixels
                );
                cohorts.entry(key.clone()).or_default().push(score);
                cohort = Some(key);
                None
            }
        };
        parsed.push(Frame {
            source,
            file: f,
            content: c,
            score,
            reason,
            cohort,
        });
    }
    let mut summaries = Map::new();
    let references: std::collections::BTreeMap<_, _> = cohorts
        .into_iter()
        .filter_map(|(k, mut values)| {
            if values.len() < 3 {
                return None;
            }
            values.sort_by(f64::total_cmp);
            let start = values.len() / 2;
            let reference = median(&mut values[start..]);
            Some((k, reference))
        })
        .collect();
    for frame in parsed {
        let reference = frame
            .cohort
            .as_deref()
            .and_then(|k| references.get(k))
            .copied();
        let ratio = reference.filter(|n| *n > 0.0).map(|n| frame.score / n);
        let (code, reason, confidence) = if let Some(issue) = frame.reason {
            (
                "unknown",
                if issue == "unavailable" {
                    frame.source["unavailable"].as_str().unwrap_or(issue)
                } else {
                    issue
                },
                0.0,
            )
        } else {
            match ratio {
                Some(q) if q < 0.45 => (
                    "suspectedBlur",
                    "relativeFineDetailLoss",
                    ((0.45 - q) / 0.45 + 0.5).min(0.95),
                ),
                Some(q) if q >= 0.85 => (
                    "clear",
                    "comparableFineDetail",
                    (0.55 + (q - 0.85) * 0.4).min(0.92),
                ),
                Some(_) => ("unknown", "ambiguousRelativeDetail", 0.0),
                None => ("unknown", "insufficientComparableFrames", 0.0),
            }
        };
        let observation = json!({"method":"native-region-relative-v2","groupID":gid,"groupRevision":revision,"machine":code,"reason":reason,"confidence":confidence,
            "score":frame.score,"reference":reference,"relativeScore":ratio,"frame":frame.source});
        db.execute("INSERT INTO lc_inspect_focus(file_id,content_id,machine,evidence) VALUES(?,?,?,?) ON CONFLICT(file_id,content_id)
            DO UPDATE SET machine=excluded.machine,evidence=excluded.evidence",params![frame.file,frame.content,code,observation.to_string()])?;
        file_change(db, frame.file)?;
        summaries.insert(
            frame.file.into(),
            json!({"machine":code,"reason":reason,"confidence":confidence}),
        );
    }
    Ok(json!({"groupID":gid,"frames":summaries}))
}
