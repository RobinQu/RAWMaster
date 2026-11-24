use super::{op, Library};
use rawmaster_library::{backup, scheduler::batch, Result};
use rusqlite::TransactionBehavior;
use serde_json::{json, Value};
use std::{
    path::Path,
    sync::{Arc, Barrier},
    time::Duration,
};

#[path = "workbench_batch_objects.rs"]
mod objects;

fn batch(db: &Path, command: Value) -> Result<Value> {
    op(db, json!({"op":"workbenchBatch","command":command}))
}

fn fixture() -> Result<Library> {
    let l = Library::v9()?;
    l.db.execute(
        "INSERT INTO metadata VALUES('deviceID','original-writer')",
        [],
    )?;
    Ok(l)
}

fn descriptor(l: &Library, n: u32) -> Result<Value> {
    let library: String =
        l.db.query_row("SELECT value FROM lc_meta WHERE key='libraryID'", [], |r| {
            r.get(0)
        })?;
    let source = json!({"assetID":"a","projectID":"p","contentSHA256":"b".repeat(64),"byteCount":123,
        "admissionFingerprint":"adm","sourceLocation":"file:///media/private/real.jpg"});
    Ok(
        json!({"schema":1,"batchID":format!("00000000-0000-4000-8000-{n:012x}"),"libraryID":library,
        "sourceContext":{"kind":"editor","title":"unsaved"},"destination":{"grantID":"host-only-grant","pathHint":"/private/export"},
        "namingTemplate":"{name}.{index}","collision":"rename","configuration":{"format":"jpeg8","jpegQuality":0.925},
        "items":[{"ordinal":1,"assetID":"a","stem":"Cafe\u{301}.v1","work":{"id":"work-a","source":source},
            "version":{"id":"parent-saved","workID":"work-a","source":source,"recipe":{"exposureEV":0.112345678901,
                "curve":[0.75,0.25,1.125]}}}]}),
    )
}

fn register(path: &Path, manifest: &Value) -> Result<Value> {
    batch(path, json!({"action":"register","manifest":manifest}))
}

// Exercise the exported ABI with the same UTF-8 request bytes a native host supplies.
fn wire_request(path: &Path, message: &[u8]) -> Result<Vec<u8>> {
    #[repr(C)]
    struct Reply {
        data: *mut u8,
        length: usize,
    }
    unsafe extern "C" {
        fn rm_library_request_v1(
            path: *const u8,
            path_len: usize,
            message: *const u8,
            message_len: usize,
            reply: *mut Reply,
        ) -> i32;
        fn rm_library_release_v1(reply: *mut Reply);
    }
    let path = path.as_os_str().as_encoded_bytes();
    let mut reply = Reply {
        data: std::ptr::null_mut(),
        length: 0,
    };
    // Both slices and the reply struct outlive the call. Copy the result before releasing its owner.
    let (status, bytes) = unsafe {
        let status = rm_library_request_v1(
            path.as_ptr(),
            path.len(),
            message.as_ptr(),
            message.len(),
            &mut reply,
        );
        if reply.data.is_null() {
            return Err("catalog returned an empty ABI buffer".into());
        }
        let bytes = std::slice::from_raw_parts(reply.data, reply.length).to_vec();
        rm_library_release_v1(&mut reply);
        (status, bytes)
    };
    if status != 0 {
        return Err(String::from_utf8_lossy(&bytes).into_owned().into());
    }
    Ok(bytes)
}

