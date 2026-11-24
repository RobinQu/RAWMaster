"""Generated v10 catalog and signed-worker admission/receipt verification."""

import argparse
import errno
import hashlib
import json
import os
import importlib.util
from pathlib import Path
import shutil
import subprocess as sp
import tempfile
import uuid
from broker import ARCH, Broker, X, Q

spec = importlib.util.spec_from_file_location(
    "mac_cold_owner", ARCH / "bootstrap/supervisor.py"
)
Y = importlib.util.module_from_spec(spec)
spec.loader.exec_module(Y)


def make_files(c):
    for name, content in [
        ("withheld.bin", b"unrelated catalog note"),
        ("rename-source.bin", b"unrelated rename guard"),
    ]:
        (c.path / name).write_bytes(content)
    (c.path.parent / "sibling.bin").write_bytes(b"unrelated sibling content")


def req(b, action, body, scope="delivery", expected=True):
    c = b.catalog
    cmd = {
        "action": action,
        **({} if action == "register" else {"batchID": c.batch}),
        **body,
    }
    env = {
        "operation": "scheduler",
        "request": {"op": "workbenchBatch", "command": cmd},
    }
    answer = b.call("queue", write=scope, payload=env)
    assert (answer["status"] == 0) == expected, (
        action,
        answer["status"],
        answer.get("answer", {}).get("error"),
        b.results[-1]["phases"],
        b.results[-1]["attachmentDiagnostics"],
    )
    return answer["answer"]


def verify_denials(c, b):
    make_files(c)
    original = {
        str(p): X.sha(p)
        for p in [
            c.path / "withheld.bin",
            c.path / "rename-source.bin",
            c.path.parent / "sibling.bin",
        ]
    }
    blocked = b.call("permission")
    assert blocked.pop("authorizedSQLiteHeaderRead") == 1
    assert (
        all(n in (errno.EACCES, errno.EPERM) for n in blocked.values())
        and len(blocked) == 5
    ), blocked
    assert all(X.sha(p) == digest for p, digest in original.items())
    assert (
        not (c.path / "probe-create.bin").exists()
        and not (c.path / "rename-destination.bin").exists()
    )
    unconfined = b.call("permission", sandbox=False)
    assert unconfined.pop("authorizedSQLiteHeaderRead") == 1 and all(
        n == 0 for n in unconfined.values()
    ), unconfined
    assert (
        X.sha(c.path / "rename-destination.bin")
        == original[str(c.path / "rename-source.bin")]
        and (c.path / "probe-create.bin").exists()
    )
    # This single-UID positive control used only its own generated names.
    (c.path / "rename-destination.bin").rename(c.path / "rename-source.bin")
    (c.path / "probe-create.bin").unlink()
    assert all(X.sha(p) == digest for p, digest in original.items())
    alt = b.call("permission", signed="other-worker", write="identity")
    e = b.results[-1]
    v = e["connection"]
    assert (
        alt["ungrantedMainReadErrno"] in (errno.EACCES, errno.EPERM)
        and e["staticExactRequirementExit"] != 0
        and alt["receivedCapability"] == 0
        and v["expectedIdentifierMatched"]
        and v["baseDynamicSignatureStatus"] == 0
        and v["expectedPIDMatched"]
        and v["exactDynamicRequirementStatus"] != 0
    )
    assert (
        v["observedCDHash"] == b.pins["other-worker"]["CDHash"]
        and not e["fileDescriptorsSent"]
    )
    wrong = b.call("permission", mismatched_pid=True, write="identity")
    e = b.results[-1]
    assert (
        wrong["receivedCapability"] is False
        and e["connection"]["exactDynamicRequirementStatus"] == 0
        and not e["connection"]["expectedPIDMatched"]
        and not e["fileDescriptorsSent"]
    )
    revoked = b.call("permission", authority=False, write="identity")
    e = b.results[-1]
    assert (
        revoked["receivedCapability"] is False
        and e["connection"]["signedPeerAllowed"]
        and not e["fileDescriptorsSent"]
        and not e["appSentCommand"]
    )
    return {
        "actualSeatbeltErrnos": blocked,
        "sameUIDWithoutSeatbeltControl": unconfined,
        "untouchedSentinels": original,
    }


