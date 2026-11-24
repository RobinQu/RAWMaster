#!/usr/bin/env python3
"""Replay workbench delivery transactions against the packaged macOS SQLite runtime."""

import argparse
import ctypes
import hashlib
import json
import os
import platform
import shutil
import socket
import subprocess
import tempfile
import uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = next(
    p for p in HERE.parents if (p / "Modules/LibraryCatalog/Cargo.toml").exists()
)
LIB = (
    ROOT
    / ".build/release/LibraryCatalog_RAWMasterLibrary.bundle/Contents/Resources/rawmaster-library.runtime"
)
VFS = ROOT / "experiments/portable-processing/catalog/attachment-probe/passive-vfs"
DDL = ROOT / "Modules/LibraryCatalog/src/authority/legacy_v7_reference.sql"
IMAGE = ROOT / "docs/research/camera-raw-parity/assets/history-proxy.jpg"
IDS = ctypes.c_uint64 * 4
CASES = {
    "passive-live": ("passive", False, None, False),
    "mapped-live": ("map", False, None, True),
    "empty-native": ("map", True, None, False),
    "empty-strict": ("map", True, None, True),
    "empty-extra-zero": ("map", True, 0, True),
    "empty-extra-one": ("map", True, 1, True),
    "wal-copy-return": ("map", False, None, True),
    "shm-copy-return": ("map", False, None, True),
    "empty-copy-return": ("map", True, 0, True),
}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def build(build_dir):
    base = [
        "/usr/bin/clang",
        "-std=c11",
        "-D_DARWIN_C_SOURCE",
        "-O1",
        "-Wall",
        "-Wextra",
        "-Werror",
        "-I",
        str(ROOT / "Modules/LibraryCatalog/include"),
        "-I",
        str(VFS),
    ]
    subprocess.run(
        base + [HERE / "keeper.c", "-lsqlite3", "-o", build_dir / "keeper"], check=True
    )
    subprocess.run(
        base + [HERE / "observe.c", "-lsqlite3", "-lproc", "-o", build_dir / "observe"],
        check=True,
    )
    subprocess.run(
        base
        + [
            "-dynamiclib",
            VFS / "inspector.c",
            "-lproc",
            "-o",
            build_dir / "inspector.dylib",
        ],
        check=True,
    )


def source(library, target, batch):
    src = {
        "assetID": "asset-a",
        "projectID": "p",
        "contentSHA256": sha(IMAGE),
        "byteCount": IMAGE.stat().st_size,
        "admissionFingerprint": "fixture",
        "sourceLocation": "file:///fixture/source.jpg",
    }
    return {
        "schema": 1,
        "batchID": batch,
        "libraryID": library,
        "sourceContext": {"kind": "editor", "title": "fixture"},
        "destination": {"grantID": "fixture-local", "pathHint": str(target)},
        "namingTemplate": "{name}",
        "collision": "rename",
        "configuration": {"format": "jpeg8", "jpegQuality": 0.9},
        "items": [
            {
                "ordinal": 1,
                "assetID": "asset-a",
                "stem": "fixture",
                "work": {"id": "work-a", "source": src},
                "version": {
                    "id": "version-a",
                    "workID": "work-a",
                    "source": src,
                    "recipe": {"exposureEV": 0.0},
                },
            }
        ],
    }


def read_result(p):
    line = p.stdout.readline()
    if not line:
        raise RuntimeError(f"fixture bootstrap failed: {p.stderr.read()}")
    return json.loads(line)


def normalize(item):
    return {
        k: item.get(k) for k in ["ordinal", "state", "filename", "reason", "finished"]
    }


