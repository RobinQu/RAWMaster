"""Exercise genuine last-close sidecar deletion/recreation, then retry the same prepared work."""

import json
import os
import shutil
import subprocess as sp
import sys
import uuid
from fixtures import cases, HERE, digest


def check_epoch(directory, arm, binaries):
    directory.mkdir()
    db = directory / "library.sqlite"
    wal = directory / "library.sqlite-wal"
    shm = directory / "library.sqlite-shm"
    output = directory / "delivery"
    output.mkdir()
    bins = binaries
    artifact = bins / "librawmaster_library.so"
    fds = []
    records = []

    def keeper(reopen=False):
        p = sp.Popen(
            [
                bins / "filestat-keeper",
                db,
                cases.helper.DDL,
                *(["reopen"] if reopen else []),
            ],
            text=True,
            stdin=sp.PIPE,
            stdout=sp.PIPE,
            stderr=sp.PIPE,
        )
        state = p.stdout.readline()
        if not state:
            raise RuntimeError(p.stderr.read())
        return p, json.loads(state)

    def close(p):
        p.stdin.write("finish\n")
        p.stdin.flush()
        assert p.wait(timeout=5) == 0

    def query(command):
        k.stdin.write(command + "\n")
        k.stdin.flush()
        return json.loads(k.stdout.readline())

    def pin(path):
        f = os.open(path, os.O_PATH | os.O_NOFOLLOW)
        fds.append(f)
        return f

    def keys(descriptors):
        return [[os.fstat(n).st_dev, os.fstat(n).st_ino] for n in descriptors]

    batch = str(uuid.uuid4())
    k, first = keeper()
    grants = [pin(directory), pin(db), pin(wal), pin(shm)]

    def req(action, body, success=True, paired=False):
        data = {
            "operation": "scheduler",
            "request": {
                "op": "workbenchBatch",
                "command": {
                    "action": action,
                    **({} if action == "register" else {"batchID": batch}),
                    **body,
                },
            },
        }
        env = dict(
            os.environ,
            RM_MAP_ARM=arm,
            RM_MAP_PAIR_ACK="1" if paired else "0",
            RM_PRIVATE_FIXTURE_GRANTS=",".join(map(str, grants)),
        )
        child = sp.run(
            [sys.executable, HERE / "child.py", artifact, db],
            input=json.dumps(data),
            text=True,
            capture_output=True,
            pass_fds=fds,
            check=True,
            env=env,
        )
        answers = [json.loads(x) for x in child.stdout.splitlines()]
        assert len(answers) == (2 if paired else 1)
        reply = answers[-1]
        if paired:
            assert answers[0] == answers[1]
        events = [json.loads(x) for x in child.stderr.splitlines()]
        if paired:
            reads = [entry for entry in events if entry["phase"] == "read"]
            assert len(reads) == 2 and reads[0]["attached"] == reads[1]["attached"]
            assert reads[0]["openingGeneration"] != reads[1]["openingGeneration"]
            assert reads[0]["mappingGeneration"] != reads[1]["mappingGeneration"]
        records.append(
            {
                "action": action,
                "status": reply["status"],
                "guards": events,
                "calls": len(answers),
            }
        )
        assert (reply["status"] == 0) == success, (
            reply.get("reply", {}).get("error"),
            events,
        )
        return reply["reply"]

    try:
        parent = req(
            "register",
            {
                "manifest": cases.helper.source(first["library"], output, batch),
                "directory": str(output),
                "leaseMs": 120000,
            },
        )
        owner = {"ordinal": 1, "generation": 1, "token": parent["token"]}
        owner["itemToken"] = req("claimItem", {**owner, "leaseMs": 120000})["itemToken"]
        folder = output / (".rawmaster-export-" + str(uuid.uuid4()))
        folder.mkdir()
        stage = folder / "pixels.jpg"
        shutil.copyfile(cases.helper.IMAGE, stage)
        image = digest(stage)
        stage_inode = stage.stat().st_ino
        prepared = req(
            "prepareItem",
            {
                **owner,
                "directory": str(output),
                "stage": str(stage.relative_to(output)),
                "suffix": 1,
            },
        )
        final = output / prepared["item"]["filename"]
        ticket = query("ticket")
        assert ticket["state"] == "prepared" and ticket["reservations"] == 1
        assert query("truncate")["checkpointRC"] == 0 and wal.stat().st_size == 0
        old = keys(grants[1:])
        close(k)
        assert (
            not wal.exists()
            and not shm.exists()
            and not final.exists()
            and digest(stage) == image
        )
        k, reopened = keeper(True)
        assert first == reopened and query("ticket") == ticket
        fresh = [grants[0], grants[1], pin(wal), pin(shm)]
        current = keys(fresh[1:])
        assert old[0] == current[0] and all(
            a != b for a, b in zip(old[1:], current[1:])
        )
        assert wal.stat().st_size == 0
        req("publishItem", {**owner, "directory": str(output)}, False)
        denial = records[-1]["guards"][-1]
        assert (
            denial["phase"] == "read"
            and not denial["allowed"]
            and denial["attached"] == current
            and denial["grants"] == old
            and denial["names"] == current
        )
        assert (
            not final.exists()
            and stage.stat().st_ino == stage_inode
            and digest(stage) == image
            and query("ticket") == ticket
        )
        grants = fresh
        assert (
            req("publishItem", {**owner, "directory": str(output)})["status"]
            == "published"
        )
        assert (
            digest(final) == image
            and final.stat().st_ino == stage_inode
            and query("ticket") == ticket
        )
        assert (
            req(
                "acknowledgeItem", {"ordinal": 1, "directory": str(output)}, paired=True
            )["status"]
            == "delivered"
        )
        end = query("ticket")
        assert (
            end["state"] == "delivered"
            and end["ticket"] == ticket["ticket"]
            and end["reservations"] == 0
            and not stage.exists()
        )
        return {
            "arm": arm,
            "sqliteSourceID": first["sourceID"],
            "oldIdentity": old,
            "newIdentity": current,
            "oldSidecarsAbsentAfterLastSQLiteClose": True,
            "originalMainHeld": True,
            "samePreparedReceiptAfterReopen": True,
            "oldGrantRefusedWithStageAndVacantFinal": True,
            "newEpochPublishedSameTicket": True,
            "idempotentACK": True,
            "sameProcessReopenObservedDifferentNativeMappingGenerations": True,
            "sha256": digest(final),
            "bytes": final.stat().st_size,
            "commands": records,
        }
    finally:
        if k.poll() is None:
            close(k)
        for fd in fds:
            os.close(fd)
