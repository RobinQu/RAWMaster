use super::*;
use rawmaster_library::resources::object_path;
use sha2::{Digest, Sha256};
use std::{fs, io::Write, path::PathBuf};

#[path = "workbench_item_delivery.rs"]
mod delivery;

fn stage_command(l: &Library, body: &Value) -> Result<(tempfile::NamedTempFile, Value)> {
    let mut file = tempfile::NamedTempFile::new_in(l._root.path())?;
    let bytes = serde_json::to_vec(body)?;
    file.write_all(&bytes)?;
    let command = json!({"action":"stageResource","path":file.path(),
        "sha256":hex::encode(Sha256::digest(&bytes)),"byteCount":bytes.len()});
    Ok((file, command))
}

fn stage(l: &Library, body: &Value) -> Result<Value> {
    let (_file, command) = stage_command(l, body)?;
    Ok(batch(&l.path, command)?["resource"].take())
}

fn body_for(item: &Value) -> Value {
    json!({"schema":1,"role":"item","work":item["work"],"version":item["version"]})
}

fn compact(l: &Library, mut inline: Value) -> Result<Value> {
    inline["schema"] = json!(2);
    inline["configuration"] = stage(
        l,
        &json!({"schema":1,"role":"configuration","configuration":inline["configuration"]}),
    )?;
    for item in inline["items"].as_array_mut().unwrap() {
        let reference = stage(l, &body_for(item))?;
        let mut source = item["version"]["source"].clone();
        source.as_object_mut().unwrap().remove("sourceLocation");
        *item = json!({"ordinal":item["ordinal"],"assetID":item["assetID"],"stem":item["stem"],
            "workID":item["work"]["id"],"versionID":item["version"]["id"],
            "source":source,"body":reference});
    }
    Ok(inline)
}

fn registry_counts(l: &Library) -> Result<(i64, i64)> {
    Ok(l.db.query_row(
        "SELECT (SELECT count(*) FROM lc_resources), (SELECT count(*) FROM lc_meta WHERE key GLOB 'wb032.*')",
        [],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )?)
}

fn object(root: &Path, reference: &Value) -> Result<PathBuf> {
    Ok(root
        .join("LibraryResources")
        .join(object_path(reference["sha256"].as_str().unwrap())?))
}

fn load_item(l: &Library, m: &Value, ordinal: usize) -> Result<Value> {
    batch(
        &l.path,
        json!({"action":"loadResource","batchID":m["batchID"],"role":"item","ordinal":ordinal}),
    )
}

fn second_photo(first: &Value) -> Value {
    let mut b = first.clone();
    b["ordinal"] = json!(2);
    b["assetID"] = json!("b");
    b["stem"] = json!("Café.v2");
    b["work"]["id"] = json!("work-b");
    b["version"]["workID"] = json!("work-b");
    b["version"]["id"] = json!("version-b");
    for owner in ["work", "version"] {
        b[owner]["source"]["assetID"] = json!("b");
        b[owner]["source"]["contentSHA256"] = json!("c".repeat(64));
    }
    b
}

// Match the native dimension/domain/float32 byte fingerprint and Swift Data Codable encoding.
fn lut_layer(number: u32, byte: u8, base64_group: &str) -> Value {
    let mut hash = Sha256::new();
    hash.update(b"RAWMaster/display-sRGB-CUBE-v1");
    for value in [64_f32, 0., 0., 0., 1., 1., 1.] {
        hash.update(value.to_le_bytes());
    }
    let rgb_bytes = 64_usize.pow(3) * 3 * 4;
    hash.update(vec![byte; rgb_bytes]);
    json!({"id":format!("00000000-0000-4000-8000-{number:012x}"),"amount":51.248178375505404,
        "cube":{"name":format!("Solid {number}"),"id":hex::encode(hash.finalize()),
        "dimension":64,"domainMin":[0,0,0],"domainMax":[1,1,1],
        "lutCubeRGB32":base64_group.repeat(rgb_bytes/3)}})
}

