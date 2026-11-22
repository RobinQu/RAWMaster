//! Suggestions for an already confirmed identity. This read never changes human records.
use super::{cache, digest, field, people, settings, Input, FACES};
use crate::query::works::{discovery_inputs_selected, discovery_work_ids};
use crate::Result;
use people::Face;
use rusqlite::{params, Connection};
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};

const MAX_REFERENCES: usize = 8;
struct Gate {
    minimum: f64,
    margin: f64,
    single: f64,
}
// Review suggestions only. All scores are in the model's normalized cosine space.
const PERSON_GATE: Gate = Gate {
    minimum: 0.62,
    margin: 0.08,
    single: 0.66,
};

/// SHA aliases, RAW+JPEG captures, virtual copies, and their transitive aliases each get
/// a single source identity. They cannot multiply template votes or rediscover themselves.
fn source_groups(inputs: &BTreeMap<String, Input>) -> BTreeMap<String, usize> {
    fn root(links: &mut [usize], mut index: usize) -> usize {
        while links[index] != index {
            links[index] = links[links[index]];
            index = links[index];
        }
        index
    }
    let mut links: Vec<usize> = (0..inputs.len()).collect();
    let mut aliases = BTreeMap::new();
    for (index, item) in inputs.values().enumerate() {
        for (kind, key) in [
            ("capture", item.capture_id.as_deref()),
            ("file", item.file_id.as_deref()),
            ("sha", item.sha256.as_deref()),
        ] {
            let Some(key) = key.filter(|s| !s.is_empty()) else {
                continue;
            };
            if kind == "sha" && (key.len() != 64 || !key.bytes().all(|v| v.is_ascii_hexdigit())) {
                continue;
            }
            let normalized = if kind == "sha" {
                key.to_ascii_lowercase()
            } else {
                key.to_owned()
            };
            if let Some(previous) = aliases.insert((kind, normalized), index) {
                let a = root(&mut links, index);
                let b = root(&mut links, previous);
                links[a] = b;
            }
        }
    }
    inputs
        .keys()
        .enumerate()
        .map(|(i, work)| (work.clone(), root(&mut links, i)))
        .collect()
}

