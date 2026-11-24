"""Use only a generated fixture's inherited private channel to validate defensive framing."""

import array
import errno
import json
import os
import socket
from broker import REQ, RESP

s = socket.socket(fileno=int(os.environ["RM_OWNER_FD"]))
n = int(os.environ["RM_OWNER_NONCE"])
control = os.open("/dev/null", os.O_RDONLY | os.O_CLOEXEC)


def denied(nonce, op, send=()):
    ancillary = (
        []
        if not send
        else [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", send))]
    )
    s.sendmsg(
        [REQ.pack(nonce, op, os.O_RDWR | os.O_NOFOLLOW | os.O_CREAT, 0o600, 0)],
        ancillary,
    )
    data, rights, flags, _ = s.recvmsg(RESP.size, socket.CMSG_SPACE(4))
    (code,) = RESP.unpack(data)
    assert not rights and not flags and code in (errno.EPROTO, errno.EPERM)
    return code


try:
    print(
        json.dumps(
            [denied(n ^ 1, 1), denied(n, 3), denied(n, 1, (control,)), denied(n, 4, ())]
        )
    )
finally:
    os.close(control)