#[test]
fn raw_c_abi_freezes_native_float_bits_and_canonical_batch_uuid_spelling() -> Result<()> {
    let l = fixture()?;
    let mut m = descriptor(&l, 0xabcd)?;
    let canonical = m["batchID"].as_str().unwrap().to_owned();
    let uppercase = canonical.to_uppercase();
    m["batchID"] = uppercase.clone().into();
    m["items"][0]["version"]["recipe"]["look"] = json!({"amount":"__wire_decimal__"});
    let envelope = json!({"operation":"scheduler","request":{"op":"workbenchBatch","command":{"action":"register","manifest":m}}});
    // The literal must reach the ABI without being parsed or rounded by this fixture.
    let register =
        serde_json::to_string(&envelope)?.replace("\"__wire_decimal__\"", "51.248178375505404");
    let first: Value = serde_json::from_slice(&wire_request(&l.path, register.as_bytes())?)?;
    assert!(first["token"].is_string());
    assert_eq!(first["batch"]["batchID"], canonical);
    let same = register.replace(&uppercase, &canonical);
    let again: Value = serde_json::from_slice(&wire_request(&l.path, same.as_bytes())?)?;
    assert!(again.get("token").is_none());
    assert_eq!(
        first["batch"]["manifestSHA256"],
        again["batch"]["manifestSHA256"]
    );
    let load = serde_json::to_vec(
        &json!({"operation":"scheduler","request":{"op":"workbenchBatch",
        "command":{"action":"load","batchID":canonical}}}),
    )?;
    let output = String::from_utf8(wire_request(&l.path, &load)?)?;
    let loaded: Value = serde_json::from_str(&output)?;
    assert_eq!(loaded["manifest"]["batchID"], canonical);
    let value = loaded
        .pointer("/manifest/items/0/version/recipe/look/amount")
        .and_then(Value::as_f64)
        .unwrap();
    let expected_bits = 0x4049_9fc4_4f1b_2f60;
    assert_eq!(value.to_bits(), expected_bits);
    // Also check the bytes a non-serde client sees using Rust's independent decimal parser.
    let literal = output
        .split_once("\"amount\":")
        .unwrap()
        .1
        .split('}')
        .next()
        .unwrap();
    assert_eq!(literal.parse::<f64>()?.to_bits(), expected_bits);
    Ok(())
}

fn race(db: &Path, command: &Value) -> Vec<Result<Value>> {
    let gate = Arc::new(Barrier::new(4));
    let workers: Vec<_> = (0..4)
        .map(|_| {
            let gate = gate.clone();
            let path = db.to_owned();
            let command = command.clone();
            std::thread::spawn(move || {
                gate.wait();
                batch(&path, command)
            })
        })
        .collect();
    workers
        .into_iter()
        .map(|worker| worker.join().unwrap())
        .collect()
}

#[test]
fn concurrent_registration_is_immutable_and_only_the_inserter_gets_the_token() -> Result<()> {
    let l = fixture()?;
    let m = descriptor(&l, 1)?;
    let id = &m["batchID"];
    let replies = race(&l.path, &json!({"action":"register","manifest":m}))
        .into_iter()
        .collect::<Result<Vec<_>>>()?;
    let tokens: Vec<_> = replies.iter().filter_map(|r| r["token"].as_str()).collect();
    assert_eq!(tokens.len(), 1);
    let token = tokens[0];
    for r in &replies {
        assert_eq!(r["batch"]["generation"], 1);
    }
    let duplicate = register(&l.path, &m)?;
    assert!(duplicate.get("token").is_none());
    assert_eq!(duplicate["batch"]["phase"], "running");
    let loaded = batch(&l.path, json!({"action":"load","batchID":id}))?;
    assert_eq!(loaded["manifest"], m);
    assert!(!loaded.to_string().contains(token));
    let listed = batch(&l.path, json!({"action":"list"}))?.to_string();
    for private in [
        token,
        "/private/export",
        "host-only-grant",
        "exposureEV",
        "tokenDigest",
    ] {
        assert!(!listed.contains(private));
    }
    let stored: i64 = l.db.query_row(
        "SELECT count(*) FROM lc_meta WHERE key GLOB 'wb032.*' AND instr(value,?1)>0",
        [token],
        |r| r.get(0),
    )?;
    assert_eq!(stored, 0);
    let mut changed = m.clone();
    changed["items"][0]["stem"] = json!("Café.v1");
    assert!(register(&l.path, &changed).is_err());
    assert!(op(&l.path, json!({"op":"claim"}))?.is_null());
    Ok(())
}

