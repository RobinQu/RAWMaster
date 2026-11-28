//! Reconstruct the published Swift scan's corroboration from persisted assets.
//! Within a flush, each source session is indexed once, including unmatched peers.
use super::*;
use serde::Deserialize;
use std::collections::HashMap;
use unicode_normalization::UnicodeNormalization;

const CAPTURE_METADATA_COLUMNS: &str = "
    CASE COALESCE(json_type(a.data,'$.captureClock'),'absent')
        WHEN 'absent' THEN NULL
        WHEN 'object' THEN json_extract(a.data,'$.captureClock')
        ELSE 'null'
    END,
    CASE WHEN json_type(a.data,'$.cameraSerialDigest')='text'
        THEN json_extract(a.data,'$.cameraSerialDigest') END";

pub(super) enum Corroboration {
    Confirmed,
    Insufficient,
    Contradicted,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CaptureClock {
    local_second: i64,
    nanosecond: Option<i64>,
    offset_minutes: Option<i64>,
    has_invalid_tags: bool,
    #[serde(rename = "subsecondTruncated")]
    _subsecond_truncated: bool,
}

impl CaptureClock {
    fn parse(wire: &str) -> Option<Self> {
        let clock: Self = serde_json::from_str(wire).ok()?;
        (!clock.has_invalid_tags
            && (-62_135_596_800..=253_402_300_799).contains(&clock.local_second)
            && clock
                .nanosecond
                .is_none_or(|ns| (0..=999_999_999).contains(&ns))
            && clock
                .offset_minutes
                .is_none_or(|minutes| (-840..=840).contains(&minutes)))
        .then_some(clock)
    }

    fn compare(&self, other: &Self) -> TimeComparison {
        let mut seconds = self.local_second - other.local_second;
        if let (Some(a), Some(b)) = (self.offset_minutes, other.offset_minutes) {
            seconds -= (a - b) * 60;
        }
        match self.nanosecond.zip(other.nanosecond) {
            Some((a, b)) => {
                let nanoseconds = (i128::from(seconds) * 1_000_000_000 + i128::from(a - b)).abs();
                TimeComparison {
                    delta_seconds: nanoseconds as f64 / 1_000_000_000.0,
                    compatible: nanoseconds < 1_000_000,
                }
            }
            None => TimeComparison {
                delta_seconds: seconds.abs() as f64,
                compatible: seconds == 0,
            },
        }
    }
}

struct TimeComparison {
    delta_seconds: f64,
    compatible: bool,
}

enum Clock {
    Legacy,
    Declared(Option<CaptureClock>),
}

struct CaptureMetadata {
    clock: Clock,
    serial_digest: Option<String>,
}

impl CaptureMetadata {
    fn read(row: &rusqlite::Row<'_>, column: usize) -> rusqlite::Result<Self> {
        let clock = match row.get::<_, Option<String>>(column)? {
            Some(wire) => Clock::Declared(CaptureClock::parse(&wire)),
            None => Clock::Legacy,
        };
        let serial_digest = row.get::<_, Option<String>>(column + 1)?.filter(|digest| {
            digest.len() == 64
                && digest
                    .bytes()
                    .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
        });
        Ok(Self {
            clock,
            serial_digest,
        })
    }

    fn modern_time(&self, other: &Self) -> Option<TimeComparison> {
        match (&self.clock, &other.clock) {
            (Clock::Declared(Some(a)), Clock::Declared(Some(b))) => Some(a.compare(b)),
            _ => None,
        }
    }

