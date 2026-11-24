use super::*;
use rawmaster_library::scheduler::Queue;
use std::{
    os::unix::{fs::symlink, process::ExitStatusExt},
    process::{Command, Stdio},
};

const DATA: &[u8] = b"frozen rendered image bytes";
#[path = "workbench_inline_delivery.rs"]
mod inline;
struct Run {
    l: Library,
    target: PathBuf,
    manifest: Value,
    parent: Value,
}
impl Run {
    fn new(policy: &str, count: usize) -> Result<Self> {
        Self::with_names(policy, count, false)
    }
    fn with_names(policy: &str, count: usize, duplicate: bool) -> Result<Self> {
        let l = fixture()?;
        let target = l._root.path().join("output");
        fs::create_dir(&target)?;
        let mut m = descriptor(&l, 0xe1)?;
        m["destination"]["pathHint"] = json!(target);
        m["collision"] = json!(policy);
        if count == 2 {
            let mut second = second_photo(&m["items"][0]);
            if duplicate {
                second["stem"] = json!("Café.v1");
            }
            m["items"].as_array_mut().unwrap().push(second);
        }
        let manifest = compact(&l, m)?;
        let parent = batch(
            &l.path,
            json!({"action":"register","manifest":manifest,"directory":target}),
        )?;
        Ok(Self {
            l,
            target,
            manifest,
            parent,
        })
    }
    fn cmd(&self, action: &str, extra: Value) -> Value {
        let mut command = extra;
        command["action"] = action.into();
        command["batchID"] = self.manifest["batchID"].clone();
        command
    }
    fn ask(&self, action: &str, extra: Value) -> Result<Value> {
        batch(&self.l.path, self.cmd(action, extra))
    }
    fn claim(&self, n: usize, ms: u32) -> Result<Value> {
        let mut credentials = json!({"ordinal":n,"generation":self.parent["batch"]["generation"],"token":self.parent["token"]});
        let mut request = credentials.clone();
        request["leaseMs"] = ms.into();
        let reply = self.ask("claimItem", request)?;
        credentials["itemToken"] = reply
            .get("itemToken")
            .ok_or("missing unique item token")?
            .clone();
        Ok(credentials)
    }
    fn stage(&self) -> Result<String> {
        let folder = format!(".rawmaster-export-{}", uuid::Uuid::new_v4());
        fs::create_dir(self.target.join(&folder))?;
        let relative = format!("{folder}/pixels.jpg");
        fs::write(self.target.join(&relative), DATA)?;
        Ok(relative)
    }
    fn prepare(&self, owner: &Value, stage: &str, suffix: u32) -> Value {
        let mut args = owner.clone();
        args["stage"] = stage.into();
        args["directory"] = json!(self.target);
        args["suffix"] = suffix.into();
        self.cmd("prepareItem", args)
    }
    fn publish(&self, owner: &Value) -> Value {
        let mut args = owner.clone();
        args["directory"] = json!(self.target);
        self.cmd("publishItem", args)
    }
    fn ack(&self, n: usize) -> Value {
        self.cmd(
            "acknowledgeItem",
            json!({"ordinal":n,"directory":self.target}),
        )
    }
    fn stop(&self, cancel: bool) -> Result<Value> {
        let mut args = json!({"expectedGeneration":self.parent["batch"]["generation"],"reason":if cancel{"cancelled"}else{"interrupted"}});
        if !cancel {
            args["token"] = self.parent["token"].clone();
        }
        self.ask("stop", args)
    }
    fn resume(&mut self) -> Result<()> {
        self.parent = self.ask(
            "begin",
            json!({"expectedGeneration":self.parent["batch"]["generation"]}),
        )?;
        Ok(())
    }
    fn items(&self) -> Result<Value> {
        self.ask("items", json!({}))
    }
    fn path(&self, n: usize, suffix: u32) -> PathBuf {
        let stem = self.manifest["items"][n - 1]["stem"].as_str().unwrap();
        self.target.join(if suffix == 1 {
            format!("{stem}.jpg")
        } else {
            format!("{stem}-{suffix}.jpg")
        })
    }
}