#[test]
fn expired_generation_cannot_renew_or_publish_and_explicit_resume_is_exclusive() -> Result<()> {
    let mut l = fixture()?;
    let m = descriptor(&l, 2)?;
    let id = &m["batchID"];
    let first = register(&l.path, &m)?;
    let token = first["token"].as_str().unwrap();
    let begin = json!({"action":"begin","batchID":id,"expectedGeneration":1});
    let check = json!({"action":"check","batchID":id,"generation":1,"token":token});
    let renew = json!({"action":"renew","batchID":id,"generation":1,"token":token,"leaseMs":25});
    let interrupt = json!({"action":"stop","reason":"interrupted","batchID":id,"expectedGeneration":1,"token":token});
    assert!(batch(&l.path, begin.clone()).is_err());
    assert!(batch::check(&l.db, id.as_str().unwrap(), 1, token).is_err());
    let read = l.db.unchecked_transaction()?;
    let _: i64 = read.query_row("SELECT COUNT(*) FROM lc_meta", [], |r| r.get(0))?;
    assert!(batch::check(&read, id.as_str().unwrap(), 1, token).is_err());
    read.commit()?;
    let tx =
        l.db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    batch::check(&tx, id.as_str().unwrap(), 1, token)?;
    tx.commit()?;
    batch(&l.path, renew.clone())?;
    std::thread::sleep(Duration::from_millis(65));
    assert_eq!(
        batch(&l.path, json!({"action":"load","batchID":id}))?["batch"]["phase"],
        "interrupted"
    );
    for stale in [check, renew, interrupt] {
        assert!(batch(&l.path, stale).is_err());
    }
    let acquired: Vec<_> = race(&l.path, &begin)
        .into_iter()
        .filter_map(Result::ok)
        .collect();
    assert_eq!(acquired.len(), 1);
    assert_eq!(acquired[0]["batch"]["generation"], 2);
    let next = acquired[0]["token"].as_str().unwrap();
    assert_ne!(next, token);
    assert!(batch(
        &l.path,
        json!({"action":"stop","batchID":id,"expectedGeneration":1,"reason":"cancelled"})
    )
    .is_err());
    batch(
        &l.path,
        json!({"action":"check","batchID":id,"generation":2,"token":next}),
    )?;
    let cancel = json!({"action":"stop","batchID":id,"expectedGeneration":2,"reason":"cancelled"});
    assert_eq!(batch(&l.path, cancel.clone())?, batch(&l.path, cancel)?);
    assert!(batch(
        &l.path,
        json!({"action":"begin","batchID":id,"expectedGeneration":2})
    )
    .is_err());
    assert!(batch(
        &l.path,
        json!({"action":"check","batchID":id,"generation":2,"token":next})
    )
    .is_err());
    assert!(register(&l.path, &m)?.get("token").is_none());
    let stopped = descriptor(&l, 3)?;
    let sid = &stopped["batchID"];
    let granted = register(&l.path, &stopped)?;
    let interrupted = json!({"action":"stop","batchID":sid,"expectedGeneration":1,"reason":"interrupted","token":granted["token"]});
    assert_eq!(
        batch(&l.path, interrupted)?["batch"]["phase"],
        "interrupted"
    );
    batch(
        &l.path,
        json!({"action":"stop","batchID":sid,"expectedGeneration":1,"reason":"cancelled"}),
    )?;
    assert!(batch(
        &l.path,
        json!({"action":"begin","batchID":sid,"expectedGeneration":1})
    )
    .is_err());
    Ok(())
}