def delivery(c, b, denied, missing_volume=False, cold=False):
    parent = req(
        b,
        "register",
        {
            "manifest": Q.source(c.origin["library"], c.out, c.batch),
            "directory": str(c.out),
            "leaseMs": 120000,
        },
    )
    own = {"ordinal": 1, "generation": 1, "token": parent["token"]}
    missingVolume = None
    if missing_volume:
        sql = "SELECT count(*) FROM lc_meta WHERE key GLOB 'wb032.item.v1/*'"
        count = lambda: sp.check_output(
            ["/usr/bin/sqlite3", "-readonly", c.db, sql], text=True
        ).strip()
        before = count()
        req(
            b,
            "claimItem",
            {**own, "leaseMs": 120000},
            scope="no-volume",
            expected=False,
        )
        diag = b.results[-1]["attachmentDiagnostics"]
        assert (
            before == count() == "0"
            and len(diag) == 1
            and diag[0]["attachmentDiagnostic"] == "volumeAttributes"
            and diag[0]["errno"] == errno.EPERM
            and not any(c.out.iterdir())
        )
        missingVolume = {
            "failure": diag[0],
            "itemRowsBeforeAndAfter": 0,
            "destinationStayedEmpty": True,
        }
    own["itemToken"] = req(b, "claimItem", {**own, "leaseMs": 120000})["itemToken"]
    stage_dir = c.out / (".rawmaster-export-" + str(uuid.uuid4()))
    stage_dir.mkdir()
    stage = stage_dir / "pixels.jpg"
    shutil.copyfile(Q.IMAGE, stage)
    origin = stage.stat().st_ino
    expected = X.sha(stage)
    receipt = req(
        b,
        "prepareItem",
        {
            **own,
            "directory": str(c.out),
            "stage": str(stage.relative_to(c.out)),
            "suffix": 1,
        },
    )
    final = c.out / receipt["item"]["filename"]
    ticket = X.command(c.keeper, "ticket")
    assert (
        ticket["state"] == "prepared"
        and ticket["reservations"] == 1
        and not final.exists()
    )
    if cold:
        cold_context = two_generations(c, b, ticket)
    else:
        cold_context = None
        checkpoint = X.command(c.keeper, "truncate")
        assert checkpoint == {"checkpointRC": 0, "log": 0, "done": 0}
    publish = {**own, "directory": str(c.out)}
    ack = {"ordinal": 1, "directory": str(c.out)}
    physical = []
    if denied:
        req(b, "publishItem", publish, scope="catalog", expected=False)
        physical = b.results[-1]["publicationDiagnostics"]
        assert physical == [
            {"publicationSyscall": "linkat", "errno": errno.EPERM},
            {"publicationSyscall": "renameatx_np(RENAME_EXCL)", "errno": errno.EPERM},
        ], physical
        assert (
            not final.exists()
            and stage.stat().st_ino == origin
            and X.sha(stage) == expected
            and X.command(c.keeper, "ticket") == ticket
        )
    assert (
        req(b, "publishItem", publish)["status"] == "published"
        and final.stat().st_ino == origin
        and X.sha(final) == expected
        and X.command(c.keeper, "ticket") == ticket
    )
    proof1 = req(b, "acknowledgeItem", ack)
    proof2 = req(b, "acknowledgeItem", ack)
    end = X.command(c.keeper, "ticket")
    assert (
        proof1 == proof2
        and proof1["status"] == "delivered"
        and end["state"] == "delivered"
        and end["ticket"] == ticket["ticket"]
        and end["reservations"] == 0
        and not stage.exists()
    )
    verify = sp.check_output(
        [
            "/usr/bin/sqlite3",
            "-readonly",
            c.db,
            "SELECT quick_check FROM pragma_quick_check; SELECT count(*) FROM pragma_foreign_key_check; SELECT count(*) FROM lc_workbench_names",
        ],
        text=True,
    ).splitlines()
    assert verify == ["ok", "0", "0"]
    return {
        "actualOriginalInode": True,
        "bytes": final.stat().st_size,
        "sha256": expected,
        "stableOriginalTicketAndTwoACKs": True,
        "independentAppleIntegrity": verify,
        "refusedOutputWritePreservedPreparedTicket": denied,
        "refusedPhysicalCalls": physical,
        "missingMountMetadata": missingVolume,
        "cold": cold_context,
    }


