//! Reconstruct the published Swift scan's corroboration from persisted assets.
//! Within a flush, each source session is indexed once, including unmatched peers.
use super::*;
use std::collections::HashMap;
use unicode_normalization::UnicodeNormalization;

#[derive(Clone)]
struct Facts {
    root: String,
    stem: String,
    camera: Option<String>,
    time: Option<f64>,
    width: Option<i64>,
    height: Option<i64>,
    content: Option<String>,
    role: String,
}
#[derive(Default)]
pub(super) struct SessionFacts {
    files: HashMap<String, Facts>,
    candidates: HashMap<(String, String), (usize, usize)>,
}
impl SessionFacts {
    pub(super) fn load(db: &Connection, session: &str) -> Result<Self> {
        let mut facts = Self::default();
        let mut st=db.prepare("SELECT i.asset_id,COALESCE(o.root_id,'source:'||i.session_id),i.relative_path,i.role,i.content_id,
            json_extract(a.data,'$.camera'),json_extract(a.data,'$.capturedAt'),json_extract(a.data,'$.width'),json_extract(a.data,'$.height')
            FROM lc_asset_input i JOIN assets a ON a.id=i.asset_id LEFT JOIN lc_occurrences o ON o.session_id=i.session_id AND o.asset_id=i.asset_id
            WHERE i.session_id=?1")?;
        let mut rows = st.query([session])?;
        while let Some(row) = rows.next()? {
            let id: String = row.get(0)?;
            let root: String = row.get(1)?;
            let path: Option<String> = row.get(2)?;
            let role: String = row.get(3)?;
            if !matches!(role.as_str(), "raw" | "jpeg") {
                continue;
            }
            let Some(path) = path else {
                continue;
            };
            let Some((stem, _)) = path.rsplit_once('.') else {
                continue;
            };
            let stem: String = stem.nfc().collect();
            let count = facts
                .candidates
                .entry((root.clone(), stem.clone()))
                .or_default();
            if role == "raw" {
                count.0 += 1;
            } else {
                count.1 += 1;
            }
            let camera: Option<String> = row.get(5)?;
            facts.files.insert(
                id,
                Facts {
                    root,
                    stem,
                    role,
                    content: row.get(4)?,
                    camera: camera
                        .map(|s| s.trim().to_owned())
                        .filter(|s| !s.is_empty()),
                    time: row.get(6)?,
                    width: row.get(7)?,
                    height: row.get(8)?,
                },
            );
        }
        Ok(facts)
    }
    pub(super) fn unique_candidates(&self) -> Vec<(&str, &str)> {
        let mut pairs = BTreeMap::<(&str, &str), (Option<&str>, Option<&str>)>::new();
        for (id, f) in &self.files {
            let p = pairs.entry((&f.root, &f.stem)).or_default();
            if f.role == "raw" {
                p.0 = Some(id);
            } else {
                p.1 = Some(id);
            }
        }
        pairs
            .into_iter()
            .filter_map(|((root, stem), (raw, jpg))| {
                (self.candidates.get(&(root.to_owned(), stem.to_owned())) == Some(&(1, 1)))
                    .then_some(raw.zip(jpg))
                    .flatten()
            })
            .collect()
    }
    pub(super) fn assess(&self, raw: &str, jpeg: &str, pair: &Value) -> (Value, bool) {
        let mut e = json!({"source":"v7-source-corroboration-v1","pairID":pair["id"]});
        let (Some(a), Some(b)) = (self.files.get(raw), self.files.get(jpeg)) else {
            return (e, false);
        };
        let same_source = a.root == b.root && a.stem == b.stem;
        let counts = self
            .candidates
            .get(&(a.root.clone(), a.stem.clone()))
            .copied()
            .unwrap_or_default();
        let same_camera = a.camera.is_some() && a.camera == b.camera;
        let time = a
            .time
            .zip(b.time)
            .filter(|(x, y)| x.is_finite() && y.is_finite())
            .map(|(x, y)| (x - y).abs());
        let geometry = a.width.is_some_and(|n| n > 0)
            && a.height.is_some_and(|n| n > 0)
            && a.width == b.width
            && a.height == b.height;
        let mut accepted = a.role == "raw"
            && b.role == "jpeg"
            && a.content.is_some()
            && b.content.is_some()
            && same_source
            && counts == (1, 1)
            && same_camera
            && time.is_some_and(|v| v < 0.001)
            && geometry;
        e["rawContentID"] = json!(a.content);
        e["jpegContentID"] = json!(b.content);
        e["rootID"] = json!(a.root);
        e["relativeStemDigest"] = json!(digest_id("relative-stem", &[&a.stem]));
        e["sameSourceAndStem"] = json!(same_source);
        e["candidateCounts"] = json!([counts.0, counts.1]);
        e["sameCameraModel"] = json!(same_camera);
        e["captureDeltaSeconds"] = json!(time);
        e["sameDimensions"] = json!(geometry);
        // A runtime extractor may attach stronger, digest-bound facts. A known
        // serial, subsecond, or frame disagreement overrides the local fallback.
        if let Some(extra) = pair.get("evidence") {
            let orig = &extra["raw"];
            let mate = &extra["jpeg"];
            let bound = a.content.is_some()
                && b.content.is_some()
                && orig["contentID"].as_str() == a.content.as_deref()
                && mate["contentID"].as_str() == b.content.as_deref();
            let conflict = ["cameraSerial", "captureTime", "subsecond", "frameNumber"]
                .iter()
                .any(|key| {
                    orig[*key]
                        .as_str()
                        .zip(mate[*key].as_str())
                        .is_some_and(|(x, y)| !x.is_empty() && !y.is_empty() && x != y)
                });
            e["supplementalBound"] = json!(bound);
            e["supplementalConflict"] = json!(conflict);
            if bound && !conflict && same_source && counts == (1, 1) {
                e["raw"] = orig.clone();
                e["jpeg"] = mate.clone();
            } else {
                accepted = false;
            }
        }
        (e, accepted)
    }
}