#[test]
fn completion_requires_the_exact_registered_item_keys() -> Result<()> {
    let run = Run::new("skip", 2)?;
    for ordinal in [2, 1] {
        let owner = run.claim(ordinal, 90_000)?;
        let stage = run.stage()?;
        batch(&run.l.path, run.prepare(&owner, &stage, 1))?;
        assert_eq!(
            batch(&run.l.path, run.publish(&owner))?["status"],
            "published"
        );
    }
    assert_eq!(batch(&run.l.path, run.ack(2))?["status"], "delivered");
    assert_eq!(run.items()?["complete"], false);

    let database = rusqlite::Connection::open(&run.l.path)?;
    let key = format!(
        "wb032.item.v1/{}/002",
        run.manifest["batchID"].as_str().unwrap()
    );
    let misplaced = format!("{key}-outside-manifest");
    database.execute("UPDATE lc_meta SET key=?1 WHERE key=?2", [&misplaced, &key])?;
    assert!(batch(&run.l.path, run.ack(1)).is_err());
    let result = run.items()?;
    assert_eq!(result["complete"], false);
    assert_eq!(result["items"][0]["state"], "prepared");
    assert_eq!(result["items"][1]["state"], "pending");

    database.execute("UPDATE lc_meta SET key=?1 WHERE key=?2", [&key, &misplaced])?;
    assert_eq!(batch(&run.l.path, run.ack(1))?["status"], "delivered");
    assert_eq!(batch(&run.l.path, run.ack(1))?["status"], "delivered");
    assert_eq!(run.items()?["complete"], true);
    for ordinal in [1, 2] {
        assert_eq!(fs::read(run.path(ordinal, 1))?, DATA);
    }
    Ok(())
}

// Subprocess hook is inert for ordinary test runs. A command succeeds through the real library
// entry point before SIGKILL prevents the host from recording or acting on its response.
#[test]
fn workbench_crash_worker() -> Result<()> {
    let Some(file) = std::env::var_os("RAWMASTER_TEST_035_CRASH_COMMAND") else {
        return Ok(());
    };
    let input: Value = serde_json::from_slice(&fs::read(file)?)?;
    let reply = batch(
        Path::new(input["database"].as_str().unwrap()),
        input["command"].clone(),
    )?;
    assert_eq!(&reply[input["field"].as_str().unwrap()], &input["expected"]);
    unsafe { libc::raise(libc::SIGKILL) };
    Err("crash worker survived".into())
}
fn crash_after(run: &Run, command: &Value, field: &str, expected: Value) -> Result<()> {
    let spec = run.l._root.path().join("crash-command.json");
    fs::write(
        &spec,
        serde_json::to_vec(
            &json!({"database":run.l.path,"command":command,"field":field,"expected":expected}),
        )?,
    )?;
    let path = module_path!().split_once("::").unwrap().1;
    let status = Command::new(std::env::current_exe()?)
        .args([
            "--exact",
            &format!("{path}::workbench_crash_worker"),
            "--nocapture",
        ])
        .env("RAWMASTER_TEST_035_CRASH_COMMAND", &spec)
        .stdout(Stdio::null())
        .status()?;
    assert_eq!(status.signal(), Some(libc::SIGKILL));
    Ok(())
}

#[test]
fn actual_process_loss_after_prepare_publication_and_ack_preserves_each_file_and_terminal_count(
) -> Result<()> {
    let mut r = Run::new("skip", 2)?;
    let lease = r.claim(1, 90000)?;
    let stage = r.stage()?;
    let prepare = r.prepare(&lease, &stage, 1);
    // The first response carries only the public ordinal, SHA, size and selected basename.
    let digest = hex::encode(Sha256::digest(DATA));
    let expected = json!({"ordinal":1,"state":"prepared","attempt":1,"generation":1,"filename":r.path(1,1).file_name().unwrap().to_str(),
        "sha256":digest,"byteCount":DATA.len(),"reason":null});
    crash_after(&r, &prepare, "item", expected)?;
    assert_eq!(batch(&r.l.path, r.ack(1))?["status"], "missing");
    assert!(r.target.join(&stage).exists());
    assert!(!r.path(1, 1).exists());
    r.stop(false)?;
    r.resume()?;
    assert!(batch(&r.l.path, r.publish(&lease)).is_err());
    let fresh = r.claim(1, 90000)?;
    crash_after(&r, &r.publish(&fresh), "status", json!("published"))?;
    assert_eq!(fs::read(r.path(1, 1))?, DATA);
    assert_eq!(r.items()?["items"][0]["state"], "prepared");
    crash_after(&r, &r.ack(1), "status", json!("delivered"))?;
    assert_eq!(batch(&r.l.path, r.ack(1))?["status"], "delivered");
    assert_eq!(r.items()?["items"][0]["state"], "delivered");
    let other = r.claim(2, 90000)?;
    fs::write(r.path(2, 1), b"external")?;
    let mut skip = other;
    skip["directory"] = json!(r.target);
    skip["suffix"] = 1.into();
    assert_eq!(r.ask("skipItem", skip)?["item"]["state"], "skipped");
    assert_eq!(fs::read(r.path(2, 1))?, b"external");
    assert_eq!(r.items()?["complete"], true);
    assert_eq!(r.ask("load", json!({}))?["batch"]["phase"], "done");
    assert_eq!(
        batch(&r.l.path, json!({"action":"list"}))?["batches"][0]["phase"],
        "done"
    );
    assert!(r.resume().is_err());
    Ok(())
}