def case(name, d, build_dir, runtime):
    arm, empty, extra, enforce = CASES[name]
    api = ctypes.CDLL(str(build_dir / "inspector.dylib"))
    api.inspect_pin.argtypes = [ctypes.c_int, ctypes.POINTER(IDS)]

    def key(fd):
        a = IDS()
        assert api.inspect_pin(fd, ctypes.byref(a)) == 1
        return ":".join(str(x) for x in a)

    db = d / "catalog.sqlite"
    out = d / "delivery"
    out.mkdir()
    k = subprocess.Popen(
        [build_dir / "keeper", runtime, db, DDL],
        text=True,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    history = []
    pins = []
    swap_record = {}
    physical_receipts = {}
    swap_role = {
        "wal-copy-return": "wal",
        "empty-copy-return": "wal",
        "shm-copy-return": "shm",
    }.get(name)
    try:
        initial = read_result(k)
        assert initial["version"] == 10 and initial["abiIdentityMatches"]
        for f in [db, Path(str(db) + "-wal"), Path(str(db) + "-shm")]:
            pins.append(os.open(f, os.O_RDONLY | os.O_NOFOLLOW))
        names = [key(x) for x in pins]
        batch = str(uuid.uuid4())
        expected_sha = sha(IMAGE)

        def independent(phase):
            k.stdin.write("ticket\n")
            k.stdin.flush()
            entry = read_result(k)
            t = entry.pop("ticket")
            entry["immutableTicketSHA256"] = hashlib.sha256(
                json.dumps(t, sort_keys=True, separators=(",", ":")).encode()
            ).hexdigest()
            entry["fileSHA256"] = t["sha256"]
            entry["byteCount"] = t["byteCount"]
            entry["filename"] = t["filename"]
            assert (
                entry["fileSHA256"] == expected_sha
                and entry["byteCount"] == IMAGE.stat().st_size
            )
            physical_receipts[phase] = entry
            return entry

        def execute(args, wire, exchange):
            if not exchange:
                return subprocess.run(args, input=wire, text=True, capture_output=True)
            current = Path(str(db) + "-" + exchange)
            peer = d / ("held-peer-" + exchange)
            immutable_main = sha(db)
            original_wal_hash = sha(Path(str(db) + "-wal"))
            shutil.copyfile(current, peer)
            initial_hash = sha(current)
            assert initial_hash == sha(peer)
            peer_fd = os.open(peer, os.O_RDONLY | os.O_NOFOLLOW)
            try:
                peer_id = [int(v) for v in key(peer_fd).split(":")]
            finally:
                os.close(peer_fd)
            role_index = 1 if exchange == "wal" else 2
            original_id = [int(v) for v in names[role_index].split(":")]
            assert peer_id != original_id
            api.exchange_files.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
            swapped = False

            def toggle():
                nonlocal swapped
                assert api.exchange_files(os.fsencode(current), os.fsencode(peer)) == 0
                swapped = not swapped

            controller, child = socket.socketpair()
            controller.settimeout(8)
            toggle()
            proc = None

            def current_id():
                fd = os.open(current, os.O_RDONLY | os.O_NOFOLLOW)
                try:
                    return [int(v) for v in key(fd).split(":")]
                finally:
                    os.close(fd)

            try:
                proc = subprocess.Popen(
                    args,
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    pass_fds=(child.fileno(),),
                    env={**os.environ, "RM_V10_STUDY_PIPE": str(child.fileno())},
                )
                child.close()
                proc.stdin.write(wire)
                proc.stdin.close()
                proc.stdin = None
                for phase in (b"O", b"C"):
                    seen = controller.recv(1)
                    if seen != phase:
                        raise RuntimeError(
                            "missing controlled observation/rollback barrier"
                        )
                    toggle()
                    assert current_id() == (original_id if phase == b"O" else peer_id)
                    controller.sendall(b"x")
                stdout, stderr = proc.communicate(timeout=8)
                assert swapped
                toggle()
                assert current_id() == original_id
                assert (
                    sha(db) == immutable_main
                    and sha(Path(str(db) + "-wal")) == original_wal_hash
                )
                if exchange == "wal":
                    assert sha(peer) == initial_hash
                swap_record.update(
                    afterCloseOriginalSHA256=sha(current),
                    afterCloseCopySHA256=sha(peer),
                    mainBytesUnchanged=True,
                    originalWalBytesUnchanged=True,
                    role=exchange,
                    byteIdenticalInitially=True,
                    initialSHA256=initial_hash,
                    original=original_id,
                    copy=peer_id,
                    originalNameDuringContext=True,
                    openedSetRestoredBeforeInterrupt=True,
                    originalRestoredAfterClose=True,
                )
                return subprocess.CompletedProcess(
                    args, proc.returncode, stdout, stderr
                )
            finally:
                if proc and proc.poll() is None:
                    proc.kill()
                    proc.wait()
                if swapped:
                    toggle()
                child.close()
                controller.close()

        def req(
            action,
            fields,
            *,
            expected=0,
            probe_arm=arm,
            guard=False,
            decoy=None,
            exchange=None,
        ):
            work = {
                "operation": "scheduler",
                "request": {
                    "op": "workbenchBatch",
                    "command": {
                        "action": action,
                        **({} if action == "register" else {"batchID": batch}),
                        **fields,
                    },
                },
            }
            p = execute(
                [
                    build_dir / "observe",
                    runtime,
                    db,
                    probe_arm,
                    "guard" if guard else "observe",
                    str(decoy) if decoy else "-",
                    *names,
                    action,
                ],
                json.dumps(work) + "\n",
                exchange,
            )
            if p.returncode != 0:
                raise RuntimeError(f"observer {action} exit {p.returncode}: {p.stderr}")
            answer = json.loads(p.stdout)
            observed = [json.loads(x) for x in p.stderr.splitlines()]
            closed = observed[-1]
            if answer["status"] != expected:
                raise RuntimeError(
                    f"{action} ABI status {answer['status']}: {answer['reply'].get('error', 'missing error')}"
                )
            assert (
                closed["event"] == "closed"
                and closed["identityFunctionMatches"]
                and not closed["globalSyscallHook"]
            )
            assert (
                closed["nativeConnectionOpenEvents"]
                == closed["mainClosed"]
                == closed["walClosed"]
                == 1
            ), closed
            assert (
                closed["shmUnmaps"] >= 1
                and closed["mappingInvalidated"]
                and closed["capChanges"] == closed["capRestored"]
                and closed["capErrors"] == 0
            )
            assert not any(
                e.get("nonnull") and (e["unfetchRC"] != 0 or e["released"] != 1)
                for e in observed
            )
            history.append(
                {
                    "action": action,
                    "arm": probe_arm,
                    "guard": guard,
                    "abiStatus": answer["status"],
                    "contexts": observed[:-1],
                    "lifecycle": closed,
                }
            )
            return answer["reply"]

        def states():
            items = req("items", {}, probe_arm="passive")["items"]
            assert len(items) == 1
            return normalize(items[0])

        args = {"ordinal": 1, "generation": 1}
        desc = source(initial["library"], out, batch)
        parent = req(
            "register", {"manifest": desc, "directory": str(out), "leaseMs": 120000}
        )
        args["token"] = parent["token"]
        child = req("claimItem", {**args, "leaseMs": 120000})
        args["itemToken"] = child["itemToken"]
        folder = out / (".rawmaster-export-" + str(uuid.uuid4()))
        folder.mkdir()
        stage = folder / "pixels.jpg"
        shutil.copyfile(IMAGE, stage)
        prefix = str(stage.relative_to(out))
        prepare = req(
            "prepareItem", {**args, "directory": str(out), "stage": prefix, "suffix": 1}
        )
        assert prepare["item"]["state"] == "prepared"
        first_state = states()
        assert first_state["state"] == "prepared"
        original_ticket = independent("prepared")
        assert (
            original_ticket["state"] == "prepared"
            and original_ticket["reservations"] == 1
        )
        final = out / first_state["filename"]
        assert not final.exists() and sha(stage) == expected_sha
        if empty:
            k.stdin.write("truncate\n")
            k.stdin.flush()
            ck = read_result(k)
            assert ck["checkpointRC"] == 0
        wal_before = Path(str(db) + "-wal").stat().st_size
        assert (wal_before == 0) == empty
        dummy = None
        if extra is not None:
            dummy = d / "unrelated"
            dummy.write_bytes(b"x" * extra)
        denied = enforce and (empty or bool(swap_role))
        publish = req(
            "publishItem",
            {**args, "directory": str(out)},
            expected=1 if denied else 0,
            decoy=dummy,
            guard=enforce,
            exchange=swap_role,
        )
        target_call = history[-1]
        assert any(e["state"] == 2 for e in target_call["contexts"])
        cw = next(e for e in target_call["contexts"] if e["state"] == 2)
        assert (
            cw["mainWalWrappersJoined"]
            and cw["mainScopedCandidateMatches"]
            and cw["shmLocksMatch"]
            and cw["namedWalMatchesOriginal"]
            and cw["namedShmMatchesOriginal"]
        )
        assert cw["walDeltaMatchesTrustedAndPath"] == (swap_role != "wal") and cw[
            "shmMapMatchesTrustedAndPath"
        ] == (swap_role != "shm")
        if swap_role:
            assert (
                cw["actualWalFdCandidate"] if swap_role == "wal" else cw["actualShm"]
            ) == swap_record["copy"]
            if swap_role == "wal" and not empty:
                assert cw["mappedWal"] == swap_record["copy"]
        if arm == "map":
            assert (
                target_call["lifecycle"]["originalWalMmapCap"]
                == target_call["lifecycle"]["restoredWalMmapCap"]
                == 0
            )
            assert target_call["lifecycle"]["activeWalMmapCap"] == 4096
            if not empty:
                assert (
                    cw["walKernelRegionBytes"] >= 4096
                    and cw["walFetchOffset"] == 0
                    and cw["walFetchLength"] == 1
                )
        if arm == "passive":
            assert (
                cw["fetchAttempted"] == 0
                and target_call["lifecycle"]["capChanges"] == 0
            )
        elif empty:
            assert (
                cw["fetchAttempted"] == 1
                and cw["fetchRC"] == 0
                and not cw["nonnull"]
                and not cw["directWalMappingMatches"]
            )
        else:
            assert (
                cw["nonnull"] == 1
                and cw["directWalMappingMatches"] == (swap_role != "wal")
                and cw["strongDiagnostic"] == (swap_role is None)
            )
        if extra is not None:
            assert (
                cw["sizeClassBefore"] >= 2
                and not cw["uniqueSizeInferenceOnly"]
                and cw["sameSizeMethodAsCanary"]
            )
            assert (
                target_call["lifecycle"]["decoyNativeFileSize"] == 0
                and target_call["lifecycle"]["decoyPhysicalBytes"] == extra
            )
            assert dummy.read_bytes() == b"x" * extra
        if empty and extra is None:
            assert cw["sizeClassBefore"] == 1 and cw["uniqueSizeInferenceOnly"]
        if denied:
            assert (
                target_call["lifecycle"]["progressInterrupts"] == 1
                and not final.exists()
                and stage.is_file()
                and sha(stage) == expected_sha
            )
            rejected_state = states()
            assert (
                first_state == rejected_state
                and independent("afterRefusal") == original_ticket
            )
            # A genuine owner heartbeat produces a nonempty WAL; use the same immutable PREPARED ticket.
            req("renewItem", {**args, "leaseMs": 120000}, probe_arm="passive")
            assert Path(str(db) + "-wal").stat().st_size > 0
            again = req(
                "publishItem",
                {**args, "directory": str(out)},
                probe_arm="map",
                guard=True,
            )
            assert again["status"] == "published"
        else:
            rejected_state = None
            assert publish["status"] == "published"
        published = {
            "stageStillExists": stage.is_file(),
            "finalSHA256": sha(final),
            "sameInode": stage.exists() and stage.stat().st_ino == final.stat().st_ino,
        }
        assert published == {
            "stageStillExists": True,
            "finalSHA256": expected_sha,
            "sameInode": True,
        }
        after_publish = states()
        assert (
            after_publish["state"] == "prepared"
            and independent("afterPublish") == original_ticket
        )
        ack = req("acknowledgeItem", {"ordinal": 1, "directory": str(out)})
        assert ack["status"] == "delivered"
        after_ack = states()
        assert (
            after_ack["state"] == "delivered"
            and not stage.exists()
            and sha(final) == expected_sha
        )
        ack_ticket = independent("afterAck")
        assert (
            ack_ticket["state"] == "delivered"
            and ack_ticket["reservations"] == 0
            and ack_ticket["immutableTicketSHA256"]
            == original_ticket["immutableTicketSHA256"]
        )
        again = req("acknowledgeItem", {"ordinal": 1, "directory": str(out)})
        assert (
            again["status"] == "delivered" and independent("repeatedAck") == ack_ticket
        )
        return {
            "case": name,
            "version": initial["version"],
            "sameSQLiteFunction": initial["abiIdentityMatches"],
            "sourceID": initial["sourceID"],
            "initialWalBytesAtPublish": wal_before,
            "decoyPhysicalBytes": extra,
            "guardedRefusal": denied,
            "independentSQL": physical_receipts,
            "swap": swap_record or None,
            "initialPrepared": first_state,
            "afterRefusal": rejected_state,
            "afterPublish": after_publish,
            "afterAck": after_ack,
            "publication": published,
            "stageRemovedAfterAck": not stage.exists(),
            "repeatedAck": "delivered",
            "targetContext": cw,
            "calls": history,
        }
    finally:
        for f in pins:
            os.close(f)
        if k.poll() is None:
            k.stdin.write("finish\n")
            k.stdin.flush()
        k.wait(timeout=5)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--only", nargs="+", choices=CASES, default=list(CASES))
    p.add_argument(
        "--build-dir",
        type=Path,
        required=True,
        help="Worktree output directory for tools and temporary catalogs",
    )
    p.add_argument(
        "--output",
        type=Path,
        required=True,
        help="JSON receipt under the worktree output directory",
    )
    p.add_argument(
        "--runtime",
        type=Path,
        default=LIB,
        help="Packaged rawmaster-library.runtime to exercise",
    )
    p.add_argument("--no-build", action="store_true")
    a = p.parse_args()
    if not __debug__:
        p.error("Use Python without -O so that replay checks run")
    build_dir = a.build_dir.resolve()
    output = a.output.resolve()
    output_root = (ROOT / "output").resolve()
    if output_root not in build_dir.parents or output_root not in output.parents:
        p.error("--build-dir and --output must be below the worktree output directory")
    runtime = a.runtime.resolve(strict=True)
    build_dir.mkdir(parents=True, exist_ok=True)
    output.parent.mkdir(parents=True, exist_ok=True)
    if not a.no_build:
        build(build_dir)
    records = {
        "macOS": platform.mac_ver()[0],
        "arch": platform.machine(),
        "runtimeSHA256": sha(runtime),
        "imageSourceSHA256": sha(IMAGE),
        "cases": [],
    }
    for name in a.only:
        with tempfile.TemporaryDirectory(prefix="rm-actual-v10-", dir=build_dir) as t:
            rec = case(name, Path(t).resolve(), build_dir, runtime)
            records["cases"].append(rec)

            print(
                name,
                "passed",
                rec["initialWalBytesAtPublish"],
                rec["targetContext"]["sizeClassBefore"],
                rec["guardedRefusal"],
                flush=True,
            )
    with tempfile.NamedTemporaryFile(
        mode="w", dir=output.parent, delete=False
    ) as receipt:
        receipt.write(json.dumps(records, indent=2) + "\n")
        candidate = Path(receipt.name)
    candidate.replace(output)


if __name__ == "__main__":
    main()
