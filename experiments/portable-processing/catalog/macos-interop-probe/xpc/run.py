"""Exercise real signed peers, scoped access, and one frozen v10 workbench item."""

import argparse
import errno
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess as sp
import tempfile
import sys
import uuid

HERE = Path(__file__).resolve().parent
ROOT = next(
    p for p in HERE.parents if (p / "Modules/LibraryCatalog/Cargo.toml").is_file()
)
sys.dont_write_bytecode = True
old = ROOT / "experiments/portable-processing/catalog/macos-interop-probe/run.py"
spec = importlib.util.spec_from_file_location("macx", old)
X = importlib.util.module_from_spec(spec)
spec.loader.exec_module(X)


def invoke(subj, op, body, scope, fds, *, other=False, wrong=False, inject=False):
    req = {
        "fixtureMismatch": inject,
        "op": op,
        "body": body,
        "scopes": {k: {"kind": v[0], "path": str(v[1])} for k, v in scope.items()},
        "fds": fds,
    }
    cp = sp.run(
        [
            subj["otherHost" if other else "host"],
            "0" * 40 if wrong else subj["workerCDHash"],
        ],
        input=json.dumps(req),
        text=True,
        capture_output=True,
        timeout=12,
        pass_fds=list(fds.values()),
    )
    if cp.returncode:
        raise RuntimeError(f"caller rc {cp.returncode}: {cp.stderr}")
    v = json.loads(cp.stdout)
    if not (other or wrong):
        assert (
            v.get("runtimeSandboxEntitlement")
            and v["callerPID"] == v["serviceSawCaller"]
            and v["callerPID"] != v["workerPID"]
        )
        assert v["launchParent"] == 1 and v["hostUID"] == v["workerUID"] == os.getuid()
    return v


def redacted(v):
    if isinstance(v, dict):
        return {k: redacted(x) for k, x in v.items() if "token" not in k.lower()}
    if isinstance(v, list):
        return [redacted(x) for x in v]
    return v