#[test]
fn two_windows_expired_owners_legacy_claim_and_cancel_share_no_publication_authority() -> Result<()>
{
    let mut r = Run::new("rename", 1)?;
    let request = r.cmd(
        "claimItem",
        json!({"ordinal":1,"generation":1,"token":r.parent["token"],"leaseMs":90000}),
    );
    let mut old = Queue::open(&r.l.path)?;
    let replies = race(&r.l.path, &request)
        .into_iter()
        .collect::<Result<Vec<_>>>()?;
    let tokens: Vec<_> = replies
        .iter()
        .filter_map(|x| x["itemToken"].as_str())
        .collect();
    assert_eq!(tokens.len(), 1);
    let mut owner =
        json!({"ordinal":1,"generation":1,"token":r.parent["token"],"itemToken":tokens[0]});
    let stage = r.stage()?;
    batch(&r.l.path, r.prepare(&owner, &stage, 1))?;
    owner["leaseMs"] = 25.into();
    r.ask("renewItem", owner.clone())?;
    std::thread::sleep(Duration::from_millis(55));
    assert!(batch(&r.l.path, r.publish(&owner)).is_err());
    assert!(r.ask("renewItem", owner.clone()).is_err());
    let owner = r.claim(1, 90000)?;
    assert!(old
        .request(serde_json::from_value(json!({"op":"claim"}))?)?
        .is_null());
    let legacy_key = format!(
        "wb032.item.v1/{}/001",
        r.manifest["batchID"].as_str().unwrap()
    );
    if let Some(binary) = std::env::var_os("RAWMASTER_TEST_035_LEGACY_CATALOG") {
        // Load the actual old ABI in a separate process. Send the private token over its input pipe.
        let script = r#"
import ctypes as c, hashlib, json, pathlib, sys
p,db,key=sys.argv[1:]
class Reply(c.Structure):
    _fields_=[('data',c.c_void_p),('length',c.c_size_t)]
lib=c.CDLL(p)
lib.rm_library_request_v1.argtypes=[c.c_char_p,c.c_size_t,c.c_char_p,c.c_size_t,c.POINTER(Reply)]
lib.rm_library_release_v1.argtypes=[c.POINTER(Reply)]
def call(request):
    m=json.dumps(dict(operation='scheduler',request=request)).encode()
    r=Reply(); status=lib.rm_library_request_v1(db.encode(),len(db.encode()),m,len(m),c.byref(r))
    value=json.loads(c.string_at(r.data,r.length));lib.rm_library_release_v1(c.byref(r));return status,value
for request in ({'op':'capabilities'}, {'op':'claim'}, {'op':'claim','key':key}):
    status, reply = call(request)
    assert status != 0 and 'upgraded library' in reply['error'], reply
assert call({'op':'check','key':key,'token':sys.stdin.read()})[0]!=0
print('Verified legacy v9 library rejects v10',hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest())
"#;
        let mut process = Command::new("python3")
            .arg("-c")
            .arg(script)
            .arg(binary)
            .arg(&r.l.path)
            .arg(&legacy_key)
            .stdin(Stdio::piped())
            .spawn()?;
        process
            .stdin
            .take()
            .unwrap()
            .write_all(owner["itemToken"].as_str().unwrap().as_bytes())?;
        assert!(process.wait()?.success());
    }
    assert!(op(
        &r.l.path,
        json!({"op":"check","key":legacy_key,"token":owner["itemToken"]})
    )
    .is_err());
    assert!(op(
        &r.l.path,
        json!({"op":"reconcile","key":legacy_key,"safeToResubmit":true})
    )
    .is_err());
    assert_eq!(
        r.l.db
            .query_row("SELECT count(*) FROM lc_task_jobs", [], |row| row
                .get::<_, i64>(0))?,
        0
    );
    r.ask(
        "renew",
        json!({"generation":1,"token":r.parent["token"],"leaseMs":25}),
    )?;
    std::thread::sleep(Duration::from_millis(65));
    assert!(batch(&r.l.path, r.publish(&owner)).is_err());
    assert!(!r.path(1, 1).exists());
    r.resume()?;
    let next = r.claim(1, 90000)?;
    assert!(batch(&r.l.path, r.publish(&owner)).is_err());
    r.stop(true)?;
    assert!(batch(&r.l.path, r.publish(&next)).is_err());
    assert_eq!(batch(&r.l.path, r.ack(1))?["status"], "missing");
    assert!(r.target.join(&stage).is_file());
    assert!(!r.path(1, 1).exists());
    assert!(old
        .request(serde_json::from_value(json!({"op":"claim"}))?)?
        .is_null());
    Ok(())
}

