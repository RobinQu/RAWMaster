"""Supervises one fixed, signed executable per request, on generated local fixtures only."""

import array
import contextlib
import errno
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import select
import socket
import subprocess as sp
import time

ROOT = next(
    p
    for p in Path(__file__).resolve().parents
    if (p / "Modules/LibraryCatalog/Cargo.toml").exists()
)
ARCH = ROOT / "experiments/portable-processing/catalog/macos-interop-probe"
q = importlib.util.spec_from_file_location("existing_mac_interop", ARCH / "run.py")
X = importlib.util.module_from_spec(q)
q.loader.exec_module(X)
Q = X.old


def rule(operation, paths):
    return (
        "(allow "
        + operation
        + " "
        + " ".join(
            "(literal " + json.dumps(str(p)) + ")" for p in sorted(map(str, set(paths)))
        )
        + ")"
    )


def profile(c, exe, write, mount):
    # Only fixed system image directories are readable for this statically linked Rust worker.
    # Workbench writes may change the three registered SQLite files and the explicitly selected delivery directory.
    names = [c.path / n for n in X.NAMES]
    statements = [
        "(version 1)",
        "(deny default)",
        '(import "dyld-support.sb")',
        "(allow mach-bootstrap)",
        "(allow syscall*)",
        rule("process-exec", [exe]),
        rule("file-read* file-map-executable", [exe]),
        '(allow file-read* file-map-executable (subpath "/System/Library") (subpath "/usr/lib"))',
        '(allow file-read* (literal "/dev/null") (literal "/dev/urandom") (literal "/dev/random"))',
        "(allow sysctl-read)",
        rule(
            "file-read-metadata",
            [
                *([mount] if write not in ("identity", "no-volume") else []),
                *exe.parents,
                *c.path.parents,
                c.path,
                c.path / "broker.sock",
            ],
        ),
        "(allow network-outbound (remote unix-socket (path-literal "
        + json.dumps(str(c.path / "broker.sock"))
        + ")))",
    ]
    if write != "identity":
        statements.extend(
            [
                rule("file-read*", [c.path, *names]),
                "(allow file-read* (subpath " + json.dumps(str(c.out)) + "))",
            ]
        )
    if write in ("catalog", "delivery", "no-volume"):
        statements.append(rule("file-write*", names))
    if write in ("delivery", "no-volume"):
        statements.append(
            "(allow file-write* (subpath " + json.dumps(str(c.out)) + "))"
        )
    return "\n".join(statements) + "\n"


@contextlib.contextmanager
def at(path):
    old = os.getcwd()
    os.chdir(path)
    try:
        yield
    finally:
        os.chdir(old)