def two_generations(c, b, ticket):
    retiring = []
    old_generation = c.epoch
    absent = b.call(
        "permission",
        write="identity",
        expected_epoch=old_generation,
        after_peer_check=lambda: retiring.append(c.retire(ticket)),
    )
    checkpoint, retired = retiring[0]
    try:
        assert all(not (c.path / n).exists() for n in X.NAMES[1:]) and all(
            os.fstat(fd).st_nlink == 0 for fd in retired
        )
        assert (
            absent == {"receivedCapability": False}
            and b.results[-1]["fileDescriptorsSent"] == 0
            and not b.results[-1]["issuerActive"]
        )
        assert (
            b.results[-1]["connection"]["signedPeerAllowed"]
            and b.results[-1]["issuerActiveAtLaunch"]
            and b.results[-1]["issuerEpochAtLaunch"] == old_generation
            and b.results[-1]["issuerEpoch"] == old_generation + 1
        )
        sql = "SELECT json_extract(value,'$.ticket') FROM lc_meta WHERE key GLOB 'wb032.item.v1/*'"
        from_main = json.loads(
            sp.check_output(
                [
                    "/usr/bin/sqlite3",
                    "-readonly",
                    c.db.as_uri() + "?mode=ro&immutable=1",
                    sql,
                ],
                text=True,
            )
        )
        assert from_main == ticket["ticket"] and all(
            not (c.path / n).exists() for n in X.NAMES[1:]
        )
        c.begin()
        c.release()
        old = b.call("permission", expected_epoch=1)
        assert (
            old == {"receivedCapability": False}
            and b.results[-1]["fileDescriptorsSent"] == 0
            and b.results[-1]["issuerEpoch"] == 2
        )
        assert X.command(c.keeper, "ticket") == ticket
        return {
            "initialMissingAfterNativeClose": c.origin_close,
            "newlyAttestedGenerations": c.reports,
            "retiredCheckpoint": checkpoint,
            "receiptReadFromMainWithSidecarNamesAbsent": True,
            "authorityRetiredAfterPeerIdentityCheckBeforeAnyCapabilitiesOrCommand": True,
            "noCapabilitiesDuringGap": True,
            "retiredGenerationReceivedNoCapabilities": True,
        }
    finally:
        Y.closeall(retired)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--build-dir", type=Path, required=True)
    p.add_argument("--interop-build", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--bootstrap-build", type=Path, required=True)
    p.add_argument("--runtime", type=Path, default=X.RUNTIME)
    p.add_argument(
        "--case",
        choices=(
            "permissions",
            "clean-delivery",
            "refused-delivery",
            "refused-attachment-metadata",
            "signed-cold-recreation",
        ),
    )
    args = p.parse_args()
    bins = args.build_dir.resolve()
    inside = args.interop_build.resolve()
    rt = args.runtime.resolve()
    report = {
        "signedPrograms": json.loads((bins / "signed-programs.json").read_text()),
        "runtimeSHA256": X.sha(rt),
        "cases": [],
    }
    with tempfile.TemporaryDirectory(prefix="authority-", dir=bins) as tmp:
        parent = Path(tmp)
        for name in (
            [args.case]
            if args.case
            else (
                "permissions",
                "clean-delivery",
                "refused-delivery",
                "refused-attachment-metadata",
                "signed-cold-recreation",
            )
        ):
            case = parent / name
            case.mkdir(mode=0o700)
            cold = name == "signed-cold-recreation"
            c = (
                Y.Owner(
                    case / "catalog",
                    inside,
                    rt,
                    args.bootstrap_build.resolve() / "apfs-owner-keeper",
                )
                if cold
                else X.Catalog(case / "catalog", inside, rt)
            )
            if cold:
                c.begin()
                c.release()
            b = Broker(c, bins)
            try:
                evidence = (
                    verify_denials(c, b)
                    if name == "permissions"
                    else delivery(
                        c,
                        b,
                        name == "refused-delivery",
                        name == "refused-attachment-metadata",
                        cold,
                    )
                )
                report["cases"].append(
                    {"case": name, "evidence": evidence, "requests": b.results}
                )
                args.output.write_text(json.dumps(report, indent=2) + "\n")
                print("passed", name, flush=True)
            finally:
                c.close()


if __name__ == "__main__":
    main()
