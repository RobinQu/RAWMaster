"""The only processes exited by this test are its newly spawned, synthetic catalog owner and keeper."""

import array
import json
import os
from pathlib import Path
import select
import shutil
import socket
import sqlite3
import subprocess
import sys
from broker import Grant, NAMES, rights
import importlib.util

_spec = importlib.util.spec_from_file_location(
    "owner_fixtures", Path(__file__).with_name("run.py")
)
_fixtures = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_fixtures)
Catalog, digest, command = _fixtures.Catalog, _fixtures.digest, _fixtures.command


def inner(path, bins, transport_fd):
    channel = socket.socket(fileno=transport_fd)
    c = Catalog(path, bins)
    c.boot()
    c.prepare()
    assert command(c.k.proc, "checkpoint") == {"checkpointRC": 0}
    assert os.fstat(c.owner.holds[2]).st_size == 0
    ticket = command(c.k.proc, "ticket")
    assert ticket["state"] == "prepared"
    info = {
        "keeperPID": c.k.proc.pid,
        "library": c.owner.library,
        "writer": c.owner.writer,
        "stage": str(c.stage.relative_to(path)),
        "final": str(c.final.relative_to(path)),
        "ticket": ticket,
        "imageSHA": c.sha,
        "sourceID": c.sourceid,
        "commands": c.outputs,
    }
    anc = [
        (
            socket.SOL_SOCKET,
            socket.SCM_RIGHTS,
            array.array("i", [c.owner.directory, c.owner.holds[1]]),
        )
    ]
    channel.sendmsg([json.dumps(info).encode()], anc)
    assert channel.recv(16) == b"finish-owner"
    os._exit(0)  # Controlled genuine owner exit while its SQLite keeper remains live.


def study(temporary, bins):
    path = temporary / "owner-exit"
    parent, child = socket.socketpair(socket.AF_UNIX, socket.SOCK_SEQPACKET)
    p = subprocess.Popen(
        [sys.executable, __file__, str(path), str(bins), str(child.fileno())],
        pass_fds=[child.fileno()],
    )
    child.close()
    parent.settimeout(8)
    fds = []
    pidfd = None
    try:
        msg, anc, flags, _ = parent.recvmsg(
            16384,
            socket.CMSG_SPACE(2 * array.array("i").itemsize),
            socket.MSG_CMSG_CLOEXEC,
        )
        assert not flags & socket.MSG_TRUNC and not flags & socket.MSG_CTRUNC
        fds = rights(anc)
        assert len(fds) == 2
        initial = json.loads(msg)
        pidfd = os.pidfd_open(initial["keeperPID"])
        assert not select.select([pidfd], [], [], 0)[0]
        assert parent.send(b"finish-owner") == 12 and p.wait(timeout=5) == 0
        assert select.select([pidfd], [], [], 4)[
            0
        ]  # The actual live keeper exited via PR_SET_PDEATHSIG.
        # Independent expected identity comes from the original fixture over SCM_RIGHTS before exit.
        new = Grant(path, *fds, initial["library"], initial["writer"])
        fds = []
        before = {
            r: ((path / NAMES[r]).stat().st_ino, digest(path / NAMES[r]))
            for r in (1, 2, 3)
        }
        assert (path / NAMES[2]).stat().st_size == 0
        attempt = new.attach("keeper", [bins / "owner-keeper", path / NAMES[1]])
        stdout, stderr = attempt.proc.communicate(timeout=6)
        attempt.join()
        assert (
            attempt.proc.returncode != 0
            and not stdout
            and new.phase == "pending"
            and set(new.holds) == {1}
        )
        assert any(e["errno"] == 17 for e in attempt.denials)
        assert before == {
            r: ((path / NAMES[r]).stat().st_ino, digest(path / NAMES[r]))
            for r in (1, 2, 3)
        }
        assert (
            not (path / initial["final"]).exists()
            and digest(path / initial["stage"]) == initial["imageSHA"]
        )
        # Original owner explicitly checkpointed. Inspect a separate immutable copy of those main bytes.
        separate = temporary / "checkpoint-copy.sqlite"
        shutil.copyfile(path / NAMES[1], separate)
        with sqlite3.connect(separate.as_uri() + "?immutable=1", uri=True) as read:
            row = read.execute("""SELECT json_extract(value,'$.state'),json_extract(value,'$.ticket'),
                    (SELECT count(*) FROM lc_workbench_names) FROM lc_meta WHERE key GLOB 'wb032.item.v1/*'""").fetchone()
            assert row == ("prepared", initial["ticket"]["ticket"], 1)
            assert read.execute("PRAGMA quick_check").fetchone() == ("ok",)
            assert not read.execute("PRAGMA foreign_key_check").fetchall()
        new.close()
        return {
            "case": "owner-exit-unwitnessed-restart",
            "actualPreparedBeforeSupervisorExit": True,
            "pidfdObservedOriginalKeeperTermination": True,
            "originalDirectoryAndMainPassedBeforeOwnerExit": True,
            "unwitnessedZeroByteWALAndSHMRefused": True,
            "allOriginalInodesAndHashesUnaffectedByAttempt": True,
            "preparedTicketAndOneReservationFromIndependentCheckpointCopy": True,
            "vacantFinal": True,
            "preservedStageSHA256": initial["imageSHA"],
            "quickCheck": "ok",
            "foreignKeyViolations": 0,
            "denials": attempt.denials,
        }
    finally:
        parent.close()
        if p.poll() is None:
            p.kill()
            p.wait()
        if pidfd is not None:
            os.close(pidfd)
        for fd in fds:
            os.close(fd)


if __name__ == "__main__":
    inner(Path(sys.argv[1]), Path(sys.argv[2]), int(sys.argv[3]))
