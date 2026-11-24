use rawmaster_library::{request, scheduler::Queue, transaction, Result};
use rusqlite::{params, Connection, TransactionBehavior};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    path::{Path, PathBuf},
    sync::{Arc, Barrier},
};
use tempfile::TempDir;

#[path = "scheduled_processing/workbench_batches.rs"]
mod workbench_batches;

struct Library {
    _root: TempDir,
    path: PathBuf,
    db: Connection,
}

impl Library {
    fn v8() -> Result<Self> {
        let root = tempfile::tempdir()?;
        let path = root.path().join("library.sqlite");
        let db = Connection::open(&path)?;
        db.execute_batch("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; BEGIN IMMEDIATE")?;
        db.execute_batch(include_str!("../src/authority/legacy_v7_reference.sql"))?;
        transaction(&db, &json!({"operation":"install"}))?;
        db.execute_batch("PRAGMA user_version=8; COMMIT")?;
        Ok(Self {
            _root: root,
            path,
            db,
        })
    }
    fn upgrade(&mut self) -> Result<()> {
        let tx = self
            .db
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        transaction(&tx, &json!({"operation":"upgradeScheduler"}))?;
        Ok(tx.commit()?)
    }
    fn v9() -> Result<Self> {
        let mut library = Self::v8()?;
        library.upgrade()?;
        Ok(library)
    }
}
fn op(path: &Path, body: Value) -> Result<Value> {
    request(path, &json!({"operation":"scheduler","request":body}))
}
fn submit(path: &Path, key: &str, resource: &str, safe: bool) -> Result<Value> {
    op(
        path,
        json!({"op":"submit","key":key,"lane":"editing","resource":resource,"payload":{"frozenRevision":17},
        "memoryMiB":64,"replaySafe":safe}),
    )
}

#[test]
fn v8_is_checked_before_any_mutation_and_v9_validates_the_same_registry() -> Result<()> {
    let mut l = Library::v8()?;
    let id: String =
        l.db.query_row("SELECT value FROM lc_meta WHERE key='libraryID'", [], |r| {
            r.get(0)
        })?;
    assert!(Queue::open(&l.path).is_err());
    l.db.execute_batch("CREATE TABLE lc_unrecognized(v)")?;
    assert!(l.upgrade().is_err());
    assert_eq!(
        l.db.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))?,
        8
    );
    assert_eq!(
        l.db.query_row(
            "SELECT count(*) FROM sqlite_schema WHERE name GLOB 'lc_task_*'",
            [],
            |r| r.get::<_, i64>(0)
        )?,
        0
    );
    l.db.execute_batch("DROP TABLE lc_unrecognized; CREATE VIEW foreign_view AS SELECT 1")?;
    assert!(l.upgrade().is_err());
    l.db.execute_batch("DROP VIEW foreign_view")?;
    let trigger: String = l.db.query_row(
        "SELECT sql FROM sqlite_schema WHERE name='lc_sync_asset_update'",
        [],
        |r| r.get(0),
    )?;
    let historic = trigger.replacen(" WHEN\n", " WHEN \n", 1);
    assert_ne!(historic, trigger);
    l.db.execute_batch("DROP TRIGGER lc_sync_asset_update")?;
    l.db.execute_batch(&historic)?;
    l.upgrade()?;
    assert_eq!(
        l.db.query_row(
            "SELECT sql FROM sqlite_schema WHERE name='lc_sync_asset_update'",
            [],
            |r| r.get::<_, String>(0)
        )?,
        trigger
    );
    let tx = l.db.unchecked_transaction()?;
    tx.execute_batch("DROP TRIGGER lc_sync_asset_update")?;
    tx.execute_batch(&historic)?;
    assert!(rawmaster_library::validate_catalog_objects(&tx).is_err());
    tx.rollback()?;
    l.upgrade()?;
    assert_eq!(
        l.db.query_row("SELECT value FROM lc_meta WHERE key='libraryID'", [], |r| r
            .get::<_, String>(0))?,
        id
    );
    let entries = rawmaster_library::validate_catalog_objects(&l.db)?;
    assert!(entries.iter().any(|s| s == "lc_task_ended"));
    assert!(op(&l.path,json!({"op":"submit","key":"x","lane":"library","resource":"cpu","payload":{"libraryID":"another"}})).is_err());
    l.db.execute_batch("CREATE INDEX foreign_index ON lc_task_jobs(available_at)")?;
    assert!(Queue::open(&l.path).is_err());
    l.db.execute_batch("DROP INDEX foreign_index; DROP INDEX lc_task_ready; CREATE INDEX lc_task_ready ON lc_task_jobs(job_key)")?;
    assert!(rawmaster_library::validate_catalog_objects(&l.db).is_err());
    assert!(Queue::open(&l.path).is_err());
    Ok(())
}

