//! Optional, offline replay of a private frozen evaluation manifest. Only aggregated counts leave the fixture.
use super::Library;
use rawmaster_library::{discovery, organization};
use rusqlite::{Connection, MAIN_DB};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    path::PathBuf,
};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Observation {
    #[serde(rename = "faceID")]
    id: String,
    #[serde(rename = "imageID")]
    work: String,
    #[serde(rename = "personID")]
    person: String,
    day: String,
    body: Option<String>,
    #[serde(default)]
    r#box: Option<[f64; 4]>,
    #[serde(default)]
    landmarks: Option<Vec<[f64; 2]>>,
    #[serde(default)]
    detection_score: Option<f64>,
    #[serde(default, rename = "proxySHA256")]
    sha: Option<String>,
}
#[derive(Deserialize)]
struct Manifest {
    faces: Vec<Observation>,
    unmapped: Vec<Observation>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Features {
    dimensions: usize,
    #[serde(rename = "manifestSHA256")]
    manifest_sha: String,
    vectors: BTreeMap<String, Vec<f32>>,
}
#[derive(Default, Serialize)]
#[serde(rename_all = "camelCase")]
struct Metrics {
    known: usize,
    correct: usize,
    wrong: usize,
    abstained: usize,
    undetected_known: usize,
    naturally_unenrolled: usize,
    natural_wrong: usize,
    removed_identity_queries: usize,
    removed_identity_wrong: usize,
}
fn training_days(records: &[&Observation], balanced: bool) -> BTreeSet<String> {
    let days: Vec<_> = records
        .iter()
        .map(|r| r.day.clone())
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect();
    if !balanced {
        return days[..days.len() / 2].iter().cloned().collect();
    }
    assert!(days.len() <= 14);
    let mut totals = BTreeMap::new();
    for r in records {
        *totals.entry(&r.person).or_insert(0_i32) += 1;
    }
    let mut best = None;
    for mask in 0usize..1 << days.len() {
        if mask.count_ones() as usize != days.len() / 2 {
            continue;
        }
        let chosen: BTreeSet<_> = days
            .iter()
            .enumerate()
            .filter(|(i, _)| mask & (1 << i) != 0)
            .map(|(_, d)| d.clone())
            .collect();
        let mut counts = BTreeMap::new();
        for r in records.iter().filter(|r| chosen.contains(&r.day)) {
            *counts.entry(&r.person).or_insert(0_i32) += 1;
        }
        let (mut least, mut imbalance) = (1.0_f64, 0.0_f64);
        for (&id, &n) in &totals {
            let c = counts.get(id).copied().unwrap_or_default();
            least = least.min(f64::from(c.min(n - c)) / f64::from(n));
            imbalance += f64::from((2 * c - n).abs()) / f64::from(n);
        }
        let score = (least, -imbalance);
        if best
            .as_ref()
            .is_none_or(|(s, g)| score > *s || (score == *s && chosen < *g))
        {
            best = Some((score, chosen));
        }
    }
    best.unwrap().1
}

#[test]
#[ignore = "requires a private frozen manifest and final model vectors; see environment variable names in this test"]
fn replay_person_gallery() {
    use sha2::{Digest, Sha256};
    let manifest_path = std::env::var("RAWMASTER_FACE_REPLAY_MANIFEST").unwrap();
    let vector_path = std::env::var("RAWMASTER_FACE_REPLAY_VECTORS").unwrap();
    let output = PathBuf::from(std::env::var("RAWMASTER_FACE_REPLAY_RESULT").unwrap());
    let bytes = fs::read(manifest_path).unwrap();
    let manifest: Manifest = serde_json::from_slice(&bytes).unwrap();
    let features: Features = serde_json::from_slice(&fs::read(vector_path).unwrap()).unwrap();
    assert_eq!(
        features.manifest_sha,
        format!("{:x}", Sha256::digest(&bytes))
    );
    assert_eq!(features.dimensions, discovery::FACE_DIMENSIONS);
    let corpus: Vec<_> = manifest.faces.iter().chain(&manifest.unmapped).collect();
    let people: BTreeSet<_> = corpus.iter().map(|r| r.person.as_str()).collect();
    let mut photos: BTreeMap<&str, Vec<&Observation>> = BTreeMap::new();
    for r in &corpus {
        photos.entry(&r.work).or_default().push(r);
    }
    let library = Library::new();
    let mut observations = BTreeMap::new();
    for (work, faces) in &photos {
        library.work(
            work,
            faces.iter().find_map(|f| f.sha.as_deref()).unwrap_or(work),
            4,
        );
        let mut ready: Vec<_> = faces
            .iter()
            .filter(|f| features.vectors.contains_key(&f.id))
            .copied()
            .collect();
        ready.sort_by(|a, b| a.r#box.unwrap()[0].total_cmp(&b.r#box.unwrap()[0]));
        let detections=ready.iter().map(|r|json!({"box":r.r#box,"landmarks":r.landmarks,"confidence":r.detection_score,"vector":features.vectors[&r.id]})).collect();
        let current = library.index_vectors(work, detections);
        assert_eq!(current.len(), ready.len());
        observations.extend(
            ready
                .into_iter()
                .zip(current)
                .map(|(face, id)| (face.id.as_str(), id)),
        );
    }
    let mut report = json!({"model":discovery::FACES,"annotatedFaces":corpus.len(),"mappedFaces":observations.len(),"sourceWorks":photos.len(),
        "method":"Real final-package vectors; ordinary claim/finish and human assign; read-only production personMatches on disk. Fixed enrollment subsets per body, repeated after removing each true identity. Denominator includes unmapped human positives."});
    let mut case = 0;
    for (split, balanced) in [("balanced", true), ("chronological", false)] {
        let train = training_days(&corpus, balanced);
        for (name, physical) in [("differentDates", false), ("differentDatesAndBodies", true)] {
            let body_groups: BTreeSet<Option<&str>> = if physical {
                corpus
                    .iter()
                    .filter(|r| !train.contains(&r.day))
                    .filter_map(|r| r.body.as_deref().map(Some))
                    .collect()
            } else {
                BTreeSet::from([None])
            };
            let mut metric = Metrics::default();
            for body in body_groups {
                let enrolled: Vec<_> = corpus
                    .iter()
                    .copied()
                    .filter(|r| {
                        train.contains(&r.day)
                            && (!physical || r.body.as_deref().is_some_and(|s| Some(s) != body))
                            && observations.contains_key(r.id.as_str())
                    })
                    .collect();
                let query: Vec<_> = corpus
                    .iter()
                    .copied()
                    .filter(|r| !train.contains(&r.day) && (!physical || r.body.as_deref() == body))
                    .collect();
                for removed in std::iter::once(None).chain(people.iter().copied().map(Some)) {
                    case += 1;
                    let db_path = library._dir.path().join(format!("gallery-{case}.sqlite"));
                    library.db.backup(MAIN_DB, &db_path, None).unwrap();
                    let mut conn = Connection::open(&db_path).unwrap();
                    let tx = conn.transaction().unwrap();
                    let allowed: BTreeSet<_> = enrolled
                        .iter()
                        .map(|r| r.person.as_str())
                        .filter(|p| Some(*p) != removed)
                        .collect();
                    for person in &allowed {
                        let anchors: Vec<_> = enrolled
                            .iter()
                            .filter(|r| r.person == *person)
                            .map(|r| &observations[r.id.as_str()])
                            .collect();
                        discovery::apply(&tx,&json!({"action":"discover.assign","commandID":uuid::Uuid::new_v4().to_string(),"name":person,"personID":person,"observationIDs":anchors})).unwrap();
                    }
                    organization::apply(&tx,&json!({"action":"org.saveCollection","collectionID":"probes","kind":"regular","name":"Probes"})).unwrap();
                    let members: BTreeSet<_> = query.iter().map(|r| r.work.as_str()).collect();
                    organization::apply(&tx,&json!({"action":"org.setMembers","collectionID":"probes","workIDs":members})).unwrap();
                    tx.commit().unwrap();
                    let mut predicted = BTreeMap::new();
                    for person in &allowed {
                        let out=rawmaster_library::request(&db_path,&json!({"operation":"discovery","request":{"op":"personMatches","personID":person,"scope":{"collectionID":"probes"},"limit":500}})).unwrap();
                        assert_eq!(out["status"], "ok");
                        assert_eq!(out["eligibleWorks"], members.len());
                        assert!(out["nextCursor"].is_null());
                        for hit in out["items"].as_array().unwrap() {
                            assert!(hit["personID"].is_null());
                            assert!(predicted
                                .insert(hit["observationID"].as_str().unwrap().to_owned(), *person)
                                .is_none());
                        }
                    }
                    for probe in &query {
                        let predicted = observations
                            .get(probe.id.as_str())
                            .and_then(|id| predicted.get(id))
                            .copied();
                        if let Some(omitted) = removed {
                            if probe.person == omitted {
                                metric.removed_identity_queries += 1;
                                metric.removed_identity_wrong += usize::from(predicted.is_some());
                            }
                        } else if allowed.contains(probe.person.as_str()) {
                            metric.known += 1;
                            metric.undetected_known +=
                                usize::from(!observations.contains_key(probe.id.as_str()));
                            match predicted {
                                Some(p) if p == probe.person => metric.correct += 1,
                                Some(_) => metric.wrong += 1,
                                None => metric.abstained += 1,
                            };
                        } else {
                            metric.naturally_unenrolled += 1;
                            metric.natural_wrong += usize::from(predicted.is_some());
                        }
                    }
                }
            }
            assert_eq!(
                metric.correct + metric.wrong + metric.abstained,
                metric.known
            );
            assert!(metric.correct > 0);
            report[split][name] = json!(metric);
        }
    }
    fs::write(output, serde_json::to_vec_pretty(&report).unwrap()).unwrap();
}
