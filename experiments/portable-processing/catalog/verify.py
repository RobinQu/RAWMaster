"""Exercise the release Rust host across OS processes. All databases and artifacts are private fixtures."""
import argparse
import collections
import concurrent.futures
import contextlib
import datetime as dt
import hashlib
import json
import math
import pathlib
import platform
import signal
import sqlite3
import statistics
import subprocess
import tempfile
import threading
import time


ROOT = pathlib.Path(__file__).resolve().parents[3]
FIXTURE = ROOT / "Tests/RAWMasterImagingTests/Fixtures/SequenceGrouping/v1/cases/burst14-context38/files/asset0000.jpg"


class Host:
    def __init__(self, binary, db):
        self.process = subprocess.Popen([binary, db], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)

    def send(self, op, *, expect_error=False, **args):
        self.process.stdin.write(json.dumps({"op": op, **args}) + "\n")
        self.process.stdin.flush()
        reply = json.loads(self.process.stdout.readline())
        if expect_error:
            assert reply["ok"] is False, reply
            return reply["error"]
        assert reply["ok"] is True, reply
        return reply["value"]

    def close(self):
        self.process.stdin.close()
        self.process.stdout.close()
        self.process.wait(timeout=5)

    def submit(self, key, lane="editing", resource="gpu", **options):
        return self.send("submit", key=key, lane=lane, resource=resource, payload={"revision": 1}, **options)

    def finish(self, lease, **options):
        return self.send("complete", key=lease["key"], token=lease["token"], **options)


def wait_until(epoch_ms):
    time.sleep(max(0, epoch_ms / 1_000 - time.time()) + 0.025)


def require_count(db, sql, expected):
    with contextlib.closing(sqlite3.connect(db)) as c:
        count, = c.execute(sql).fetchone()
    assert count == expected, (sql, count, expected)
    return count


def mixed_load(host):
    for i in range(20):
        for lane in ("library", "export", "editing"):
            host.submit(f"{lane}-{i}", lane, "gpu")
    sequence = []
    for _ in range(25):
        work = host.send("claim")
        sequence.append(work["lane"])
        host.finish(work, result="done")
    assert sequence == ["editing", "export", "editing", "library", "editing"] * 5, sequence
    return {"backlogPerLane": 20, "claims": sequence, "served": dict(collections.Counter(sequence))}


def resource_budget(host):
    host.submit("foreground", "editing", "gpu", memoryMiB=384)
    host.submit("export", "export", "cpu", memoryMiB=128)
    host.submit("index", "library", "cpu", memoryMiB=192)
    large, small = host.send("claim"), host.send("claim")
    assert [large["key"], small["key"]] == ["foreground", "export"]
    assert host.send("claim") is None
    assert host.send("cancel", key=large["key"])["state"] == "cancelling"
    assert host.send("claim") is None
    rejected = host.finish(large, expect_error=True, result="stale")
    assert host.send("ackCancel", key=large["key"], token=large["token"])["state"] == "cancelled"
    assert host.send("claim")["key"] == "index"
    return {"heldMiB": large["memoryMiB"] + small["memoryMiB"], "cancelHeldCapacityUntilAck": True,
            "lateCompletion": rejected, "libraryAdmittedAfterAck": True}


def bulk_status(host):
    keys = [f"visible-{i}" for i in range(60)]
    for key in keys:
        host.submit(key, "library", "cpu")
    expected = [host.send("status", key=key) for key in keys]
    assert host.send("statuses", keys=keys) == expected
    assert host.send("statuses", keys=[keys[7], "absent", keys[7]]) == [expected[7], None, expected[7]]
    assert host.send("statuses", keys=[]) == []
    assert host.send("statuses", keys=keys * 5, expect_error=True)
    return {"visibleJobs": 60, "sameOrderAndValues": True, "duplicateAndMissingPreserved": True, "maximumKeys": 256}