#[test]
fn v10_workbench_fence_rejects_old_statements_on_a_preopened_v9_connection() -> Result<()> {
    let mut library = Library::v8()?;
    library.db.execute_batch("BEGIN IMMEDIATE;")?;
    library.db.execute_batch(rawmaster_library::scheduler::SCHEMA)?;
    library.db.execute_batch("PRAGMA user_version=9; COMMIT;")?;
    rawmaster_library::validate_catalog_objects(&library.db)?;
    let old = Connection::open(&library.path)?;
    old.execute_batch("PRAGMA trusted_schema=OFF;")?;
    let mut register = old.prepare("INSERT INTO lc_meta(key,value) VALUES
        ('wb032.manifest.v1/old','{}'),('wb032.control.v1/old','{\"schema\":1}')")?;
    let mut reserve = old.prepare("INSERT INTO lc_meta(key,value) VALUES('wb032.name.v1/legacy','old')")?;
    let mut update = old.prepare("UPDATE lc_meta SET value='{\"schema\":1}' WHERE key='wb032.control.v1/current'")?;
    library.upgrade()?;
    library.db.execute("INSERT INTO lc_meta(key,value) VALUES('wb032.control.v1/current','{\"schema\":2}')", [])?;
    for statement in [&mut register, &mut reserve, &mut update] {
        let error = statement.execute([]).unwrap_err();
        assert!(error.to_string().contains("workbench writer requires control schema 2"));
    }
    assert_eq!(old.query_row("SELECT key FROM lc_meta WHERE key GLOB 'wb032.*'", [], |row| row.get::<_, String>(0))?,
        "wb032.control.v1/current");
    assert_eq!(old.query_row("SELECT json_extract(value,'$.schema') FROM lc_meta WHERE key='wb032.control.v1/current'", [],
        |row| row.get::<_,u8>(0))?, 2);
    let mut queue = Queue::open(&library.path)?;
    let capabilities = queue.request(serde_json::from_value(json!({"op":"capabilities"}))?)?;
    assert_eq!(capabilities["catalogSchema"], rawmaster_library::CATALOG_SCHEMA_VERSION);
    Ok(())
}

#[test]
fn registry_rechecks_live_objects_including_triggers_that_share_a_trusted_name() -> Result<()> {
    let l = Library::v9()?;
    let registry = rawmaster_library::schema_objects()?;
    let validate = || rawmaster_library::validate_catalog_objects(&l.db);
    l.db.execute_batch("CREATE INDEX host_metadata_value ON metadata(value)")?;
    assert_eq!(validate()?, registry);
    let ready: String = l.db.query_row(
        "SELECT sql FROM sqlite_schema WHERE type='index' AND name='lc_task_ready'",
        [],
        |row| row.get(0),
    )?;
    // SQLite permits a trigger and an index to share a name. Reinstall the expected index last
    // so a validator that collapses rows by name would silently discard the untrusted trigger.
    let duplicate = format!(
        "DROP INDEX lc_task_ready;
        CREATE TRIGGER lc_task_ready AFTER INSERT ON metadata BEGIN SELECT 1; END; {ready}"
    );
    for change in [
        duplicate.as_str(),
        "CREATE TRIGGER unexpected AFTER INSERT ON metadata BEGIN SELECT 1; END",
        "DROP TRIGGER lc_task_ended; CREATE INDEX lc_task_ended ON lc_task_jobs(state)",
        "DROP INDEX lc_task_ready; CREATE INDEX lc_task_ready ON lc_resources(kind)",
        "ALTER TABLE lc_resources ADD COLUMN extra TEXT",
        "DROP INDEX lc_task_ready",
    ] {
        let tx = l.db.unchecked_transaction()?;
        tx.execute_batch(change)?;
        assert!(validate().is_err(), "schema change was accepted: {change}");
        tx.rollback()?;
        assert_eq!(validate()?, registry);
    }
    let missing = l._root.path().join("missing.sqlite");
    assert!(Queue::open(&missing).is_err());
    assert!(!missing.exists());
    let empty = l._root.path().join("empty.sqlite");
    std::fs::File::create(&empty)?;
    assert!(Queue::open(&empty).is_err());
    assert_eq!(std::fs::metadata(&empty)?.len(), 0);
    Ok(())
}

#[test]
fn simultaneous_claims_respect_cpu_gpu_io_and_memory_and_fence_late_workers() -> Result<()> {
    let l = Library::v9()?;
    op(
        &l.path,
        json!({"op":"configure","cpu":2,"gpu":1,"io":1,"memoryMiB":256}),
    )?;
    for (i, r) in ["gpu", "gpu", "cpu", "io", "cpu", "cpu", "io", "gpu"]
        .iter()
        .enumerate()
    {
        submit(&l.path, &format!("w{i}"), r, true)?;
    }
    let gate = Arc::new(Barrier::new(8));
    let workers: Vec<_> = (0..8)
        .map(|_| {
            let (p, g) = (l.path.clone(), gate.clone());
            std::thread::spawn(move || -> Result<Value> {
                let mut q = Queue::open(&p)?;
                g.wait();
                q.request(serde_json::from_value(json!({"op":"claim"}))?)
            })
        })
        .collect();
    let mut claims = Vec::new();
    for w in workers {
        let v = w.join().unwrap()?;
        if !v.is_null() {
            claims.push(v)
        }
    }
    assert_eq!(claims.len(), 4);
    let mut resources: Vec<_> = claims
        .iter()
        .map(|v| v["resource"].as_str().unwrap())
        .collect();
    resources.sort();
    assert_eq!(resources, ["cpu", "cpu", "gpu", "io"]);
    let mut ids: Vec<_> = claims.iter().map(|v| v["key"].as_str().unwrap()).collect();
    ids.sort();
    ids.dedup();
    assert_eq!(ids.len(), 4);
    let lease = &claims[0];
    let key = &lease["key"];
    let tok = &lease["token"];
    assert!(op(&l.path, json!({"op":"claim"}))?.is_null());
    op(&l.path, json!({"op":"cancel","key":key,"token":tok}))?;
    assert!(op(&l.path, json!({"op":"claim"}))?.is_null());
    assert!(op(
        &l.path,
        json!({"op":"complete","key":key,"token":tok,"result":"late"})
    )
    .is_err());
    assert_eq!(
        op(&l.path, json!({"op":"ackCancel","key":key,"token":tok}))?["state"],
        "cancelled"
    );
    assert!(!op(&l.path, json!({"op":"claim"}))?.is_null());
    Ok(())
}

#[test]
fn artifact_stage_failure_backoff_expired_fence_unknown_remote_and_ack_replay() -> Result<()> {
    let l = Library::v9()?;
    let p = &l.path;
    submit(p, "local", "gpu", true)?;
    let first = op(p, json!({"op":"claim","key":"local"}))?;
    let token = &first["token"];
    let jpeg = l._root.path().join("worker.jpg");
    let real=include_bytes!("../../../Tests/RAWMasterImagingTests/Fixtures/SequenceGrouping/v1/cases/burst14-context38/files/asset0000.jpg");
    let hash = hex::encode(Sha256::digest(real));
    let complete =
        |t: &Value| json!({"op":"complete","key":"local","token":t,"result":hash,"file":jpeg});
    assert!(op(p, complete(token)).is_err());
    let failed = op(
        p,
        json!({"op":"fail","key":"local","token":token,"class":"transient","error":"missing staged file"}),
    )?;
    assert!(failed["availableAtMs"].as_i64().unwrap() > 0);
    l.db.execute(
        "UPDATE lc_task_jobs SET available_at=0 WHERE job_key='local'",
        [],
    )?;
    let second = op(p, json!({"op":"claim","key":"local"}))?;
    l.db.execute(
        "UPDATE lc_task_jobs SET lease_until=0 WHERE job_key='local'",
        [],
    )?;
    assert!(op(
        p,
        json!({"op":"heartbeat","key":"local","token":second["token"]})
    )
    .is_err());
    assert!(op(
        p,
        json!({"op":"cancel","key":"local","token":second["token"]})
    )
    .is_err());
    assert!(op(p, complete(&second["token"])).is_err());
    let third = op(p, json!({"op":"claim","key":"local"}))?;
    assert_eq!(third["attempt"], 3);
    std::fs::write(&jpeg, real)?;
    let reference = op(p, complete(&third["token"]))?;
    std::fs::remove_file(jpeg.as_path())?;
    assert_eq!(op(p, complete(&third["token"]))?, reference);
    assert_eq!(
        l.db.query_row(
            "SELECT count(*) FROM lc_resources WHERE kind='recipeResource' AND sha256=?",
            [&hash],
            |r| r.get::<_, i64>(0)
        )?,
        1
    );
    let history = op(p, json!({"op":"attempts","key":"local"}))?;
    assert_eq!(history.as_array().unwrap().len(), 3);
    assert_eq!(history[2]["state"], "done");
    assert_eq!(history[2]["error"], Value::Null);
    submit(p, "remote", "io", false)?;
    let remote = op(p, json!({"op":"claim","key":"remote"}))?;
    l.db.execute(
        "UPDATE lc_task_jobs SET lease_until=0 WHERE job_key='remote'",
        [],
    )?;
    assert!(op(
        p,
        json!({"op":"check","key":"remote","token":remote["token"]})
    )
    .is_err());
    let recover = json!({"op":"reconcile","key":"remote","result":"verified-external-receipt","safeToResubmit":false});
    assert_eq!(op(p, recover.clone())?["state"], "done");
    assert_eq!(op(p, recover)?["result"], "verified-external-receipt");
    assert!(op(p, json!({"op":"verifyExternalDelivery","key":"remote"}))?.is_null());
    Ok(())
}

#[test]
fn publication_of_domain_row_rolls_back_when_lease_expires_and_retry_has_one_receipt() -> Result<()>
{
    let mut l = Library::v9()?;
    submit(&l.path, "mask", "gpu", true)?;
    let lease = op(&l.path, json!({"op":"claim","key":"mask"}))?;
    let descriptor = json!({"key":"mask","token":lease["token"],"receipt":"mask:7"});
    let first = json!({"operation":"checkTaskLease","request":descriptor});
    let last = json!({"operation":"finishTaskReceipt","request":descriptor});
    {
        let tx =
            l.db.transaction_with_behavior(TransactionBehavior::Immediate)?;
        transaction(&tx, &first)?;
        tx.execute("INSERT INTO metadata VALUES('mask:7','frozen')", [])?;
        tx.execute(
            "UPDATE lc_task_jobs SET lease_until=0 WHERE job_key='mask'",
            [],
        )?;
        assert!(transaction(&tx, &last).is_err());
        tx.rollback()?;
    }
    assert_eq!(
        l.db.query_row(
            "SELECT count(*) FROM metadata WHERE key='mask:7'",
            [],
            |r| r.get::<_, i64>(0)
        )?,
        0
    );
    let tx =
        l.db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    transaction(&tx, &first)?;
    tx.execute(
        "INSERT INTO metadata VALUES('mask:7',?1)",
        params!["frozen"],
    )?;
    transaction(&tx, &last)?;
    tx.commit()?;
    assert_eq!(
        op(
            &l.path,
            json!({"op":"complete","key":"mask","token":lease["token"],"result":"mask:7"})
        )?["state"],
        "done"
    );
    Ok(())
}

#[test]
fn external_stage_survives_reopen_and_requires_verified_final_bytes_before_any_ack() -> Result<()> {
    let mut l = Library::v9()?;
    let root = l.path.parent().unwrap();
    let volume = root.join("output-volume");
    std::fs::create_dir(&volume)?;
    let stage_dir = volume.join(".rawmaster-export-28");
    std::fs::create_dir(&stage_dir)?;
    let stage = stage_dir.join("pixels.jpg");
    let output = volume.join("frame.jpg");
    let real = include_bytes!("../../../Tests/RAWMasterImagingTests/Fixtures/SequenceGrouping/v1/cases/burst14-context38/files/asset0000.jpg");
    std::fs::write(&stage, real)?;
    let key = "export:batch:28";
    op(
        &l.path,
        json!({"op":"submit","key":key,"lane":"export","resource":"io","payload":{"asset":"asset0000","destination":output},"replaySafe":true}),
    )?;
    let first = op(&l.path, json!({"op":"claim","key":key}))?;
    let prep = json!({"op":"prepareExternal","key":key,"token":first["token"],"stage":stage,"destination":output});
    let mut wrong_path = prep.clone();
    wrong_path["destination"] = json!(volume.join("different.jpg"));
    assert!(op(&l.path, wrong_path).is_err());
    let record = op(&l.path, prep.clone())?;
    assert_eq!(record["byteCount"], real.len());
    assert_eq!(record["sha256"], hex::encode(Sha256::digest(real)));
    assert_eq!(op(&l.path, prep.clone())?, record);
    let all =
        json!({"op":"preparedExternalTasks","lane":"export","keyPrefix":"export:batch:","limit":1});
    let list = op(&l.path, all.clone())?;
    assert_eq!(list[0]["publication"], record);
    assert_eq!(list[0]["payload"]["asset"], "asset0000");
    let mut page2 = all.clone();
    page2["after"] = key.into();
    assert_eq!(op(&l.path, page2)?, json!([]));
    assert_eq!(
        op(
            &l.path,
            json!({"op":"verifyPrepared","key":key,"destination":false})
        )?,
        true
    );
    let verify = json!({"op":"verifyPrepared","key":key,"destination":true});
    assert_eq!(op(&l.path, verify.clone())?, false);
    let ticket = json!({"op":"verifyExternalDelivery","key":key});
    assert!(op(&l.path, ticket.clone())?.is_null());
    assert!(op(
        &l.path,
        json!({"op":"verifyExternalDelivery","key":"missing-key"})
    )?
    .is_null());
    let finish = json!({"op":"complete","key":key,"token":first["token"],"result":"published:28"});
    assert!(op(&l.path, finish.clone()).is_err());
    let ack =
        json!({"operation":"completeVerifiedTask","request":{"key":key,"receipt":"published:28"}});
    {
        let tx =
            l.db.transaction_with_behavior(TransactionBehavior::Immediate)?;
        assert!(transaction(&tx, &ack).is_err());
        tx.rollback()?;
    }
    let state = op(
        &l.path,
        json!({"op":"fail","key":key,"token":first["token"],"class":"transient","error":"lost publication callback"}),
    )?;
    assert_eq!(state["state"], "reconcile");
    assert!(op(&l.path, prep).is_err());
    assert!(op(&l.path, json!({"op":"claim","key":key}))?.is_null());
    assert_eq!(
        op(&l.path, json!({"op":"preparedExternal","key":key}))?,
        record
    );
    let mut wrong = real.to_vec();
    wrong[50] ^= 1;
    std::fs::hard_link(&stage, &output)?;
    std::fs::write(&output, &wrong)?;
    // Even the correct inode must still have exactly the prepared bytes.
    assert!(op(&l.path, verify.clone()).is_err());
    assert_eq!(std::fs::read(&output)?, wrong);
    std::fs::write(&stage, real)?;
    std::fs::remove_file(&output)?;
    #[cfg(unix)]
    {
        std::os::unix::fs::symlink(&stage, &output)?;
        assert!(op(&l.path, verify.clone()).is_err());
        std::fs::remove_file(&output)?;
    }
    // Model a successful no-replace publication whose worker stopped before its queue ACK.
    std::fs::hard_link(&stage, &output)?;
    std::fs::remove_file(&stage)?;
    // Temporarily remove the entire output tree while the catalog remains open. Reattachment
    // with the same identity is recoverable. Real workstation volumes are never unmounted here.
    let offline = root.join("volume-offline");
    std::fs::rename(&volume, &offline)?;
    assert!(op(&l.path, ticket.clone())?.is_null());
    std::fs::rename(&offline, &volume)?;
    // Simulate a different OS device assignment.
    let identity: String = l.db.query_row(
        "SELECT prepared_file_identity FROM lc_task_jobs WHERE job_key=?1",
        [key],
        |r| r.get(0),
    )?;
    l.db.execute("UPDATE lc_task_jobs SET prepared_file_identity='different-device:same-inode' WHERE job_key=?1",[key])?;
    assert!(op(&l.path, ticket.clone()).is_err());
    assert_eq!(
        op(&l.path, json!({"op":"status","key":key}))?["state"],
        "reconcile"
    );
    l.db.execute(
        "UPDATE lc_task_jobs SET prepared_file_identity=?2 WHERE job_key=?1",
        params![key, identity],
    )?;
    assert_eq!(op(&l.path, verify)?, true);
    assert_eq!(op(&l.path, ticket)?, record);
    let tx =
        l.db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    transaction(&tx, &ack)?;
    transaction(&tx, &ack)?;
    let conflict = json!({"operation":"completeVerifiedTask","request":{"key":key,"receipt":"different intent"}});
    assert!(transaction(&tx, &conflict).is_err());
    tx.commit()?;
    assert!(op(&l.path, finish).is_err());
    assert_eq!(op(&l.path, all)?, json!([]));
    assert_eq!(std::fs::read(&output)?, real);
    // An already completed receipt is historical. A restored byte-for-byte copy at that path still verifies.
    let replacement = volume.join("restored-copy.jpg");
    std::fs::write(&replacement, real)?;
    std::fs::rename(replacement, &output)?;
    assert_eq!(
        op(&l.path, json!({"op":"verifyExternalDelivery","key":key}))?,
        record
    );
    Ok(())
}

#[test]
fn prepared_safe_jobs_require_reconciliation_on_expiry_or_acknowledged_cancellation() -> Result<()>
{
    let l = Library::v9()?;
    let base = l.path.parent().unwrap();
    let stage = base.join("encoded.jpg");
    std::fs::write(&stage, b"closed-stage")?;
    for (key, cancel) in [("expire", false), ("cancel", true)] {
        submit(&l.path, key, "io", true)?;
        let running = op(&l.path, json!({"op":"claim","key":key}))?;
        let token = &running["token"];
        let dest = base.join(format!("{key}.jpg"));
        op(
            &l.path,
            json!({"op":"prepareExternal","key":key,"token":token,"stage":stage,"destination":dest}),
        )?;
        if cancel {
            op(&l.path, json!({"op":"cancel","key":key,"token":token}))?;
            assert_eq!(
                op(&l.path, json!({"op":"ackCancel","key":key,"token":token}))?["state"],
                "reconcile"
            );
        } else {
            l.db.execute(
                "UPDATE lc_task_jobs SET lease_until=0 WHERE job_key=?",
                [key],
            )?;
        }
        assert!(op(&l.path, json!({"op":"claim","key":key}))?.is_null());
        assert_eq!(
            op(&l.path, json!({"op":"status","key":key}))?["state"],
            "reconcile"
        );
        assert!(op(
            &l.path,
            json!({"op":"reconcile","key":key,"result":"bad","safeToResubmit":false})
        )
        .is_err());
        assert!(!dest.exists());
    }
    Ok(())
}

#[test]
fn targeted_workers_rotate_eligible_lanes_without_blocking_on_abandoned_intent() -> Result<()> {
    let l = Library::v9()?;
    op(
        &l.path,
        json!({"op":"configure","cpu":1,"gpu":0,"io":1,"memoryMiB":128}),
    )?;
    assert_eq!(
        submit(&l.path, "uncapable", "gpu", true)?["fitsConfiguredBudget"],
        false
    );
    let submit_lane = |key: &str, lane: &str| {
        op(
            &l.path,
            json!({"op":"submit","key":key,"lane":lane,"resource":"cpu","payload":{},"replaySafe":true}),
        )
    };
    let claim = |key: &str| op(&l.path, json!({"op":"claim","key":key,"leaseMs":60000}));
    let complete = |key: &str, lease: &Value| {
        op(
            &l.path,
            json!({"op":"complete","key":key,"token":lease["token"],"result":key}),
        )
    };
    submit_lane("occupied", "editing")?;
    let current = claim("occupied")?;
    submit_lane("abandoned", "export")?; // No host owns this closure right now.
    for (key, lane) in [
        ("lib", "library"),
        ("preview", "editing"),
        ("out", "export"),
    ] {
        submit_lane(key, lane)?;
        assert!(claim(key)?.is_null());
    }
    complete("occupied", &current)?;
    for (preferred, late) in [("out", "lib"), ("preview", "lib")] {
        assert!(claim(late)?.is_null());
        let leased = claim(preferred)?;
        assert_eq!(leased["key"], preferred);
        complete(preferred, &leased)?;
    }
    assert_eq!(claim("lib")?["key"], "lib");
    Ok(())
}

#[test]
fn confirmed_no_replace_collision_never_adopts_another_jobs_identical_bytes() -> Result<()> {
    let l = Library::v9()?;
    let base = l.path.parent().unwrap();
    let stage = base.join("pixels.jpg");
    let target = base.join("final.jpg");
    std::fs::write(&stage, b"same encoded bytes")?;
    submit(&l.path, "racing-delivery", "io", true)?;
    let running = op(&l.path, json!({"op":"claim","key":"racing-delivery"}))?;
    let token = &running["token"];
    let prepare = json!({"op":"prepareExternal","key":"racing-delivery","stage":stage,"destination":target,"token":token});
    std::fs::write(&target, b"pre-existing file")?;
    assert_eq!(op(&l.path, prepare.clone())?["status"], "destinationExists");
    assert!(op(
        &l.path,
        json!({"op":"preparedExternal","key":"racing-delivery"})
    )?
    .is_null());
    std::fs::remove_file(&target)?;
    op(&l.path, prepare)?;
    // A competitor wins after preparation, while a reconciliation scan races the EEXIST callback.
    std::fs::write(&target, b"same encoded bytes")?;
    assert!(op(
        &l.path,
        json!({"op":"verifyExternalDelivery","key":"racing-delivery"})
    )
    .is_err());
    assert_eq!(
        std::fs::hard_link(&stage, &target).unwrap_err().kind(),
        std::io::ErrorKind::AlreadyExists
    );
    let result = op(
        &l.path,
        json!({"op":"fail","key":"racing-delivery","token":token,"class":"destinationOccupied","error":"no-replace collision"}),
    )?;
    assert_eq!(result["state"], "failed");
    assert!(op(
        &l.path,
        json!({"op":"verifyPrepared","key":"racing-delivery","destination":true})
    )
    .is_err());
    assert_eq!(
        op(
            &l.path,
            json!({"op":"preparedExternalTasks","lane":"editing","keyPrefix":"racing-","limit":4})
        )?,
        json!([])
    );
    Ok(())
}

#[test]
fn combined_submit_claim_is_atomic_idempotent_and_never_discloses_another_workers_token(
) -> Result<()> {
    let l = Library::v9()?;
    let configure = json!({"op":"configure","cpu":1,"gpu":1,"io":1,"memoryMiB":64});
    op(&l.path, configure)?;
    let body = json!({"op":"submit","key":"combined","lane":"export","resource":"cpu","memoryMiB":64,
                    "payload":{"frozenVersion":"v32"},"replaySafe":true,"claimLeaseMs":90_000});
    let mut invalid = body.clone();
    invalid["key"] = "bad-ttl".into();
    invalid["claimLeaseMs"] = 1.into();
    assert!(op(&l.path, invalid).is_err());
    assert_eq!(
        l.db.query_row("SELECT count(*) FROM lc_task_jobs", [], |r| r
            .get::<_, i64>(0))?,
        0
    );
    assert!(op(&l.path, json!({"op":"claim","includeStatus":true})).is_err());
    let start = Arc::new(Barrier::new(8));
    let workers: Vec<_> = (0..8)
        .map(|_| {
            let (path, b, g) = (l.path.clone(), body.clone(), start.clone());
            std::thread::spawn(move || {
                g.wait();
                op(&path, b)
            })
        })
        .collect();
    let mut grants = Vec::new();
    for worker in workers {
        let row = worker.join().unwrap()?;
        assert_eq!(row["state"], "running");
        assert_eq!(row["attempt"], 1);
        if row["token"].is_string() {
            grants.push(row["token"].clone());
        }
    }
    assert_eq!(grants.len(), 1);
    let mut conflict = body.clone();
    conflict["payload"]["frozenVersion"] = "different".into();
    assert!(op(&l.path, conflict).is_err());
    let mut second = body.clone();
    second["key"] = "second".into();
    let waiting = op(&l.path, second.clone())?;
    let proof = waiting["submissionToken"].as_str().unwrap();
    assert_eq!(waiting["inserted"], true);
    let duplicate = op(&l.path, second)?;
    assert_eq!(duplicate["inserted"], false);
    assert!(duplicate.get("submissionToken").is_none());
    assert_eq!(waiting["state"], "queued");
    assert!(waiting.get("token").is_none());
    let poll = json!({"op":"claim","key":"second","includeStatus":true});
    let from_poll = op(&l.path, poll.clone())?;
    assert_eq!(from_poll["state"], "queued");
    assert!(from_poll.get("submissionToken").is_none());
    let wrong = json!({"op":"cancelIfQueued","key":"second","submissionToken":"not-the-owner"});
    assert_eq!(op(&l.path, wrong)?["state"], "queued");
    let mut withdrawn = body.clone();
    withdrawn["key"] = "withdrawn".into();
    let own = op(&l.path, withdrawn)?;
    let cancel =
        json!({"op":"cancelIfQueued","key":"withdrawn","submissionToken":own["submissionToken"]});
    assert_eq!(op(&l.path, cancel.clone())?["state"], "cancelled");
    assert_eq!(op(&l.path, cancel)?["state"], "cancelled");
    op(
        &l.path,
        json!({"op":"complete","key":"combined","token":grants[0],"result":"known-receipt"}),
    )?;
    let done = op(&l.path, body)?;
    assert_eq!(done["result"], "known-receipt");
    assert!(done.get("token").is_none());
    let active = op(&l.path, poll)?;
    assert!(active["token"].is_string());
    assert_eq!(
        op(
            &l.path,
            json!({"op":"cancelIfQueued","key":"second","submissionToken":proof})
        )?["state"],
        "running"
    );
    let retry = op(
        &l.path,
        json!({"op":"fail","key":"second","token":active["token"],"class":"transient","error":"retry","ownRetry":true}),
    )?;
    assert!(retry["submissionToken"].is_string());
    assert_eq!(
        op(
            &l.path,
            json!({"op":"cancelIfQueued","key":"second","submissionToken":proof})
        )?["state"],
        "queued"
    );
    assert_eq!(
        op(
            &l.path,
            json!({"op":"cancelIfQueued","key":"second","submissionToken":retry["submissionToken"],"attempt":1})
        )?["state"],
        "cancelled"
    );
    assert!(op(&l.path, json!({"op":"claim"}))?.is_null());
    Ok(())
}

#[test]
fn finish_external_verifies_and_commits_once_on_the_active_lease() -> Result<()> {
    let l = Library::v9()?;
    let root = l.path.parent().unwrap();
    let digest = hex::encode(Sha256::digest(b"encoded artifact"));
    for (key, expire) in [("good", false), ("expired", true)] {
        let lease = op(
            &l.path,
            json!({"op":"submit","key":key,"lane":"export","resource":"io","payload":{},"replaySafe":true,"claimLeaseMs":90000}),
        )?;
        let stage = root.join(format!("{key}.stage"));
        let dest = root.join(format!("{key}.jpg"));
        std::fs::write(&stage, b"encoded artifact")?;
        let prepared = op(
            &l.path,
            json!({"op":"prepareExternal","key":key,"token":lease["token"],"stage":stage,"destination":dest}),
        )?;
        let acknowledge = json!({"op":"finishExternalDelivery","key":key,"token":lease["token"]});
        assert!(op(&l.path, acknowledge.clone()).is_err());
        std::fs::hard_link(&stage, &dest)?;
        if expire {
            l.db.execute(
                "UPDATE lc_task_jobs SET lease_until=0 WHERE job_key=?1",
                [key],
            )?;
            assert!(op(&l.path, acknowledge).is_err());
            let verified: bool = l.db.query_row(
                "SELECT final_verified FROM lc_task_jobs WHERE job_key=?1",
                [key],
                |r| r.get(0),
            )?;
            assert!(!verified);
            assert_eq!(
                op(
                    &l.path,
                    json!({"op":"claim","key":key,"includeStatus":true})
                )?["state"],
                "reconcile"
            );
        } else {
            assert!(op(
                &l.path,
                json!({"op":"finishExternalDelivery","key":key,"token":"other"})
            )
            .is_err());
            assert_eq!(op(&l.path, acknowledge.clone())?, prepared);
            let state = op(&l.path, json!({"op":"status","key":key}))?;
            assert_eq!(state["state"], "done");
            assert_eq!(state["result"], digest);
            std::fs::remove_file(stage)?;
            std::fs::remove_file(dest)?;
            assert_eq!(op(&l.path, acknowledge)?, prepared); // lost acknowledgement replay
            assert!(op(&l.path, json!({"op":"verifyExternalDelivery","key":key}))?.is_null());
        }
    }
    Ok(())
}
