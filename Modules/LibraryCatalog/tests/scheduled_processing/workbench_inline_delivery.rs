use super::*;

#[test]
fn bound_inline_uses_frozen_format_and_exact_abi_recipe_bits_through_actual_delivery() -> Result<()>
{
    let l = fixture()?;
    let directory = l._root.path().join("inline");
    fs::create_dir(&directory)?;
    for (i, (format, extension)) in [("jpeg8", "jpg"), ("tiff16", "tiff"), ("png16", "png")]
        .into_iter()
        .enumerate()
    {
        let mut manifest = descriptor(&l, 0xf0 + i as u32)?;
        manifest["destination"]["pathHint"] = json!(directory);
        manifest["configuration"]["format"] = format.into();
        manifest["items"][0]["version"]["recipe"]["amount"] = "wire-float".into();
        let id = manifest["batchID"].clone();
        let raw = serde_json::to_string(
            &json!({"operation":"scheduler","request":{"op":"workbenchBatch","command":{
            "action":"register","directory":directory,"manifest":manifest}}}),
        )?
        .replace("\"wire-float\"", "51.248178375505404");
        let parent: Value = serde_json::from_slice(&wire_request(&l.path, raw.as_bytes())?)?;
        let duplicate: Value = serde_json::from_slice(&wire_request(&l.path, raw.as_bytes())?)?;
        assert!(duplicate.get("token").is_none());
        let load = serde_json::to_vec(
            &json!({"operation":"scheduler","request":{"op":"workbenchBatch","command":{"action":"load","batchID":id}}}),
        )?;
        let loaded: Value = serde_json::from_slice(&wire_request(&l.path, &load)?)?;
        assert_eq!(
            loaded
                .pointer("/manifest/items/0/version/recipe/amount")
                .and_then(Value::as_f64)
                .unwrap()
                .to_bits(),
            0x4049_9fc4_4f1b_2f60
        );
        assert_eq!(
            loaded["manifest"]["configuration"],
            manifest["configuration"]
        );
        assert!(batch(
            &l.path,
            json!({"action":"loadResource","batchID":id,"role":"item","ordinal":1})
        )
        .is_err());
        let mut claim = json!({"action":"claimItem","batchID":id,"ordinal":1,"generation":1,"token":parent["token"]});
        let mut request = claim.clone();
        request["itemToken"] = batch(&l.path, claim.clone())?["itemToken"].clone();
        request["directory"] = json!(directory);
        let private = format!(".rawmaster-export-{}", uuid::Uuid::new_v4());
        fs::create_dir(directory.join(&private))?;
        let file = format!("{private}/pixels.{extension}");
        fs::write(directory.join(&file), DATA)?;
        let mut prepare = request.clone();
        prepare["action"] = "prepareItem".into();
        prepare["stage"] = file.into();
        prepare["suffix"] = 1.into();
        let name = format!("Cafe\u{301}.v1.{extension}");
        assert_eq!(batch(&l.path, prepare)?["item"]["filename"], name);
        batch(
            &l.path,
            json!({"action":"stop","batchID":id,"expectedGeneration":1,"token":parent["token"],"reason":"interrupted"}),
        )?;
        let resumed = batch(
            &l.path,
            json!({"action":"begin","batchID":id,"expectedGeneration":1}),
        )?;
        claim["token"] = resumed["token"].clone();
        claim["generation"] = 2.into();
        request["token"] = resumed["token"].clone();
        request["generation"] = 2.into();
        request["itemToken"] = batch(&l.path, claim)?["itemToken"].clone();
        request["action"] = "publishItem".into();
        assert_eq!(batch(&l.path, request)?["status"], "published");
        assert_eq!(
            batch(
                &l.path,
                json!({"action":"acknowledgeItem","batchID":id,"ordinal":1,"directory":directory})
            )?["status"],
            "delivered"
        );
        assert_eq!(fs::read(directory.join(name))?, DATA);
    }
    assert_eq!(
        l.db.query_row("SELECT count(*) FROM lc_resources", [], |r| r
            .get::<_, i64>(0))?,
        0
    );
    Ok(())
}

#[test]
fn bound_inline_stops_at_one_mib_and_never_backfills_a_legacy_directory() -> Result<()> {
    let l = fixture()?;
    let directory = l._root.path().join("output");
    fs::create_dir(&directory)?;
    let mut exact = descriptor(&l, 0xf3)?;
    exact["destination"]["pathHint"] = json!(directory);
    exact["configuration"]["padding"] = "".into();
    let limit = 1024 * 1024;
    exact["configuration"]["padding"] =
        "x".repeat(limit - serde_json::to_vec(&exact)?.len()).into();
    assert_eq!(serde_json::to_vec(&exact)?.len(), limit);
    let bound = |m: &Value| {
        batch(
            &l.path,
            json!({"action":"register","manifest":m,"directory":directory}),
        )
    };
    bound(&exact)?;
    let bytes: i64 = l.db.query_row(
        "SELECT length(CAST(value AS BLOB)) FROM lc_meta WHERE key=?1",
        [format!(
            "wb032.manifest.v1/{}",
            exact["batchID"].as_str().unwrap()
        )],
        |r| r.get(0),
    )?;
    assert_eq!(bytes, limit as i64);
    let mut over = exact.clone();
    over["batchID"] = "00000000-0000-4000-8000-0000000000f4".into();
    let mut pad = over["configuration"]["padding"]
        .as_str()
        .unwrap()
        .to_owned();
    pad.push('x');
    over["configuration"]["padding"] = pad.into();
    assert_eq!(serde_json::to_vec(&over)?.len(), limit + 1);
    assert!(bound(&over).unwrap_err().to_string().contains("1 MiB"));
    assert!(batch(&l.path, json!({"action":"load","batchID":over["batchID"]}))?.is_null());
    register(&l.path, &over)?;
    assert_eq!(
        batch(&l.path, json!({"action":"items","batchID":over["batchID"]}))?["available"],
        false
    );
    let mut legacy = descriptor(&l, 0xf5)?;
    legacy["destination"]["pathHint"] = json!(directory);
    register(&l.path, &legacy)?;
    assert!(bound(&legacy).is_err());
    assert!(batch(
        &l.path,
        json!({"action":"checkDirectory","batchID":legacy["batchID"],"directory":directory})
    )
    .is_err());
    let mut invalid = descriptor(&l, 0xf6)?;
    invalid["destination"]["pathHint"] = json!(directory);
    for bad in [json!("jpeg"), json!("../../bad"), Value::Null] {
        invalid["configuration"]["format"] = bad;
        assert!(bound(&invalid).is_err());
        assert!(batch(
            &l.path,
            json!({"action":"load","batchID":invalid["batchID"]})
        )?
        .is_null());
    }
    Ok(())
}