#[test]
fn prepared_conflict_keeps_same_name_and_stage_and_late_ack_preserves_parent_cancellation(
) -> Result<()> {
    let r = Run::new("rename", 1)?;
    let owner = r.claim(1, 90000)?;
    let stage = r.stage()?;
    fs::write(r.path(1, 1), b"prior output")?;
    assert_eq!(
        batch(&r.l.path, r.prepare(&owner, &stage, 1))?["status"],
        "destinationExists"
    );
    assert_eq!(
        batch(&r.l.path, r.prepare(&owner, &stage, 2))?["item"]["state"],
        "prepared"
    );
    fs::write(r.path(1, 2), DATA)?;
    assert_eq!(batch(&r.l.path, r.publish(&owner))?["status"], "conflict");
    assert_eq!(batch(&r.l.path, r.ack(1))?["status"], "conflict");
    assert!(batch(&r.l.path, r.prepare(&owner, &stage, 3)).is_err());
    assert!(r.target.join(&stage).is_file());
    fs::remove_file(r.path(1, 2))?;
    assert_eq!(batch(&r.l.path, r.publish(&owner))?["status"], "published");
    r.stop(true)?;
    assert_eq!(batch(&r.l.path, r.ack(1))?["status"], "delivered");
    assert_eq!(r.ask("load", json!({}))?["batch"]["phase"], "cancelled");
    assert_eq!(fs::read(r.path(1, 1))?, b"prior output");
    assert!(!r.path(1, 3).exists());
    // A subsequent equal-byte replacement is new physical output, even after a valid receipt.
    fs::rename(r.path(1, 2), r.target.join("saved"))?;
    fs::write(r.path(1, 2), DATA)?;
    assert_eq!(batch(&r.l.path, r.ack(1))?["status"], "conflict");
    assert_eq!(r.items()?["items"][0]["state"], "delivered");
    Ok(())
}

#[test]
fn directory_grant_cannot_be_added_later_replaced_or_inherited_from_a_restored_catalog(
) -> Result<()> {
    let r = Run::new("rename", 1)?;
    let check = r.cmd("checkDirectory", json!({"directory":r.target}));
    assert_eq!(batch(&r.l.path, check.clone())?["valid"], true);
    let owner = r.claim(1, 90000)?;
    let stage = r.stage()?;
    batch(&r.l.path, r.prepare(&owner, &stage, 1))?;
    let moved = r.l._root.path().join("disconnected");
    fs::rename(&r.target, &moved)?;
    fs::create_dir(&r.target)?;
    assert!(batch(&r.l.path, check.clone()).is_err());
    assert!(batch(&r.l.path, r.publish(&owner)).is_err());
    assert!(!r.path(1, 1).exists());
    fs::remove_dir(&r.target)?;
    symlink(&moved, &r.target)?;
    assert!(batch(&r.l.path, check.clone()).is_err());
    fs::remove_file(&r.target)?;
    fs::rename(&moved, &r.target)?;
    assert_eq!(batch(&r.l.path, check.clone())?["valid"], true);
    let root = tempfile::tempdir()?;
    let backup_dir = root.path().join("package");
    let restored = root.path().join("restored");
    backup::execute(
        &r.l.path,
        &json!({"op":"backup","destination":backup_dir,"mode":"catalog","generation":"g1"}),
    )?;
    let restored = backup::execute(
        &r.l.path,
        &json!({"op":"restore","package":backup_dir,"destination":restored}),
    )?;
    let copy = Path::new(restored["libraryPath"].as_str().unwrap());
    assert_eq!(batch(copy, r.cmd("items", json!({})))?["available"], false);
    assert!(batch(copy, check).is_err());
    assert!(batch(copy, r.publish(&owner)).is_err());
    assert!(batch(copy, r.ack(1)).is_err());
    assert!(r.target.join(&stage).exists());
    let mut old = r.manifest.clone();
    old["batchID"] = json!("00000000-0000-4000-8000-0000000000ab");
    register(&r.l.path, &old)?;
    assert!(batch(
        &r.l.path,
        json!({"action":"register","manifest":old,"directory":r.target})
    )
    .is_err());
    assert!(batch(
        &r.l.path,
        json!({"action":"checkDirectory","batchID":old["batchID"],"directory":r.target})
    )
    .is_err());
    assert!(register(&r.l.path, &r.manifest).is_err());
    let duplicate = batch(
        &r.l.path,
        json!({"action":"register","manifest":r.manifest,"directory":r.target}),
    )?;
    assert!(duplicate.get("token").is_none());
    Ok(())
}