#[test]
fn invalid_or_partial_submissions_are_rejected_and_public_pages_preserve_batch_order() -> Result<()>
{
    let l = fixture()?;
    let m = descriptor(&l, 1)?;
    for (field, invalid) in [
        ("/items/0/ordinal", json!(2)),
        ("/items/0/stem", json!("../unsafe")),
        ("/items/0/version/workID", json!("other")),
        ("/items/0/version/source/byteCount", json!(12)),
        ("/items/0/work/source/admissionFingerprint", json!("other")),
        ("/items/0/version/recipe", json!(null)),
        ("/libraryID", json!("other")),
        ("/destination/pathHint", json!("relative")),
        ("/schema", json!(2)),
    ] {
        let mut bad = m.clone();
        *bad.pointer_mut(field).unwrap() = invalid;
        assert!(register(&l.path, &bad).is_err(), "{field}");
    }
    let mut duplicate = m.clone();
    let mut item = duplicate["items"][0].clone();
    item["ordinal"] = 2.into();
    duplicate["items"].as_array_mut().unwrap().push(item);
    assert!(register(&l.path, &duplicate).is_err());
    let mut oversized = m.clone();
    oversized["configuration"]["data"] = "x".repeat(8 * 1024 * 1024).into();
    assert!(register(&l.path, &oversized).is_err());
    assert!(batch(&l.path, json!({"action":"load","batchID":m["batchID"]}))?.is_null());
    assert!(batch(
        &l.path,
        json!({"action":"register","manifest":m,"leaseMs":1})
    )
    .is_err());
    for k in [3, 1, 2] {
        register(&l.path, &descriptor(&l, k)?)?;
    }
    let first = batch(&l.path, json!({"action":"list","limit":2}))?;
    assert_eq!(first["batches"][0]["batchID"], m["batchID"]);
    assert_eq!(first["nextAfter"], descriptor(&l, 2)?["batchID"]);
    let last = batch(
        &l.path,
        json!({"action":"list","limit":2,"after":first["nextAfter"]}),
    )?;
    assert_eq!(last["batches"].as_array().unwrap().len(), 1);
    assert!(last["nextAfter"].is_null());
    l.db.execute(
        "DELETE FROM lc_meta WHERE key=?1",
        [format!(
            "wb032.manifest.v1/{}",
            m["batchID"].as_str().unwrap()
        )],
    )?;
    assert!(register(&l.path, &m).is_err());
    assert!(batch(&l.path, json!({"action":"load","batchID":m["batchID"]})).is_err());
    assert!(batch(&l.path, json!({"action":"list"})).is_err());
    Ok(())
}

#[test]
fn restored_database_retains_only_history_and_export_tokens_do_not_cross_catalog_writers(
) -> Result<()> {
    let l = fixture()?;
    let m = descriptor(&l, 1)?;
    let id = &m["batchID"];
    let lease = register(&l.path, &m)?;
    let root = tempfile::tempdir()?;
    let package = root.path().join("package");
    let restored = root.path().join("restored");
    assert_eq!(
        backup::execute(
            &l.path,
            &json!({"op":"backup","destination":package,"mode":"catalog","generation":"original"})
        )?["state"],
        "complete"
    );
    let reply = backup::execute(
        &l.path,
        &json!({"op":"restore","package":package,"destination":restored}),
    )?;
    let copy = Path::new(reply["libraryPath"].as_str().unwrap());
    let historical = batch(copy, json!({"action":"load","batchID":id}))?;
    assert_eq!(historical["batch"]["phase"], "historical");
    assert!(historical["manifest"].is_null());
    assert!(!historical.to_string().contains("private"));
    let check = json!({"action":"check","batchID":id,"generation":1,"token":lease["token"]});
    batch(&l.path, check.clone())?;
    for invalid in [
        check,
        json!({"action":"begin","batchID":id,"expectedGeneration":1}),
        json!({"action":"stop","reason":"cancelled","batchID":id,"expectedGeneration":1}),
    ] {
        assert!(batch(copy, invalid).is_err());
    }
    assert!(register(copy, &m)?.get("token").is_none());
    Ok(())
}