#[derive(Clone, Copy)]
struct Reference<'a> {
    id: &'a str,
    source: usize,
    feature: &'a [f32],
    quality: f64,
}
fn quality(face: &Face) -> f64 {
    // Both measurements exist for v8 observations including earlier index generations.
    // Relative box size is a proxy for useful resolution on the fixed long-edge preview.
    face.box_data["confidence"].as_f64().unwrap_or(0.) * (face.region[2] * face.region[3]).sqrt()
}
fn choose_templates(mut candidates: Vec<Reference<'_>>) -> Vec<Reference<'_>> {
    candidates.sort_by(|a, b| b.quality.total_cmp(&a.quality).then(a.id.cmp(b.id)));
    let mut sources = BTreeSet::new();
    candidates.retain(|r| sources.insert(r.source));
    if candidates.len() <= MAX_REFERENCES {
        return candidates;
    }
    let mut selected = vec![candidates.remove(0)];
    // Seed using the clearest available face. Add the normalized embedding farthest
    // from its closest already-selected template. Quality/ID break ties deterministically.
    let mut nearest = vec![-1.0_f64; candidates.len()];
    while selected.len() < MAX_REFERENCES {
        let last = selected.last().unwrap();
        for (n, c) in nearest.iter_mut().zip(&candidates) {
            *n = n.max(cache::cosine(c.feature, last.feature));
        }
        let index = (0..candidates.len())
            .min_by(|a, b| nearest[*a].total_cmp(&nearest[*b]).then(a.cmp(b)))
            .unwrap();
        selected.push(candidates.remove(index));
        nearest.remove(index);
    }
    selected
}

struct Candidate {
    row: Value,
    score: f64,
    id: String,
}

// A single exceptionally similar saved face must not drown out the rest of a person's
// examples. Each template already represents a distinct original/capture.
fn identity_score(templates: &[Reference<'_>], source: usize, feature: &[f32]) -> Option<f64> {
    let mut first: Option<f64> = None;
    let mut second: Option<f64> = None;
    for template in templates.iter().filter(|r| r.source != source) {
        let s = cache::cosine(feature, template.feature);
        if first.is_none_or(|v| s > v) {
            second = first;
            first = Some(s)
        } else if second.is_none_or(|v| s > v) {
            second = Some(s)
        }
    }
    first.map(|a| second.map_or(a, |b| (a + b) / 2.))
}

fn proposals(
    faces: &[Face],
    sources: &BTreeMap<String, usize>,
    scoped: &BTreeSet<String>,
    verified: &BTreeSet<String>,
    person: &str,
) -> (Vec<Candidate>, usize, usize, usize) {
    let mut by_person: BTreeMap<&str, Vec<Reference>> = BTreeMap::new();
    let confirmed_sources: BTreeSet<_> = verified
        .iter()
        .filter_map(|work| sources.get(work).copied())
        .collect();
    let mut ready_target_works = BTreeSet::new();
    for face in faces {
        let Some(id) = face.assigned.as_deref() else {
            continue;
        };
        let source = sources[&face.work];
        if let Some(feature) = face.feature.as_deref() {
            by_person.entry(id).or_default().push(Reference {
                id: &face.id,
                source,
                feature,
                quality: quality(face),
            });
            if id == person {
                ready_target_works.insert(&face.work);
            }
        }
    }
    let gallery: BTreeMap<_, _> = by_person
        .into_iter()
        .map(|(id, faces)| (id, choose_templates(faces)))
        .collect();
    let refs = gallery.get(person).map_or(0, Vec::len);
    let mut candidates = Vec::new();
    let mut unknown = 0;
    for face in faces {
        if !scoped.contains(&face.work) || face.assigned.is_some() {
            continue;
        }
        unknown += 1;
        let source = sources[&face.work];
        if refs == 0
            || face.ambiguous
            || face.blocked.contains(person)
            || confirmed_sources.contains(&source)
        {
            continue;
        }
        let Some(feature) = &face.feature else {
            continue;
        };
        let mut target = None;
        let mut competitor: Option<f64> = None;
        for (id, templates) in &gallery {
            if face.blocked.contains(*id) {
                continue;
            }
            let similarity = identity_score(templates, source, feature);
            let Some(s) = similarity else { continue };
            if *id == person {
                target = Some(s)
            } else {
                competitor = Some(competitor.map_or(s, |v| v.max(s)))
            }
        }
        let Some(score) = target else { continue };
        let margin = competitor.map(|s| score - s);
        if margin.map_or(score < PERSON_GATE.single, |d| {
            score < PERSON_GATE.minimum || d < PERSON_GATE.margin
        }) {
            continue;
        }
        let mut row = face.box_data.clone();
        row["score"] = json!(score);
        row["margin"] = json!(margin);
        candidates.push(Candidate {
            row,
            score,
            id: face.id.clone(),
        });
    }
    candidates.sort_by(|a, b| b.score.total_cmp(&a.score).then(a.id.cmp(&b.id)));
    (candidates, refs, unknown, ready_target_works.len())
}

fn indexed_outputs(
    db: &Connection,
    inputs: &BTreeMap<String, Input>,
) -> Result<BTreeMap<String, i64>> {
    let versions: Vec<_> = inputs
        .values()
        .map(|i| (&i.work_id, &i.input_version))
        .collect();
    let mut q=db.prepare_cached("SELECT o.work_id,o.detections FROM json_each(?1) j
        JOIN lc_discover_outputs o ON o.work_id=json_extract(j.value,'$[0]') AND o.input_version=json_extract(j.value,'$[1]')
        AND o.kind='faces' AND o.model=?2")?;
    let rows = q.query_map(params![serde_json::to_string(&versions)?, FACES], |r| {
        Ok((r.get(0)?, r.get(1)?))
    })?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}

pub(super) fn read(db: &Connection, b: &Value) -> Result<Value> {
    let person = field(b, "personID")?;
    let limit = b
        .get("limit")
        .map(|v| {
            v.as_u64()
                .filter(|n| (1..=500).contains(n))
                .ok_or("invalid person match page size")
        })
        .transpose()?
        .unwrap_or(60) as usize;
    let scope = b.get("scope").cloned().unwrap_or_else(|| json!({}));
    let config = settings(db)?;
    let human = config["humanRevision"]
        .as_i64()
        .ok_or("invalid human revision")?;
    let library: String =
        db.query_row("SELECT value FROM lc_meta WHERE key='libraryID'", [], |r| {
            r.get(0)
        })?;
    let scoped: BTreeSet<String> = discovery_work_ids(db, &scope)?.into_iter().collect();
    let mut output = json!({"status":"indexDisabled","personID":person,"model":FACES,"items":[],"eligibleWorks":scoped.len(),
        "indexedWorks":0,"unknownFaces":0,"referenceCount":0,"confirmedWorkCount":0,"unindexedReferenceWorks":0,
        "count":0,"nextCursor":null,"humanRevision":human,"libraryID":library});
    if config["faces"] != true {
        return Ok(output);
    }
    // Select cheap IDs for coverage first. Only a face result or a human reference
    // warrants resolving its current input version, paths, and cached feature metadata.
    let mut q=db.prepare("SELECT j.value FROM json_each(?1) j
        WHERE EXISTS(SELECT 1 FROM lc_discover_outputs o WHERE o.work_id=j.value AND o.kind='faces' AND o.model=?2)
           OR EXISTS(SELECT 1 FROM lc_discover_anchors a WHERE a.work_id=j.value)")?;
    let in_scope = q
        .query_map(params![serde_json::to_string(&scoped)?, FACES], |r| {
            r.get(0)
        })?
        .collect::<rusqlite::Result<Vec<String>>>()?;
    let mut inputs = BTreeMap::new();
    if !in_scope.is_empty() {
        for input in discovery_inputs_selected(db, &scope, Some(&in_scope))? {
            inputs.insert(input.work_id.clone(), input);
        }
    }
    // A folder/project restricts returned works. Enrolled identities may use their
    // independent, currently visible same-library references from other folders.
    let mut q = db.prepare("SELECT DISTINCT work_id FROM lc_discover_labels ORDER BY work_id")?;
    let references = q
        .query_map([], |r| r.get(0))?
        .collect::<rusqlite::Result<Vec<String>>>()?;
    let extra: Vec<String> = references
        .into_iter()
        .filter(|work| !scoped.contains(work))
        .collect();
    if !extra.is_empty() {
        for input in discovery_inputs_selected(db, &json!({}), Some(&extra))? {
            inputs.insert(input.work_id.clone(), input);
        }
    }
    let verified: BTreeSet<_> = people::confirmed(db, person)?
        .into_iter()
        .filter(|w| inputs.contains_key(w))
        .collect();
    let outputs = indexed_outputs(db, &inputs)?;
    let origins = source_groups(&inputs);
    let evaluated: Vec<Input> = inputs
        .into_values()
        .filter(|i| outputs.contains_key(&i.work_id))
        .collect();
    let mut cache = cache::open(db, false)?;
    let cache_tx = cache.as_mut().map(|c| c.transaction()).transpose()?;
    let faces = people::scan(db, cache_tx.as_deref(), &evaluated, true)?;
    let mut counts: BTreeMap<&str, (i64, i64)> = BTreeMap::new();
    for f in &faces {
        let count = counts.entry(&f.work).or_default();
        count.0 += 1;
        count.1 += i64::from(f.feature.is_some());
    }
    let indexed = outputs
        .iter()
        .filter(|(work, n)| {
            scoped.contains(*work)
                && counts.get(work.as_str()).copied().unwrap_or_default() == (**n, **n)
        })
        .count();
    let (rows, reference_count, unknown, ready_references) =
        proposals(&faces, &origins, &scoped, &verified, person);
    let scores: Vec<_> = rows
        .iter()
        .map(|r| {
            (
                &r.id,
                r.score.to_bits(),
                &r.row["margin"],
                &r.row["inputVersion"],
            )
        })
        .collect();
    let watermark = cache::tip(db)?;
    let token = digest(serde_json::to_vec(&(
        &library,
        FACES,
        person,
        &scope,
        human,
        watermark,
        &config["revision"],
        indexed,
        unknown,
        reference_count,
        ready_references,
        scores,
    ))?);
    let cursor = b.get("cursor").filter(|v| !v.is_null());
    let stale = cursor.is_some_and(|c| c["fingerprint"] != token);
    let offset = cursor
        .map(|c| {
            c["offset"]
                .as_u64()
                .and_then(|n| usize::try_from(n).ok())
                .ok_or("invalid person match offset")
        })
        .transpose()?
        .unwrap_or(0);
    let count = rows.len();
    output["status"] = json!(if stale {
        "staleCursor"
    } else if reference_count == 0 {
        "referenceUnindexed"
    } else {
        "ok"
    });
    output["count"] = json!(count);
    output["referenceCount"] = json!(reference_count);
    output["confirmedWorkCount"] = json!(verified.len());
    output["unindexedReferenceWorks"] = json!(verified.len().saturating_sub(ready_references));
    output["indexedWorks"] = json!(indexed);
    output["unknownFaces"] = json!(unknown);
    output["watermark"] = json!(watermark);
    if !stale {
        let end = offset.saturating_add(limit);
        if end < count {
            output["nextCursor"] = json!({"fingerprint":token,"offset":end});
        }
        output["items"] = json!(rows
            .into_iter()
            .skip(offset)
            .take(limit)
            .map(|r| r.row)
            .collect::<Vec<_>>());
    }
    Ok(output)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn raw_and_jpeg_capture_aliases_and_byte_identical_copies_are_transitive() {
        let input = |id: &str, sha: String, capture: &str| {
            Input::new(
                id.into(),
                id.into(),
                "master".into(),
                Some(id.into()),
                None,
                None,
                None,
                None,
                None,
                None,
                Some(sha),
                Some(8),
                "original",
                Some(capture.into()),
            )
            .unwrap()
        };
        let items = [
            input("raw", "a".repeat(64), "exposure-one"),
            input("jpeg", "b".repeat(64), "exposure-one"),
            input("independent-copy", "B".repeat(64), "other-project-marker"),
            input("different", "c".repeat(64), "another-exposure"),
        ]
        .into_iter()
        .map(|i| (i.work_id.clone(), i))
        .collect();
        let groups = source_groups(&items);
        assert_eq!(groups["raw"], groups["jpeg"]);
        assert_eq!(groups["raw"], groups["independent-copy"]);
        assert_ne!(groups["raw"], groups["different"]);
    }
}