class Broker:
    def __init__(self, c, bins):
        self.catalog = c
        self.bins = bins
        self.pins = json.loads((bins / "signed-programs.json").read_text())
        self.results = []
        self.mount = Path(
            sp.check_output(["/bin/df", "-P", c.path], text=True)
            .splitlines()[-1]
            .split(maxsplit=5)[5]
        )
        assert (
            self.mount.is_absolute()
            and self.mount.stat().st_dev == os.fstat(c.fds[0]).st_dev
        )

    def call(
        self,
        mode,
        *,
        signed="expected-worker",
        sandbox=True,
        write="none",
        authority=True,
        mismatched_pid=False,
        payload=None,
        expected_epoch=None,
        after_peer_check=None,
    ):
        c = self.catalog
        exe = self.bins / signed
        cfg = self.bins / "profiles"
        cfg.mkdir(exist_ok=True)
        pin = self.pins["expected-worker"]
        requirement = (
            f'-R=identifier "{pin["identifier"]}" and cdhash H"{pin["CDHash"]}"'
        )
        static = sp.run(
            ["/usr/bin/codesign", "--verify", "--strict", requirement, exe],
            capture_output=True,
        ).returncode

        # A fixture that fails the trusted on-disk requirement can only exercise the identity gate.
        # Under the tested service-owned code directory, it never receives catalog pathname grants.
        def issuer():
            epoch = getattr(c, "epoch", None)
            live = not hasattr(c, "phase") or (
                c.phase == "active"
                and c.keeper is not None
                and c.keeper.poll() is None
                and not c.held_writer
            )
            return epoch, live, (expected_epoch is None or epoch == expected_epoch)

        epoch0, live0, desired0 = issuer()
        epoch, live, desired = epoch0, live0, desired0
        if static != 0 or not authority or mismatched_pid or not live or not desired:
            write = "identity"
        setting = profile(c, exe, write, self.mount)
        pf = cfg / f"{c.path.name}-{signed}-{write}.sb"
        pf.write_text(setting)
        args = (
            [str(Path("/usr/bin/sandbox-exec")), "-f", str(pf)] if sandbox else []
        ) + [
            str(exe),
            mode,
            str(c.db if mode == "queue" else c.path.parent / "sibling.bin"),
        ]
        env = {
            k: v
            for k, v in os.environ.items()
            if not k.startswith(("DYLD_", "RM_MAC_"))
        }
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.settimeout(5)
        sockpath = c.path / "broker.sock"
        proc = None
        try:
            with at(c.path):
                listener.bind("broker.sock")
            listener.listen(1)
            proc = sp.Popen(
                args,
                cwd=c.path,
                env=env,
                stdin=sp.PIPE,
                stdout=sp.PIPE,
                stderr=sp.PIPE,
                text=True,
                close_fds=True,
            )
            ready = select.select([listener, proc.stdout], [], [], 5)[0]
            if listener not in ready:
                if proc.poll() is None:
                    proc.kill()
                out, err = proc.communicate(timeout=3)
                raise RuntimeError(
                    "worker did not connect: "
                    + str(proc.returncode)
                    + " "
                    + err[:400]
                    + " "
                    + out[:100]
                )
            accepted, _ = listener.accept()
            with accepted:
                expected_pid = os.getpid() if mismatched_pid else proc.pid
                verified = json.loads(
                    sp.check_output(
                        [
                            self.bins / "verify-peer",
                            str(accepted.fileno()),
                            str(expected_pid),
                            self.pins["expected-worker"]["CDHash"],
                        ],
                        pass_fds=(accepted.fileno(),),
                        text=True,
                    )
                )
                if after_peer_check is not None:
                    # The waiting peer only has identity-gate access, and no registered queue work.
                    assert (
                        write == "identity"
                        and verified["signedPeerAllowed"]
                        and authority
                        and live
                        and desired
                    )
                    after_peer_check()
                epoch, live, desired = issuer()
                grant = (
                    bool(verified["signedPeerAllowed"])
                    and static == 0
                    and authority
                    and live
                    and desired
                    and proc.poll() is None
                )
                sent = []
                narrowed = []
                copies = []
                try:
                    if grant:
                        if hasattr(c, "validate"):
                            c.validate()
                        assert len(c.fds) == 4
                        for index, current in enumerate(c.fds):
                            fd = current
                            if (
                                fcntl.fcntl(current, fcntl.F_GETFL) & os.O_ACCMODE
                                != os.O_RDONLY
                            ):
                                # Dup preserves access mode. Reopen relative to the original directory,
                                # then compare while the trusted original FD still pins its inode.
                                assert index > 0
                                fd = os.open(
                                    X.NAMES[index - 1],
                                    os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC,
                                    dir_fd=c.fds[0],
                                )
                                copies.append(fd)
                                wanted = os.fstat(current)
                                readable = os.fstat(fd)
                                assert (wanted.st_dev, wanted.st_ino) == (
                                    readable.st_dev,
                                    readable.st_ino,
                                )
                                narrowed.append(X.NAMES[index - 1])
                            sent.append(fd)
                        assert all(
                            fcntl.fcntl(fd, fcntl.F_GETFL) & os.O_ACCMODE == os.O_RDONLY
                            for fd in sent
                        )
                    anc = (
                        []
                        if not grant
                        else [
                            (
                                socket.SOL_SOCKET,
                                socket.SCM_RIGHTS,
                                array.array("i", sent),
                            )
                        ]
                    )
                    assert accepted.sendmsg([bytes([int(grant)])], anc) == 1
                finally:
                    for fd in copies:
                        os.close(fd)
            # The command (including any short-lived lease token) only leaves the owner after authorization.
            command = (
                json.dumps(payload, ensure_ascii=True)
                if grant and payload is not None
                else ""
            )
            output, error = proc.communicate(command, timeout=10)
            if proc.returncode != 0:
                raise RuntimeError(
                    "worker exit " + str(proc.returncode) + ": " + error[:1200]
                )
            public = json.loads(output)
            diagnostics = [
                json.loads(l) for l in error.splitlines() if l.startswith("{")
            ]
            phases = [event for event in diagnostics if "phase" in event]
            self.results.append(
                {
                    "mode": mode,
                    "helper": signed,
                    "seatbelt": sandbox,
                    "authorityValidAtTransfer": authority,
                    "profileGrant": write,
                    "actualAPFSMount": str(self.mount),
                    "issuerEpochAtLaunch": epoch0,
                    "issuerActiveAtLaunch": live0,
                    "issuerEpoch": epoch,
                    "requestedEpoch": expected_epoch,
                    "issuerActive": live,
                    "staticExactRequirementExit": static,
                    "connection": verified,
                    "fileDescriptorsSent": len(sent),
                    "narrowedReadOnlyRoles": narrowed,
                    "appSentCommand": bool(command),
                    "CABIStatus": public.get("status"),
                    "phases": phases,
                    "attachmentDiagnostics": [
                        event
                        for event in diagnostics
                        if "attachmentDiagnostic" in event
                    ],
                    "publicationDiagnostics": [
                        event for event in diagnostics if "publicationSyscall" in event
                    ],
                }
            )
            return public
        finally:
            if proc is not None and proc.poll() is None:
                proc.kill()
                proc.wait(timeout=4)
            listener.close()
            sockpath.unlink(missing_ok=True)