#[test]
fn bad_stage_paths_and_different_frozen_formats_fail_and_failed_item_waits_for_explicit_generation(
) -> Result<()> {
    let mut r = Run::new("rename", 1)?;
    let owner = r.claim(1, 90000)?;
    let stage = r.stage()?;
    for bad in [
        "../pixels.jpg",
        "pixels.jpg",
        ".rawmaster-export-invalid/pixels.jpg",
        "/tmp/x.jpg",
        &stage.replace("jpg", "png"),
    ] {
        assert!(batch(&r.l.path, r.prepare(&owner, bad, 1)).is_err());
    }
    let file = r.target.join(&stage);
    fs::rename(&file, file.with_extension("other"))?;
    symlink(file.with_extension("other"), &file)?;
    assert!(batch(&r.l.path, r.prepare(&owner, &stage, 1)).is_err());
    let mut failure = owner.clone();
    failure["reason"] = "sourceOffline".into();
    r.ask("failItem", failure)?;
    assert_eq!(r.items()?["items"][0]["state"], "failed");
    assert_eq!(r.items()?["items"][0]["reason"], "sourceOffline");
    assert!(r.claim(1, 90000).is_err());
    r.stop(false)?;
    r.resume()?;
    assert!(r.claim(1, 90000).is_ok());
    Ok(())
}

#[test]
fn equal_frozen_names_can_only_reserve_one_candidate_and_attempts_reset_on_explicit_continuation(
) -> Result<()> {
    let r = Run::with_names("rename", 2, true)?;
    let one = r.claim(1, 90000)?;
    let two = r.claim(2, 90000)?;
    let s1 = r.stage()?;
    let s2 = r.stage()?;
    let gate = Arc::new(Barrier::new(2));
    let workers: Vec<_> = [r.prepare(&one, &s1, 1), r.prepare(&two, &s2, 1)]
        .into_iter()
        .map(|command| {
            let db = r.l.path.clone();
            let gate = gate.clone();
            std::thread::spawn(move || {
                gate.wait();
                batch(&db, command)
            })
        })
        .collect();
    let replies = workers
        .into_iter()
        .map(|w| w.join().unwrap())
        .collect::<Result<Vec<_>>>()?;
    assert_eq!(
        replies
            .iter()
            .filter(|v| v["status"] == "destinationExists")
            .count(),
        1
    );
    let loser = if replies[0]["status"] == "destinationExists" {
        (&one, &s1)
    } else {
        (&two, &s2)
    };
    assert_eq!(
        batch(&r.l.path, r.prepare(loser.0, loser.1, 2))?["item"]["state"],
        "prepared"
    );
    for (n, owner) in [(1, one), (2, two)] {
        assert_eq!(batch(&r.l.path, r.publish(&owner))?["status"], "published");
        assert_eq!(batch(&r.l.path, r.ack(n))?["status"], "delivered");
    }
    assert!(r.items()?["complete"].as_bool().unwrap());
    let mut retry = Run::new("rename", 1)?;
    for attempt in 1..=8 {
        let _ = retry.claim(1, 10)?;
        assert_eq!(retry.items()?["items"][0]["attempt"], attempt);
        std::thread::sleep(Duration::from_millis(25));
    }
    assert!(retry.claim(1, 90000).is_err());
    retry.stop(false)?;
    retry.resume()?;
    retry.claim(1, 90000)?;
    assert_eq!(retry.items()?["items"][0]["attempt"], 1);
    Ok(())
}

