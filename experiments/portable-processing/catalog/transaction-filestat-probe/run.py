"""Guard actual v10 Workbench prepare/publish/ack in a private copy of the Linux backend."""

import argparse
from build import build
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess as sp
import sys
import tempfile
import uuid

here = Path(__file__).resolve().parent
repo = next(
    p for p in here.parents if (p / "Modules/LibraryCatalog/Cargo.toml").is_file()
)
arch = repo / "experiments/portable-processing/catalog/queue-transaction-probe/run.py"
u = importlib.util.spec_from_file_location("arch_fixture", arch)
helper = importlib.util.module_from_spec(u)
u.loader.exec_module(helper)


def sha(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


policies = [
    ("live-link", False, False, None, None),
    ("empty-decoys-link", True, False, None, None),
    ("empty-wal-copy-link", True, False, "link", "wal"),
    ("live-shm-copy-link", False, False, "link", "shm"),
    ("main-copy-write", True, False, "write", "main"),
    ("true-exclusive-rename", True, True, None, None),
    ("shm-copy-rename-fence", True, True, "rename", "shm"),
    ("after-publication-bad-ack", False, False, "ack", "main"),
    ("denied-preparation", False, False, "prepare", "wal"),
    ("same-byte-peer-catalog", True, False, "peer", None),
]


def run(d, case, keeper_binary, lib):
    name, empty, rename, bad, role = case
    d.mkdir()
    db = d / "library.sqlite"
    out = d / "delivery"
    out.mkdir()
    paths = [db, Path(str(db) + "-wal"), Path(str(db) + "-shm")]
    keeper = sp.Popen(
        [keeper_binary, db, helper.DDL],
        text=True,
        stdin=sp.PIPE,
        stdout=sp.PIPE,
        stderr=sp.PIPE,
    )
    opened = []
    events = []
    batch = str(uuid.uuid4())
    extra = []
    record = {
        "scenario": name,
        "journalWasTruncated": empty,
        "forcedLinkErrno": "EPERM" if rename else None,
        "events": events,
    }

    def read():
        line = keeper.stdout.readline()
        if not line:
            raise RuntimeError(keeper.stderr.read())
        return json.loads(line)

    def line(msg):
        keeper.stdin.write(msg + "\n")
        keeper.stdin.flush()
        return read()

    def acquire(path):
        fd = os.open(path, os.O_PATH | os.O_NOFOLLOW)
        opened.append(fd)
        return fd

    try:
        initial = read()
        assert initial["version"] == 10
        record["sqliteSourceID"] = initial["sourceID"]
        grants = [acquire(x) for x in [d, *paths]]

        def request(
            action, data, *, wrong=None, expected=0, hardlinks=True, database=db
        ):
            child_env = dict(
                os.environ,
                RM_PRIVATE_FIXTURE_GRANTS=",".join(map(str, grants)),
                RM_PRIVATE_NO_HARDLINK="0" if hardlinks else "1",
            )
            if wrong:
                child_env["RM_PRIVATE_WRONG_GRANT"] = ":".join(map(str, wrong))
            desc = {
                "operation": "scheduler",
                "request": {
                    "op": "workbenchBatch",
                    "command": {
                        "action": action,
                        **({} if action == "register" else {"batchID": batch}),
                        **data,
                    },
                },
            }
            child = sp.run(
                [sys.executable, here / "child.py", lib, database],
                input=json.dumps(desc),
                capture_output=True,
                text=True,
                pass_fds=opened,
                env=child_env,
                check=True,
            )
            reply = json.loads(child.stdout)
            decisions = [json.loads(x) for x in child.stderr.splitlines() if x]
            events.append(
                {"action": action, "code": reply["status"], "guards": decisions}
            )
            if reply["status"] != expected:
                raise AssertionError(
                    (name, action, reply["reply"].get("error"), decisions)
                )
            if expected:
                assert any(not c["allowed"] for c in decisions)
            return reply["reply"]

        def clone(role):
            i = {"main": 0, "wal": 1, "shm": 2}[role]
            file = paths[i]
            duplicate = d / ("alternate-" + role)
            shutil.copyfile(file, duplicate)
            same = sha(file)
            assert (
                sha(duplicate) == same and file.stat().st_ino != duplicate.stat().st_ino
            )
            record["wrongReference"] = {
                "role": role,
                "sameSHA256BeforeRequest": same,
                "bytes": duplicate.stat().st_size,
                "liveInode": file.stat().st_ino,
                "copyInode": duplicate.stat().st_ino,
            }
            return acquire(duplicate)

        caller = request(
            "register",
            {
                "manifest": helper.source(initial["library"], out, batch),
                "directory": str(out),
                "leaseMs": 120000,
            },
        )
        args = {"ordinal": 1, "generation": 1, "token": caller["token"]}
        args["itemToken"] = request("claimItem", {**args, "leaseMs": 120000})[
            "itemToken"
        ]
        folder = out / (".rawmaster-export-" + str(uuid.uuid4()))
        folder.mkdir()
        stage = folder / "pixels.jpg"
        shutil.copyfile(helper.IMAGE, stage)
        frozen_inode = stage.stat().st_ino
        expected_sha = sha(stage)
        prep = {
            **args,
            "directory": str(out),
            "stage": str(stage.relative_to(out)),
            "suffix": 1,
        }
        if bad == "prepare":
            wrong = clone(role)
            request("prepareItem", prep, wrong=(bad, role, wrong), expected=1)
            prior = line("ticket")
            assert (
                prior == {"state": "running", "ticket": None, "reservations": 0}
                and sha(stage) == expected_sha
            )
            record["failedPrepareLeftRunningWithoutTicket"] = True
        prepared = request("prepareItem", prep)
        assert prepared["item"]["state"] == "prepared"
        first = line("ticket")
        assert first["state"] == "prepared" and first["reservations"] == 1
        final = out / prepared["item"]["filename"]
        publish_fields = {**args, "directory": str(out)}
        ack_fields = {"ordinal": 1, "directory": str(out)}
        if empty:
            assert line("truncate")["checkpointRC"] == 0
        assert (paths[1].stat().st_size == 0) == empty
        if empty:
            for size in [0, 1]:
                path = d / f"unrelated-{size}"
                path.write_bytes(b"x" * size)
                extra.append(acquire(path))
            record["unrelatedDescriptors"] = [
                {"bytes": os.fstat(f).st_size, "inode": os.fstat(f).st_ino}
                for f in extra
            ]
        if bad in ["write", "link", "rename"]:
            wrong = clone(role)
            request(
                "publishItem",
                publish_fields,
                wrong=(bad, role, wrong),
                expected=1,
                hardlinks=not rename,
            )
            assert (
                not final.exists()
                and sha(stage) == expected_sha
                and line("ticket") == first
            )
            record["denialPreservedOriginalTicketStageAndVacantFinal"] = True
        if bad == "peer":
            # Entire valid v10 byte copies coexist under separate directory grants; original names are untouched.
            peer = d / "different-catalog"
            peer.mkdir()
            peers = [peer / p.name for p in paths]
            for a, b in zip(paths, peers):
                shutil.copyfile(a, b)
            record["sameBytePeer"] = [
                {
                    "sha256": sha(a),
                    "differentInode": a.stat().st_ino != b.stat().st_ino,
                    "bytes": a.stat().st_size,
                }
                for a, b in zip(paths, peers)
            ]
            assert all(sha(a) == sha(b) for a, b in zip(paths, peers)) and all(
                x["differentInode"] for x in record["sameBytePeer"]
            )
            peer_keeper = sqlite3.connect(str(peers[0]))
            assert peer_keeper.execute("PRAGMA user_version").fetchone()[0] == 10
            try:
                request("publishItem", publish_fields, expected=1, database=peers[0])
                hit = events[-1]["guards"][-1]
                assert (
                    all(
                        actual != authorized
                        for actual, authorized in zip(hit["attached"], hit["grants"])
                    )
                    and hit["grants"] == hit["names"]
                )
                assert (
                    peer_keeper.execute(
                        "SELECT json_extract(value,'$.state') FROM lc_meta WHERE key GLOB 'wb032.item.v1/*'"
                    ).fetchone()[0]
                    == "prepared"
                )
            finally:
                peer_keeper.close()
            assert (
                not final.exists()
                and sha(stage) == expected_sha
                and line("ticket") == first
            )
            record["denialPreservedOriginalTicketStageAndVacantFinal"] = True
        success = request("publishItem", publish_fields, hardlinks=not rename)
        assert success["status"] == "published"
        assert (
            sha(final) == expected_sha
            and final.stat().st_ino == frozen_inode
            and (not stage.exists()) == rename
        )
        success_checks = events[-1]["guards"]
        assert [c["phase"] for c in success_checks] == (
            ["read", "write", "link", "rename"] if rename else ["read", "write", "link"]
        ) and all(c["allowed"] for c in success_checks)
        assert (success_checks[-1]["walBytes"] == 0) == empty
        assert line("ticket") == first
        if bad == "ack":
            wrong = clone(role)
            request(
                "acknowledgeItem", ack_fields, expected=1, wrong=("ack", role, wrong)
            )
            assert (
                line("ticket") == first
                and stage.exists()
                and sha(final) == expected_sha
            )
            record["deniedAckPreservedPreparedStageAndVerifiedFinal"] = True
        for attempt in [1, 2]:
            assert request("acknowledgeItem", ack_fields)["status"] == "delivered"
        end = line("ticket")
        assert (
            end["state"] == "delivered"
            and end["reservations"] == 0
            and end["ticket"] == first["ticket"]
            and not stage.exists()
            and sha(final) == expected_sha
        )
        record.update(
            finalSHA256=expected_sha,
            finalBytes=final.stat().st_size,
            sameStageFinalInode=True,
            delivered=True,
            idempotentAcknowledgement=True,
        )
        return record
    finally:
        for fd in opened:
            os.close(fd)
        if keeper.poll() is None:
            keeper.stdin.write("finish\n")
            keeper.stdin.flush()
            assert keeper.wait(timeout=10) == 0


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--build-dir", required=True, type=Path)
    ap.add_argument("--image-digest")
    ap.add_argument("--case", choices=[p[0] for p in policies])
    ap.add_argument("--out", required=True, type=Path)
    args = ap.parse_args()
    if (
        not __debug__
        or not sys.platform.startswith("linux")
        or os.uname().machine != "aarch64"
    ):
        raise SystemExit(
            "This fixture requires Linux arm64 with Python assertions enabled."
        )
    directory = args.build_dir.resolve()
    args.out = args.out.resolve()
    if (
        (
            directory.is_relative_to(repo)
            and not directory.is_relative_to(repo / "output")
        )
        or args.out.exists()
        or not args.out.is_relative_to(directory)
    ):
        raise SystemExit(
            "Use a dedicated output directory and a fresh receipt name inside it."
        )
    staged, keeper_binary, lib = build(repo, directory)
    cases = [p for p in policies if not args.case or args.case == p[0]]
    data = {
        "sqlite": "3.53.2",
        "productionBinary": False,
        "originalQueueAndStagePublish": True,
        "imageDigest": args.image_digest,
        "kernel": os.uname().release,
        "keeperSHA256": sha(keeper_binary),
        "compatibility": "isolated Linux bundle with SQLITE_ENABLE_FILESTAT and copied Rust guards at real transaction/fence entry",
        "runtimeSHA256": sha(lib),
        "sourceSHA256": {
            (
                str(p.relative_to(repo))
                if p.is_relative_to(repo)
                else str(p.relative_to(staged))
            ): sha(p)
            for p in [
                here / "guard.rs",
                here / "build.py",
                here / "child.py",
                here / "keeper.rs",
                Path(__file__),
                arch,
                repo / "Modules/LibraryCatalog/src/scheduler/batch/items.rs",
                repo / "Modules/LibraryCatalog/src/scheduler/batch/directory.rs",
                staged / "src/scheduler/batch/items.rs",
                staged / "src/scheduler/batch/directory.rs",
                staged / "Cargo.lock",
            ]
        },
        "cases": [],
    }
    with tempfile.TemporaryDirectory(dir="/tmp") as d:
        for case in cases:
            print("running", case[0], flush=True)
            data["cases"].append(run(Path(d) / case[0], case, keeper_binary, lib))
            print("pass", case[0], flush=True)
    with args.out.open("x") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    print("sha", sha(args.out), flush=True)