    fn conflicting_serial(&self, other: &Self) -> bool {
        self.serial_digest
            .as_ref()
            .zip(other.serial_digest.as_ref())
            .is_some_and(|(a, b)| a != b)
    }
}

pub(super) fn permits_bound_supplement(
    db: &Connection,
    raw: (&str, &str),
    jpeg: (&str, &str),
) -> Result<bool> {
    let mut st = db.prepare_cached(&format!(
        "SELECT DISTINCT {CAPTURE_METADATA_COLUMNS}
         FROM lc_asset_files f JOIN lc_asset_input i USING(asset_id) JOIN assets a ON a.id=f.asset_id
         WHERE f.file_id=?1 AND i.content_id=?2"
    ))?;
    // The file ID index limits this to the occurrences containing the claimed bytes.
    let mut lookup = |(file, content): (&str, &str)| {
        st.query_map(params![file, content], |row| CaptureMetadata::read(row, 0))?
            .collect::<rusqlite::Result<Vec<_>>>()
    };
    let raw = lookup(raw)?;
    if raw.is_empty() {
        return Ok(false);
    }
    let jpeg = lookup(jpeg)?;
    Ok(!jpeg.is_empty()
        && !raw.iter().any(|a| {
            jpeg.iter().any(|b| {
                a.conflicting_serial(b) || a.modern_time(b).is_some_and(|time| !time.compatible)
            })
        }))
}

struct Facts {
    root: String,
    stem: String,
    camera: Option<String>,
    legacy_time: Option<f64>,
    capture: CaptureMetadata,
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
        let mut st=db.prepare(&format!("SELECT i.asset_id,COALESCE(o.root_id,'source:'||i.session_id),i.relative_path,i.role,i.content_id,
            json_extract(a.data,'$.camera'),
            CASE WHEN json_type(a.data,'$.capturedAt') IN ('integer','real') THEN json_extract(a.data,'$.capturedAt') END,
            json_extract(a.data,'$.width'),json_extract(a.data,'$.height'),{CAPTURE_METADATA_COLUMNS}
            FROM lc_asset_input i JOIN assets a ON a.id=i.asset_id LEFT JOIN lc_occurrences o ON o.session_id=i.session_id AND o.asset_id=i.asset_id
            WHERE i.session_id=?1"))?;
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
                    legacy_time: row.get(6)?,
                    capture: CaptureMetadata::read(row, 9)?,
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
    pub(super) fn assess(&self, raw: &str, jpeg: &str, pair: &Value) -> (Value, Corroboration) {
        let mut e = json!({"source":"v7-source-corroboration-v1","pairID":pair["id"]});
        let (Some(a), Some(b)) = (self.files.get(raw), self.files.get(jpeg)) else {
            return (e, Corroboration::Insufficient);
        };
        let same_source = a.root == b.root && a.stem == b.stem;
        let counts = self
            .candidates
            .get(&(a.root.clone(), a.stem.clone()))
            .copied()
            .unwrap_or_default();
        let same_camera = a.camera.is_some() && a.camera == b.camera;
        let both_legacy = matches!(
            (&a.capture.clock, &b.capture.clock),
            (Clock::Legacy, Clock::Legacy)
        );
        let modern_time = a.capture.modern_time(&b.capture);
        let clock_conflict = modern_time.as_ref().is_some_and(|time| !time.compatible);
        let serial_conflict = a.capture.conflicting_serial(&b.capture);
        let time = if both_legacy {
            a.legacy_time
                .zip(b.legacy_time)
                .filter(|(x, y)| x.is_finite() && y.is_finite())
                .map(|(x, y)| {
                    let delta_seconds = (x - y).abs();
                    TimeComparison {
                        delta_seconds,
                        compatible: delta_seconds < 0.001,
                    }
                })
        } else {
            modern_time
        };
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
            && time.as_ref().is_some_and(|v| v.compatible)
            && geometry;
        e["rawContentID"] = json!(a.content);
        e["jpegContentID"] = json!(b.content);
        e["rootID"] = json!(a.root);
        e["relativeStemDigest"] = json!(digest_id("relative-stem", &[&a.stem]));
        e["sameSourceAndStem"] = json!(same_source);
        e["candidateCounts"] = json!([counts.0, counts.1]);
        e["sameCameraModel"] = json!(same_camera);
        e["captureDeltaSeconds"] = json!(time.map(|time| time.delta_seconds));
        e["sameDimensions"] = json!(geometry);
        if clock_conflict {
            e["captureClockConflict"] = json!(true);
        }
        if serial_conflict {
            e["cameraSerialConflict"] = json!(true);
        }
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
        let corroboration = if clock_conflict || serial_conflict {
            Corroboration::Contradicted
        } else if accepted {
            Corroboration::Confirmed
        } else {
            Corroboration::Insufficient
        };
        (e, corroboration)
    }
}