def run(bins, app, reports, photo_only=False):
    with tempfile.TemporaryDirectory(prefix="aa-owned-", dir=reports.parent) as td:
        path = Path(td)
        pic = path / "photos"
        pic.mkdir(mode=0o700)
        asset, other = pic / "asset.jpg", pic / "withheld.jpg"
        shutil.copyfile(X.old.IMAGE, asset)
        shutil.copyfile(X.old.IMAGE, other)
        input_sha = X.sha(asset)
        pf = os.open(pic, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        af = os.open(asset, os.O_RDONLY | os.O_NOFOLLOW)
        other_inode = other.stat().st_ino
        of = os.open(other, os.O_RDONLY | os.O_NOFOLLOW)
        data = {
            "signedSubjects": app,
            "syntheticRoot": path.name,
            "photos": {},
            "wrongSignature": {},
            "queue": [],
        }
        reports.write_text(json.dumps(data, indent=2) + "\n")

        def flush():
            reports.write_text(json.dumps(redacted(data), indent=2) + "\n")

        try:
            for lab, kind in [
                ("fd", "none"),
                ("withoutScope", "noScope"),
                ("implicit", "implicit"),
                ("fresh", "fresh"),
                ("sameBytesWrongFile", "fresh"),
                ("sameNameDifferentFD", "fresh"),
                ("persistentReadonly", "persistent"),
            ]:
                v = invoke(
                    app,
                    "photo",
                    {"kind": kind, "asset": str(asset), "withheld": str(other)},
                    {"asset": (kind, other if lab == "sameBytesWrongFile" else asset)},
                    {"asset": of if lab == "sameNameDifferentFD" else af, "parent": pf},
                    inject=lab in ("sameBytesWrongFile", "sameNameDifferentFD"),
                )
                data["photos"][lab] = v
                flush()
                r = v["result"]
                assert (
                    r["readOnlyFD"]
                    and r["fdSHA256"] == input_sha
                    and r["heldWriteErrno"] == errno.EBADF
                )
                assert r["fdInode"] == (
                    other_inode if lab == "sameNameDifferentFD" else asset.stat().st_ino
                )
                assert (
                    r["freshReadBefore"]
                    == r["freshWriteBefore"]
                    == r["freshReadAfter"]
                    == r["freshWriteAfter"]
                    == errno.EPERM
                )
                assert r["freshSiblingRead"] == r["freshSiblingWrite"] == errno.EPERM
                if lab == "fresh":
                    assert (
                        r["firstStart"]
                        and r["secondStart"]
                        and r["matchedAPFSVolume"]
                        and r["matchedFD"]
                    )
                    assert (
                        r["stale"]
                        and not r["secondStale"]
                        and r["freshReadDuring"] == r["freshWriteDuring"] == 0
                    )
                    assert r["firstWriteOpenErrno"] == r["refreshedWriteOpenErrno"] == 0
                else:
                    assert (
                        r["freshReadDuring"] == r["freshWriteDuring"] == errno.EPERM
                        and not r["matchedFD"]
                    )
                if lab in ("sameBytesWrongFile", "sameNameDifferentFD"):
                    assert v["bookmarks"]["asset"][
                        "issuerMatchedFD"
                    ] is False and not r.get("reissued")
                if lab == "withoutScope":
                    assert (
                        not r["nameOnlyStart"] and r["nameOnlyReadErrno"] == errno.EPERM
                    )
                if lab == "persistentReadonly":
                    assert not r["resolved"] and r["resolutionError"] != 0
                if lab == "sameBytesWrongFile":
                    assert not r["matchedFD"] and other_inode != r["fdInode"]
            for lab, o, w in [
                ("differentCallerCDHash", True, False),
                ("differentExpectedWorkerCDHash", False, True),
            ]:
                v = invoke(
                    app,
                    "photo",
                    {"kind": "implicit", "asset": str(asset), "withheld": str(other)},
                    {"asset": ("implicit", asset)},
                    {"asset": af, "parent": pf},
                    other=o,
                    wrong=w,
                )
                data["wrongSignature"][lab] = v
                flush()
                assert v.get("phase") == "hello" and v["sentCapabilities"] is False
            if photo_only:
                return
            c = X.Catalog(path / "catalog", bins, X.RUNTIME)
            data["systemKeeper"] = {
                k: c.origin[k] for k in ("version", "sourceID", "abiIdentityMatches")
            }
            data["productionRuntimeSHA256"] = X.sha(X.RUNTIME)
            c.out = path / "delivery"
            c.out.mkdir(mode=0o700)
            for folder in [c.path, c.out]:
                (folder / ".scope-witness").write_bytes(b"role access only")
            df = os.open(c.out, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            fds = dict(zip(["directory", "main", "wal", "shm"], c.fds))
            fds["destination"] = df
            rf = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            fds["parent"] = rf

            def call(action, extra, *, dest="fresh", success=True):
                cmd = {
                    "action": action,
                    **({} if action == "register" else {"batchID": c.batch}),
                    **extra,
                }
                body = {
                    "catalog": str(c.path),
                    "destination": str(c.out),
                    "catalogKind": "fresh",
                    "destinationKind": dest,
                    "command": cmd,
                }
                v = invoke(
                    app,
                    "queue",
                    body,
                    {"catalog": ("fresh", c.path), "destination": (dest, c.out)},
                    fds,
                )
                data["queue"].append({"action": action, "mode": dest, **redacted(v)})
                flush()
                fact = v["result"]
                if success and fact.get("status") != 0:
                    raise RuntimeError(f"{action}: {redacted(fact)}")
                if success:
                    assert (
                        fact["sameSQLiteFunction"]
                        and fact["originalReadOnlyRoles"]
                        and fact["currentThreeObjects"]
                    )
                    assert fact["freshMainReadAfterStop"] == errno.EPERM
                    for sc in [fact["catalogScope"], fact["destinationScope"]]:
                        assert (
                            sc["matchedAPFSVolume"]
                            and sc["secondStart"]
                            and not sc["secondStale"]
                        )
                        assert (
                            sc["firstWriteOpenErrno"]
                            == sc["refreshedWriteOpenErrno"]
                            == 0
                        )
                    assert all(
                        q["allowed"] and all(r["matches"] for r in q["rows"])
                        for q in fact["txnChecks"]
                    )
                return fact

            try:
                source = X.old.source(c.origin["library"], c.out, c.batch)
                parent = call(
                    "register",
                    {"manifest": source, "directory": str(c.out), "leaseMs": 120000},
                )["answer"]
                own = {"ordinal": 1, "generation": 1, "token": parent["token"]}
                own["itemToken"] = call("claimItem", {**own, "leaseMs": 120000})[
                    "answer"
                ]["itemToken"]
                temp = c.out / (".rawmaster-export-" + str(uuid.uuid4()))
                temp.mkdir()
                stage = temp / "pixels.jpg"
                shutil.copyfile(asset, stage)
                ino = stage.stat().st_ino
                receipt = call(
                    "prepareItem",
                    {
                        **own,
                        "directory": str(c.out),
                        "stage": str(stage.relative_to(c.out)),
                        "suffix": 1,
                    },
                )["answer"]
                final = c.out / receipt["item"]["filename"]
                ticket = X.command(c.keeper, "ticket")
                assert (
                    ticket["state"] == "prepared"
                    and ticket["reservations"] == 1
                    and not final.exists()
                )
                checkpoint = X.command(c.keeper, "truncate")
                assert checkpoint == {"checkpointRC": 0, "log": 0, "done": 0}
                publish = {
                    "action": "publishItem",
                    "batchID": c.batch,
                    **own,
                    "directory": str(c.out),
                }
                untrusted = invoke(
                    app,
                    "queue",
                    {
                        "catalog": str(c.path),
                        "destination": str(c.out),
                        "catalogKind": "fresh",
                        "destinationKind": "fresh",
                        "command": publish,
                    },
                    {"catalog": ("fresh", c.path), "destination": ("fresh", c.out)},
                    fds,
                    other=True,
                )
                assert (
                    untrusted["phase"] == "hello"
                    and not untrusted["sentCapabilities"]
                    and X.command(c.keeper, "ticket") == ticket
                    and not final.exists()
                )
                data["wrongSignature"]["refusedWhilePrepared"] = {
                    **untrusted,
                    "originalTicketUnchanged": True,
                    "finalAbsent": True,
                    "reservationCount": ticket["reservations"],
                }
                denied = call(
                    "publishItem",
                    {**own, "directory": str(c.out)},
                    dest="noScope",
                    success=False,
                )
                assert (
                    denied.get("reason") == "unavailable directory grant"
                    and not final.exists()
                    and X.command(c.keeper, "ticket") == ticket
                    and stage.stat().st_ino == ino
                )
                assert (
                    call("publishItem", {**own, "directory": str(c.out)})["answer"][
                        "status"
                    ]
                    == "published"
                    and final.stat().st_ino == ino
                    and X.sha(final) == input_sha
                )
                ack = {"ordinal": 1, "directory": str(c.out)}
                first = call("acknowledgeItem", ack)["answer"]
                second = call("acknowledgeItem", ack)["answer"]
                end = X.command(c.keeper, "ticket")
                assert (
                    first == second
                    and first["status"] == "delivered"
                    and end["ticket"] == ticket["ticket"]
                    and end["reservations"] == 0
                    and not stage.exists()
                )
                checks = sp.check_output(
                    [
                        "/usr/bin/sqlite3",
                        "-readonly",
                        c.db,
                        "PRAGMA quick_check; SELECT count(*) FROM pragma_foreign_key_check; SELECT count(*) FROM lc_workbench_names",
                    ],
                    text=True,
                ).splitlines()
                assert checks == ["ok", "0", "0"]
                data["delivery"] = {
                    "originalStageInode": ino,
                    "finalInode": final.stat().st_ino,
                    "bytes": final.stat().st_size,
                    "sha256": input_sha,
                    "originTicketSHA256": hashlib.sha256(
                        json.dumps(ticket["ticket"], sort_keys=True).encode()
                    ).hexdigest(),
                    "originalTicketRetained": True,
                    "twoIdenticalAcknowledgments": True,
                    "checkBeforePublication": checkpoint,
                    "independentSystemSQLite": checks,
                }
            finally:
                os.close(rf)
                os.close(df)
                c.close()
            data["sandboxIdentifier"] = app["workerID"]
            data["generatedContainerPresent"] = (
                Path.home() / "Library/Containers" / app["workerID"]
            ).is_dir()
            data["unchangedPhotos"] = X.sha(other) == X.sha(asset) == input_sha
            flush()
        finally:
            os.close(of)
            os.close(af)
            os.close(pf)


if __name__ == "__main__":
    a = argparse.ArgumentParser()
    a.add_argument("--interop-build", type=Path, required=True)
    a.add_argument("--bundle-dir", type=Path, required=True)
    a.add_argument("--report", type=Path, required=True)
    a.add_argument("--photos-only", action="store_true")
    z = a.parse_args()
    run(
        z.interop_build.resolve(),
        json.loads((z.bundle_dir / "subjects.json").read_text()),
        z.report.resolve(),
        z.photos_only,
    )
