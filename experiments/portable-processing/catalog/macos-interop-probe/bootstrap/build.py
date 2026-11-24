"""Build a single-process APFS keeper from the pinned upstream SQLite. No installed library is changed."""

import argparse
from pathlib import Path
import hashlib
import os
import shutil
import subprocess as sp

HERE = Path(__file__).resolve().parent
ROOT = next(
    p for p in HERE.parents if (p / "Modules/LibraryCatalog/Cargo.toml").is_file()
)
CAT = ROOT / "experiments/portable-processing/catalog"
V = CAT / "transaction-filestat-probe/bootstrap"
X = CAT / "macos-interop-probe"


def exact(s, old, new, count=1):
    assert s.count(old) == count, (old, s.count(old))
    return s.replace(old, new)


def system_origin(out):
    q = CAT / "queue-transaction-probe"
    code = (q / "keeper.c").read_text()
    old = "    REQUIRE(sqlite3_close(db) == SQLITE_OK);"
    addition = r"""    int previous=-1,disabled=0,verified=-1;
    REQUIRE(sqlite3_file_control(db,"main",SQLITE_FCNTL_PERSIST_WAL,&previous)==SQLITE_OK);
    REQUIRE(sqlite3_file_control(db,"main",SQLITE_FCNTL_PERSIST_WAL,&disabled)==SQLITE_OK);
    REQUIRE(sqlite3_file_control(db,"main",SQLITE_FCNTL_PERSIST_WAL,&verified)==SQLITE_OK && verified==0);
    REQUIRE(sqlite3_close(db)==SQLITE_OK);
    printf("{\"closeRC\":0,\"persistentBefore\":%d,\"persistentAfter\":%d}\n",previous,verified);
    fflush(stdout);"""
    (out / "system-origin.c").write_text(exact(code, old, addition))
    sp.run(
        [
            "xcrun",
            "clang",
            "-O0",
            "-I",
            q,
            "-I",
            ROOT / "Modules/LibraryCatalog/include",
            out / "system-origin.c",
            "-lsqlite3",
            "-o",
            out / "system-origin",
        ],
        check=True,
    )


def build(out):
    out.mkdir(exist_ok=True, parents=True)
    system_origin(out)
    cache = Path(os.environ.get("CARGO_HOME", Path.home() / ".cargo"))
    (source,) = cache.glob("registry/src/*/libsqlite3-sys-0.38.2/sqlite3/sqlite3.c")
    assert (
        hashlib.sha256(source.read_bytes()).hexdigest()
        == "0a409f1633283fa31a9126b11fbfd64a1991c5d30defad07e5745d4667f5e23d"
    )
    s = source.read_text()
    insert = "/*\n** Helper functions to obtain and relinquish the global mutex. The\n** global mutex is used to protect the unixInodeInfo objects"
    s = exact(s, insert, '#include "apfs-owner.inc"\n\n' + insert)
    s = exact(
        s,
        "fd = robust_open(zName, openFlags, openMode);",
        "fd = rm_private_db_open(zName, openFlags, openMode, eType);",
        2,
    )
    for flags in ("O_RDWR|O_CREAT|O_NOFOLLOW", "O_RDONLY|O_NOFOLLOW"):
        old = f"robust_open(zShm, {flags},\n                                     (sStat.st_mode&0777))"
        s = exact(s, old, old.replace("robust_open", "rm_private_open")[:-1] + ",3)")
    s = exact(
        s, "osUnlink(pShmNode->zFilename);", "rm_private_unlink(pShmNode->zFilename);"
    )
    s = exact(
        s, "if( osUnlink(zPath)==(-1) ){", "if( rm_private_unlink(zPath)==(-1) ){"
    )
    for var in ("pUnused", "pReadonly"):
        s = exact(
            s,
            f"{var} = findReusableFd(zName, flags);",
            f"{var} = rmSession.active ? 0 : findReusableFd(zName, flags);",
        )
    (out / "sqlite3.c").write_text(s)
    shutil.copyfile(source.with_suffix(".h"), out / "sqlite3.h")
    # Same 24-byte role/nonce protocol as the Linux archive. Darwin unix socketpair has
    # datagrams but not SEQPACKET here, and receives CLOEXEC after receipt in a no-exec worker.
    owner = (
        (V / "owner_io.inc")
        .read_text()
        .replace("#include <sys/prctl.h>", "#include <sys/un.h>")
    )
    owner = exact(
        owner,
        "if(prctl(PR_SET_PDEATHSIG,SIGKILL)!=0 || getppid()!=parent) return -1;",
        "int one=1; if(setsockopt(peer,SOL_SOCKET,SO_NOSIGPIPE,&one,sizeof(one))!=0 || getppid()!=parent) return -1;",
    )
    owner = (
        owner.replace("SOCK_SEQPACKET", "SOCK_DGRAM")
        .replace("MSG_NOSIGNAL", "0")
        .replace("MSG_CMSG_CLOEXEC", "0")
    )
    owner = exact(
        owner,
        "if(nfds<3)received[nfds++]=fd;else {close(fd);bad=1;}",
        "if(fcntl(fd,F_SETFD,FD_CLOEXEC)<0)bad=1; if(nfds<3)received[nfds++]=fd;else {close(fd);bad=1;}",
    )
    (out / "apfs-owner.inc").write_text(owner)
    native = (
        (CAT / "transaction-filestat-probe/mapping/witness-vfs.c")
        .read_text()
        .split("/* Linux UAPI struct procmap_query", 1)[0]
        .replace("#include <sys/sysmacros.h>", "")
    )
    (out / "keeper.c").write_text(
        native
        + "\n"
        + (X / "mac-proof.c").read_text()
        + "\n"
        + (HERE / "keeper.c").read_text()
    )
    compiler = [
        "xcrun",
        "clang",
        "-std=c11",
        "-O0",
        "-D_DARWIN_C_SOURCE",
        "-DSQLITE_ENABLE_FILESTAT",
        "-DSQLITE_THREADSAFE=1",
        "-DSQLITE_OMIT_LOAD_EXTENSION",
    ]
    sp.run(
        [
            *compiler,
            "-I",
            out,
            out / "sqlite3.c",
            out / "keeper.c",
            "-o",
            out / "apfs-owner-keeper",
        ],
        check=True,
    )


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--build-dir", type=Path, required=True)
    build(p.parse_args().build_dir.resolve())