fn another_batch(run: &Run, suffix: u32) -> Result<(Value, Value)> {
    let mut manifest = run.manifest.clone();
    manifest["batchID"] = format!("00000000-0000-4000-8000-{suffix:012x}").into();
    let id = manifest["batchID"].clone();
    let lease = batch(
        &run.l.path,
        json!({"action":"register","manifest":manifest,"directory":run.target}),
    )?;
    let mut owner = json!({"batchID":id,"ordinal":1,"generation":1,"token":lease["token"]});
    let mut claim = owner.clone();
    claim["action"] = "claimItem".into();
    owner["itemToken"] = batch(&run.l.path, claim)?["itemToken"].clone();
    Ok((id, owner))
}

#[test]
fn two_active_batches_in_one_directory_reserve_distinct_names_before_either_file_exists(
) -> Result<()> {
    let r = Run::new("rename", 1)?;
    let a = r.claim(1, 90000)?;
    let (idb, b) = another_batch(&r, 0xe2)?;
    let first = r.manifest["batchID"].clone();
    let s1 = r.stage()?;
    let s2 = r.stage()?;
    let cmd_a = r.prepare(&a, &s1, 1);
    let mut cmd_b = r.prepare(&b, &s2, 1);
    cmd_b["batchID"] = idb.clone();
    let gate = Arc::new(Barrier::new(2));
    let workers: Vec<_> = [cmd_a, cmd_b]
        .into_iter()
        .map(|c| {
            let db = r.l.path.clone();
            let gate = gate.clone();
            std::thread::spawn(move || {
                gate.wait();
                batch(&db, c)
            })
        })
        .collect();
    let replies = workers
        .into_iter()
        .map(|worker| worker.join().unwrap())
        .collect::<Result<Vec<_>>>()?;
    assert_eq!(
        replies
            .iter()
            .filter(|reply| reply["status"] == "destinationExists")
            .count(),
        1
    );
    assert!(!r.path(1, 1).exists());
    let (id, owner, stage) = if replies[0]["status"] == "destinationExists" {
        (&first, &a, &s1)
    } else {
        (&idb, &b, &s2)
    };
    let mut next = r.prepare(owner, stage, 2);
    next["batchID"] = id.clone();
    assert_eq!(batch(&r.l.path, next)?["item"]["state"], "prepared");
    for (id, lease) in [(&first, &a), (&idb, &b)] {
        let mut publish = r.publish(lease);
        publish["batchID"] = id.clone();
        assert_eq!(batch(&r.l.path, publish)?["status"], "published");
        let mut ack = r.ack(1);
        ack["batchID"] = id.clone();
        assert_eq!(batch(&r.l.path, ack)?["status"], "delivered");
    }
    assert_eq!(fs::read(r.path(1, 1))?, DATA);
    assert_eq!(fs::read(r.path(1, 2))?, DATA);
    // Delivered reservations are released in their own ACK. The actual existing path now guards the name.
    let (idc, c) = another_batch(&r, 0xe3)?;
    let mut third = r.prepare(&c, &r.stage()?, 1);
    third["batchID"] = idc;
    assert_eq!(
        batch(&r.l.path, third.clone())?["status"],
        "destinationExists"
    );
    fs::remove_file(r.path(1, 1))?;
    assert_eq!(batch(&r.l.path, third)?["item"]["state"], "prepared");
    Ok(())
}

#[test]
fn cancelling_a_prepared_batch_does_not_transfer_its_original_receipt_to_another_batch(
) -> Result<()> {
    let r = Run::new("rename", 1)?;
    let a = r.claim(1, 90000)?;
    let stage = r.stage()?;
    batch(&r.l.path, r.prepare(&a, &stage, 1))?;
    r.stop(true)?;
    let (id, b) = another_batch(&r, 0xe4)?;
    let mut second = r.prepare(&b, &r.stage()?, 1);
    second["batchID"] = id.clone();
    assert_eq!(
        batch(&r.l.path, second.clone())?["status"],
        "destinationExists"
    );
    assert_eq!(batch(&r.l.path, r.ack(1))?["status"], "missing");
    second["suffix"] = 2.into();
    batch(&r.l.path, second)?;
    let mut publish = r.publish(&b);
    publish["batchID"] = id;
    assert_eq!(batch(&r.l.path, publish)?["status"], "published");
    assert!(batch(&r.l.path, r.publish(&a)).is_err());
    assert!(!r.path(1, 1).exists());
    assert_eq!(fs::read(r.path(1, 2))?, DATA);
    assert_eq!(fs::read(r.target.join(stage))?, DATA);
    Ok(())
}