#[test]
fn two_large_luts_roundtrip_with_exact_recipe_and_shared_objects_across_batches() -> Result<()> {
    let l = fixture()?;
    let mut m = descriptor(&l, 20)?;
    let mut recipe: Value = serde_json::from_str(include_str!("neutral_v3_recipe.json"))?;
    recipe["adjustmentsV3"]["gradingLUTs"] = json!({"enabled":true,"layers":[
        lut_layer(1,0,"AAAA"),lut_layer(2,0x3f,"Pz8/")]});
    m["items"][0]["version"]["recipe"] = recipe;
    // Two independent photographs can use the exact same LUT stack.
    let second = second_photo(&m["items"][0]);
    m["items"].as_array_mut().unwrap().push(second);
    let exact_first_body = body_for(&m["items"][0]);
    let exact_second_body = body_for(&m["items"][1]);
    let mut frozen = compact(&l, m)?;
    assert!(frozen["items"][0]["body"]["byteCount"].as_i64().unwrap() > (8 << 20));
    assert!(serde_json::to_vec(&frozen)?.len() < 4096);
    assert_eq!(registry_counts(&l)?, (0, 0));
    let first = register(&l.path, &frozen)?;
    assert!(first["token"].is_string());
    assert_eq!(registry_counts(&l)?, (3, 2));
    assert_eq!(load_item(&l, &frozen, 1)?["body"], exact_first_body);
    assert_eq!(load_item(&l, &frozen, 2)?["body"], exact_second_body);
    assert_eq!(
        batch(
            &l.path,
            json!({"action":"load","batchID":frozen["batchID"]})
        )?["manifest"],
        frozen
    );
    assert_eq!(frozen["items"][0]["stem"], "Cafe\u{301}.v1");
    assert_eq!(frozen["items"][1]["stem"], "Café.v2");
    frozen["batchID"] = json!("00000000-0000-4000-8000-000000000021");
    assert!(register(&l.path, &frozen)?["token"].is_string());
    assert_eq!(registry_counts(&l)?, (3, 4));
    let wrong: i64 = l.db.query_row(
        "SELECT count(*) FROM lc_resources WHERE source_asset_id IS NOT NULL
        OR kind<>'recipeResource' OR resource_id<>'wb032:sha256:'||sha256",
        [],
        |r| r.get(0),
    )?;
    assert_eq!(wrong, 0);
    Ok(())
}

#[test]
fn swapped_valid_photos_and_wrong_roles_cannot_commit_a_partial_registration() -> Result<()> {
    let l = fixture()?;
    let mut inline = descriptor(&l, 30)?;
    let second = second_photo(&inline["items"][0]);
    inline["items"].as_array_mut().unwrap().push(second);
    let valid = compact(&l, inline)?;
    let mut swapped = valid.clone();
    swapped["items"][0]["body"] = valid["items"][1]["body"].clone();
    swapped["items"][1]["body"] = valid["items"][0]["body"].clone();
    assert!(register(&l.path, &swapped).is_err());
    for (pointer, change) in [
        ("/items/1/body", valid["configuration"].clone()),
        ("/configuration", valid["items"][0]["body"].clone()),
        ("/items/1/workID", json!("work-c")),
        ("/items/1/versionID", json!("version-c")),
        ("/items/1/source/projectID", json!("project-c")),
        ("/items/1/source/contentSHA256", json!("d".repeat(64))),
        ("/items/1/source/byteCount", json!(456)),
        (
            "/items/1/source/admissionFingerprint",
            json!("other-admission"),
        ),
    ] {
        let mut bad = valid.clone();
        *bad.pointer_mut(pointer).unwrap() = change;
        assert!(register(&l.path, &bad).is_err(), "{pointer}");
        assert_eq!(registry_counts(&l)?, (0, 0));
    }
    assert!(batch(&l.path, json!({"action":"list"}))?["batches"]
        .as_array()
        .unwrap()
        .is_empty());
    // An incompatible resource id must roll back registrations that preceded it in the transaction.
    let greatest = [
        &valid["configuration"],
        &valid["items"][0]["body"],
        &valid["items"][1]["body"],
    ]
    .into_iter()
    .map(|v| v["sha256"].as_str().unwrap())
    .max()
    .unwrap();
    l.db.execute(
        "INSERT INTO lc_resources VALUES(?1,'historicalLook','other',?2,5,NULL)",
        rusqlite::params![format!("wb032:sha256:{greatest}"), greatest],
    )?;
    assert!(register(&l.path, &valid).is_err());
    assert_eq!(registry_counts(&l)?, (1, 0));
    Ok(())
}