def concurrent_claims(binary, db, host):
    selectors = ("cpu", "cpu", "gpu", "io", "gpu", "io", "cpu", "cpu")
    for i, resource in enumerate(selectors):
        host.submit(f"job-{i}", "library", resource)
    barrier = threading.Barrier(len(selectors), timeout=10)

    def worker(_):
        with contextlib.closing(Host(binary, db)) as other:
            other.send("capabilities")
            barrier.wait()
            return other.send("claim")

    with concurrent.futures.ThreadPoolExecutor(max_workers=len(selectors)) as workers:
        leases = [j for j in workers.map(worker, selectors) if j]
    counts = collections.Counter(j["resource"] for j in leases)
    assert counts == {"gpu": 1, "cpu": 2, "io": 1}, counts
    assert len({j["key"] for j in leases}) == len(leases)
    return {"contendingRustProcesses": len(selectors), "admitted": dict(counts), "distinctLeases": len(leases)}


def recover_crash(binary, db, host):
    host.submit("crash")
    with contextlib.closing(Host(binary, db)) as dying:
        first = dying.send("claim", leaseMs=180)
        dying.process.kill()
        assert dying.process.wait(timeout=5) == -signal.SIGKILL
    wait_until(first["leaseUntilMs"])
    second = host.send("claim")
    assert second["attempt"] == 2 and first["key"] == second["key"] and first["token"] != second["token"]
    rejected = host.finish(first, result="late", expect_error=True)
    assert host.finish(second, result="active")["state"] == "done"
    host.submit("remote", replaySafe=False)
    remote = host.send("claim", leaseMs=30)
    wait_until(remote["leaseUntilMs"])
    assert host.send("claim") is None
    assert host.send("status", key="remote")["state"] == "reconcile"
    return {"exitSignal": "SIGKILL", "attempts": [first["attempt"], second["attempt"]],
            "staleCommit": rejected, "nonReplayableExpiredLease": "reconcile"}


def publish_fixture(host, db, directory, fixture):
    digest = hashlib.sha256(fixture.read_bytes()).hexdigest()
    file = directory / "worker-output.jpg"
    host.submit("photo", "export", "io")
    first = host.send("claim")
    error = host.finish(first, result=digest, file=str(file), expect_error=True)
    assert not file.exists()
    state = host.send("fail", key="photo", token=first["token"], error=error, **{"class": "transient"})
    assert state["state"] == "queued" and state["lastError"] == error
    assert host.send("claim") is None
    wait_until(state["availableAtMs"])
    file.write_bytes(fixture.read_bytes())
    second = host.send("claim")
    assert second["key"] == "photo" and second["attempt"] == 2
    # Abort the queue-state mutation after the catalog has staged the actual JPEG bytes.
    with contextlib.closing(sqlite3.connect(db)) as conn:
        conn.execute("CREATE TRIGGER publication_fault BEFORE UPDATE OF state ON jobs WHEN NEW.state='done' "
                     "BEGIN SELECT RAISE(ABORT,'injected publication failure'); END")
        failed = host.finish(second, result=digest, file=str(file), expect_error=True)
        assert "injected publication failure" in failed and host.send("status", key="photo")["state"] == "running"
        require_count(db, "SELECT count(*) FROM lc_resources", 0)
        staged = directory / "LibraryResources" / "objects" / digest[:2] / digest
        assert staged.read_bytes() == file.read_bytes()
        conn.execute("DROP TRIGGER publication_fault")
    receipt = host.finish(second, result=digest, file=str(file))
    file.unlink()
    replay = host.finish(second, result=digest, file=str(file))
    assert receipt == replay and replay["state"] == "done" and replay["resourceID"] == "job:photo"
    assert host.submit("photo", "export", "io") == receipt
    conflict = host.send("submit", key="photo", lane="export", resource="io", payload={"revision": 2}, expect_error=True)
    rows = require_count(db, "SELECT count(*) FROM lc_resources", 1)
    return {"missingWorkerOutput": error, "attempts": second["attempt"], "recoverableStagingFault": failed,
            "unregisteredObjectObserved": True, "registeredAfterLostAckReplay": rows, "keyConflict": conflict,
            "sha256": digest, "bytes": staged.stat().st_size}


