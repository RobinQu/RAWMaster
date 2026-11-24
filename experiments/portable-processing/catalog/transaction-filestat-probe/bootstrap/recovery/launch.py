"""A new process parked without catalog FDs until its authenticated worker record is durable."""

import array
import ctypes
import fcntl
import os
import resource
import runpy
import signal
import socket
import sys

gate = socket.socket(fileno=int(sys.argv[1]))
kind = sys.argv[2]
args = sys.argv[3:]
p = int(os.environ["RM_OWNER_PID"])
libc = ctypes.CDLL(None, use_errno=True)
assert (
    os.getppid() == p
    and libc.prctl(1, signal.SIGKILL, 0, 0, 0) == 0
    and os.getppid() == p
)
gate.settimeout(5)
gate.send(b"ready")
packet, anc, flags, _ = gate.recvmsg(
    32, socket.CMSG_SPACE(5 * array.array("i").itemsize), socket.MSG_CMSG_CLOEXEC
)
gate.close()
assert packet.decode() == os.environ["RM_OWNER_NONCE"] and not flags & (
    socket.MSG_TRUNC | socket.MSG_CTRUNC
)
assert len(anc) == 1 and anc[0][:2] == (socket.SOL_SOCKET, socket.SCM_RIGHTS)
fds = array.array("i")
fds.frombytes(anc[0][2])
assert len(fds) == (1 if kind == "keeper" else 5)
assert all(fcntl.fcntl(fd, fcntl.F_GETFD) & fcntl.FD_CLOEXEC for fd in fds)
os.environ["RM_OWNER_FD"] = str(fds[0])
if kind == "keeper":
    os.set_inheritable(fds[0], True)  # The Rust entry immediately sets CLOEXEC again.
    os.execv(args[0], args)
os.environ["RM_PRIVATE_FIXTURE_GRANTS"] = ",".join(map(str, fds[1:]))
if "RM_WAL_FIXTURE_LIMIT" in os.environ:
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    n = int(os.environ["RM_WAL_FIXTURE_LIMIT"])
    signal.signal(signal.SIGXFSZ, signal.SIG_DFL)
    resource.setrlimit(resource.RLIMIT_FSIZE, (n, n))
assert args[0] == sys.executable
sys.argv = args[1:]
runpy.run_path(sys.argv[0], run_name="__main__")