#[test]
fn a_missing_corrupt_or_unregistered_object_blocks_explicit_resume_and_member_load() -> Result<()> {
    let l = fixture()?;
    let frozen = compact(&l, descriptor(&l, 40)?)?;
    let id = &frozen["batchID"];
    let lease = register(&l.path, &frozen)?;
    let file = object(l._root.path(), &frozen["items"][0]["body"])?;
    let original = fs::read(&file)?;
    batch(
        &l.path,
        json!({"action":"stop","batchID":id,"expectedGeneration":1,"token":lease["token"],"reason":"interrupted"}),
    )?;
    let begin = json!({"action":"begin","batchID":id,"expectedGeneration":1});
    let assert_blocked = || -> Result<()> {
        assert!(batch(&l.path, begin.clone()).is_err());
        assert!(load_item(&l, &frozen, 1).is_err());
        let status = batch(&l.path, json!({"action":"load","batchID":id}))?;
        assert_eq!(status["batch"]["generation"], 1);
        assert_eq!(status["batch"]["phase"], "interrupted");
        assert!(register(&l.path, &frozen)?.get("token").is_none());
        Ok(())
    };
    fs::remove_file(&file)?;
    assert_blocked()?;
    let mut wrong = original.clone();
    // Preserve the JSON shape and all header identities so only content hashing detects this edit.
    let index = wrong.windows(4).position(|bytes| bytes == b"0.75").unwrap();
    wrong[index + 3] = b'6';
    fs::write(&file, &wrong)?;
    assert_blocked()?;
    fs::write(&file, &original)?;
    let ref_sha = frozen["items"][0]["body"]["sha256"].as_str().unwrap();
    l.db.execute(
        "UPDATE lc_resources SET source_asset_id='foreign' WHERE sha256=?1",
        [ref_sha],
    )?;
    assert_blocked()?;
    l.db.execute(
        "UPDATE lc_resources SET source_asset_id=NULL WHERE sha256=?1",
        [ref_sha],
    )?;
    let recovered = batch(&l.path, begin)?;
    assert_eq!(recovered["batch"]["generation"], 2);
    assert_ne!(recovered["token"], lease["token"]);
    assert_eq!(
        load_item(&l, &frozen, 1)?["body"],
        serde_json::from_slice::<Value>(&original)?
    );
    for command in [
        json!({"role":"item"}),
        json!({"role":"item","ordinal":0}),
        json!({"role":"configuration","ordinal":1}),
    ] {
        let mut wrong = command;
        wrong["action"] = "loadResource".into();
        wrong["batchID"] = id.clone();
        assert!(batch(&l.path, wrong).is_err());
    }
    Ok(())
}

#[test]
fn concurrent_stage_and_registration_share_bytes_and_backup_includes_only_committed_resources(
) -> Result<()> {
    let l = fixture()?;
    let inline = descriptor(&l, 50)?;
    let config = json!({"schema":1,"role":"configuration","configuration":inline["configuration"]});
    let (_file, request) = stage_command(&l, &config)?;
    let mut wrong = request.clone();
    wrong["sha256"] = json!("0".repeat(64));
    assert!(batch(&l.path, wrong.clone()).is_err());
    assert!(!object(l._root.path(), &wrong)?.exists());
    let concurrent = race(&l.path, &request)
        .into_iter()
        .collect::<Result<Vec<_>>>()?;
    assert!(concurrent
        .iter()
        .all(|reply| reply["resource"]["sha256"] == request["sha256"]));
    let unreachable = stage(&l, &json!({"schema":1,"role":"unreferenced"}))?;
    let frozen = compact(&l, inline)?;
    assert_eq!(registry_counts(&l)?, (0, 0));
    let replies = race(&l.path, &json!({"action":"register","manifest":frozen}))
        .into_iter()
        .collect::<Result<Vec<_>>>()?;
    assert_eq!(
        replies.iter().filter(|r| r.get("token").is_some()).count(),
        1
    );
    assert_eq!(registry_counts(&l)?, (2, 2));
    assert_eq!(
        batch(
            &l.path,
            json!({"action":"loadResource","batchID":frozen["batchID"],"role":"configuration"})
        )?["body"],
        config
    );
    let destination = tempfile::tempdir()?;
    for mode in ["catalog", "full"] {
        let package = destination.path().join(mode);
        let restored = destination.path().join(format!("{mode}-restored"));
        assert_eq!(
            backup::execute(
                &l.path,
                &json!({"op":"backup","destination":package,"mode":mode,"generation":"test"})
            )?["state"],
            "complete"
        );
        let result = backup::execute(
            &l.path,
            &json!({"op":"restore","package":package,"destination":restored}),
        )?;
        let copy = Path::new(result["libraryPath"].as_str().unwrap());
        let root = copy.parent().unwrap();
        for reference in [&frozen["configuration"], &frozen["items"][0]["body"]] {
            let bytes = fs::read(object(root, reference)?)?;
            assert_eq!(hex::encode(Sha256::digest(bytes)), reference["sha256"]);
        }
        assert!(!object(root, &unreachable)?.exists());
        assert!(!package
            .join(object_path(unreachable["sha256"].as_str().unwrap())?)
            .exists());
        let history = batch(copy, json!({"action":"load","batchID":frozen["batchID"]}))?;
        assert_eq!(history["batch"]["phase"], "historical");
        assert!(history["manifest"].is_null());
        assert!(batch(
            copy,
            json!({"action":"loadResource","batchID":frozen["batchID"],"role":"configuration"})
        )
        .is_err());
    }
    Ok(())
}