def recovery_rules(host):
    host.submit("offline")
    job = host.send("claim")
    host.send("fail", key="offline", token=job["token"], error="volume absent", **{"class": "offline"})
    assert host.send("claim") is None and host.send("wake", key="offline")["state"] == "queued"
    recovered = host.send("claim", leaseMs=1_000)
    renewed = host.send("heartbeat", key="offline", token=recovered["token"], leaseMs=2_000)
    assert renewed["leaseUntilMs"] > recovered["leaseUntilMs"]
    host.finish(recovered, result="available")
    for name, kind, outcome in (("validation", "permanent", "failed"), ("remote", "uncertain", "reconcile")):
        host.submit(name)
        job = host.send("claim")
        failure = host.send("fail", key=name, token=job["token"], error=name, **{"class": kind})
        assert failure["state"] == outcome
    host.submit("capped", maxAttempts=2)
    for attempt in (1, 2):
        lease = host.send("claim")
        failed = host.send("fail", key="capped", token=lease["token"], error="retry", **{"class": "transient"})
        assert failed["state"] == ("failed" if attempt == 2 else "queued")
        if attempt == 1:
            wait_until(failed["availableAtMs"])
    assert host.send("claim") is None
    return {"wakeAfterSourceReturned": recovered["attempt"], "heartbeatExtended": True,
            "permanent": "failed", "unknown": "reconcile", "transientStoppedAtAttempt": failed["attempt"]}


def benchmark(host):
    samples = []
    for i in range(110):
        before = time.perf_counter_ns()
        host.submit(f"bench-{i}", "library", "cpu")
        lease = host.send("claim")
        host.finish(lease, result="control-plane")
        if i >= 10:
            samples.append((time.perf_counter_ns() - before) / 1e6)
    return {"unit": "ms for submit + claim + complete, NDJSON pipes, WAL synchronous FULL; empty job",
            "warmup": 10, "n": len(samples), "p50": round(statistics.median(samples), 3),
            "p95NearestRank": round(sorted(samples)[math.ceil(0.95 * len(samples)) - 1], 3),
            "samplesMs": [round(s, 3) for s in samples]}


def run(binary, fixture):
    info = {"measuredAtUTC": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
            "runtime": platform.platform(), "rustBinarySHA256": hashlib.sha256(binary.read_bytes()).hexdigest(),
            "fixture": fixture.name, "sqliteObserverVersion": sqlite3.sqlite_version}
    with tempfile.TemporaryDirectory() as scratch:
        root = pathlib.Path(scratch)
        cases = {"capabilities": lambda h: h.send("capabilities"), "fairness": mixed_load, "bulkStatus": bulk_status,
                 "memoryAndCancel": resource_budget, "parallelClaim": lambda h: concurrent_claims(binary, db, h),
                 "killedProcess": lambda h: recover_crash(binary, db, h),
                 "publish": lambda h: publish_fixture(h, db, db.parent, fixture), "recovery": recovery_rules,
                 "controlLatency": benchmark}
        for name, case in cases.items():
            directory = root / name
            directory.mkdir()
            db = directory / "queue.sqlite"
            with contextlib.closing(Host(binary, db)) as host:
                info[name] = case(host)
            with contextlib.closing(sqlite3.connect(db)) as reader:
                assert reader.execute("PRAGMA integrity_check").fetchone() == ("ok",)
        foreign = root / "existing.sqlite"
        with contextlib.closing(sqlite3.connect(foreign)) as reader:
            reader.execute("CREATE TABLE sentinel(id INTEGER)")
        rejected = subprocess.run([binary, foreign], input="", text=True, capture_output=True)
        assert rejected.returncode != 0 and "empty experiment database" in rejected.stderr, rejected
        require_count(foreign, "SELECT count(*) FROM sqlite_schema WHERE name='jobs'", 0)
        info["foreignDatabaseRejected"] = True
    return info


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("binary", type=pathlib.Path)
    parser.add_argument("--fixture", type=pathlib.Path, default=FIXTURE)
    args = parser.parse_args()
    print(json.dumps(run(args.binary.resolve(), args.fixture), indent=2))
