"""Audit terminal native export benchmark receipts against their original APFS files."""
import argparse
import collections
import contextlib
import ctypes
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import stat
import struct
import sys
import uuid


def require(condition, description):
    if not condition:
        raise ValueError(description)


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()).hexdigest()


def file_sha(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def apfs_identity(fd):
    # sys/attr.h. The two requests each return a 32-bit size plus 16 payload bytes.
    libc = ctypes.CDLL(None, use_errno=True)
    def attr(common, volume):
        fields = struct.pack("=HHIIIII", 5, 0, common, volume, 0, 0, 0)
        buffer = ctypes.create_string_buffer(20)
        if libc.fgetattrlist(fd, fields, buffer, len(buffer), 0) != 0:
            raise OSError(ctypes.get_errno(), "fgetattrlist")
        size, payload = struct.unpack("=I16s", buffer.raw)
        require(size == 20, "incomplete APFS response")
        return payload
    birth = struct.unpack("=qq", attr(0x200, 0))  # ATTR_CMN_CRTIME
    volume = uuid.UUID(bytes=attr(0, 0x80040000))  # ATTR_VOL_INFO | ATTR_VOL_UUID
    return dict(inode=os.fstat(fd).st_ino, birth=list(birth), volumeUUID=str(volume))


def admissions(db):
    rows = db.execute("""
      SELECT s.asset_id, s.project_id, s.kind, t.admitted_at, session.origin, s.scope_id,
             s.operation_id, c.sha256, c.byte_count
      FROM lc_scopes s JOIN lc_scope_times t USING(scope_id) JOIN lc_contents c USING(content_id)
      JOIN lc_sessions session ON session.session_id=s.session_id WHERE session.state='sealed'
      ORDER BY t.admitted_at, s.scope_id
    """)
    result = {}
    for asset, project, kind, admitted, origin, scope, operation, sha, size in rows:
        fingerprint = dict(assetID=asset, projectID=project, sequenceOnly=kind == "sequenceOnly",
                           admittedAt=int(admitted) if admitted.is_integer() else admitted)
        if origin != "v7":
            fingerprint.update(catalogScopeID=scope, catalogOperationID=operation)
        result.setdefault((asset, project, sha, size), digest(fingerprint))
    return result


def verify_round(directory):
    output = directory / "rawmaster"
    db_path = output / "receipts.sqlite"
    inputs = json.loads((directory / "inputs.json").read_bytes())
    source_sizes = {}
    for kind, names in inputs.items():
        files = {p.name: p for p in (directory / kind).iterdir()}
        require(files.keys() == names.keys(), f"source inventory {kind}")
        for name, recorded in names.items():
            path = files[name]
            require(path.is_file() and not path.is_symlink() and file_sha(path) == recorded, f"source SHA {path}")
            source_sizes[(kind, name)] = path.stat().st_size
    timings = json.loads((output / "results.json").read_bytes())
    groups = collections.defaultdict(list)
    batches = []
    with contextlib.closing(sqlite3.connect(db_path.as_uri() + "?mode=ro&immutable=1", uri=True)) as db:
        require(db.execute("PRAGMA user_version").fetchone() == (10,), "expected v10")
        require(db.execute("PRAGMA integrity_check").fetchall() == [("ok",)], "integrity check")
        require(not db.execute("PRAGMA foreign_key_check").fetchall(), "foreign key check")
        require(db.execute("SELECT count(*) FROM lc_workbench_names").fetchone() == (0,), "live name reservations")
        source_proof = admissions(db)
        meta = dict(db.execute("SELECT key, value FROM lc_meta WHERE key GLOB 'wb032.*'"))
        prefix = "wb032.manifest.v1/"
        manifests = {key[len(prefix):]: value for key, value in meta.items() if key.startswith(prefix)}
        seen_destinations = set()
        for batch, serialized in sorted(manifests.items()):
            frozen = json.loads(serialized)
            manifest_sha = hashlib.sha256(serialized.encode()).hexdigest()
            control = json.loads(meta["wb032.control.v1/" + batch])
            target = json.loads(meta["wb032.target.v1/" + batch])
            require(meta["wb032.done.v1/" + batch] == control["manifestSHA256"] == target["manifestSha256"] == manifest_sha, batch)
            require(control["generation"] == 1 and control["tokenDigest"] is None and control["leaseUntilMs"] is None, batch)
            require(frozen["batchID"] == batch and frozen["schema"] == 1 and target["extension"] == "jpg", batch)
            count = len(frozen["items"])
            require(count == control["itemCount"], batch)
            destination = Path(frozen["destination"]["pathHint"])
            require(destination.parent == output and str(destination) == target["binding"]["path"], batch)
            require(destination not in seen_destinations, f"reused destination {destination}")
            seen_destinations.add(destination)
            kind = next(k for k in inputs if destination.name.startswith(f"{k}-{count}-"))
            group = f"{kind}/{count}"
            require(len(frozen["sourceContext"]["filenames"]) == len(target["stems"]) == count, group)
            require(sum(k.startswith("wb032.item.v1/" + batch + "/") for k in meta) == count, batch)
            files = []
            dest_fd = os.open(destination, os.O_RDONLY | os.O_NOFOLLOW | os.O_DIRECTORY)
            try:
                require(apfs_identity(dest_fd) == target["binding"]["identity"], str(destination))
                for ordinal, item in enumerate(frozen["items"], 1):
                    name = frozen["sourceContext"]["filenames"][ordinal - 1]
                    work, version = item["work"], item["version"]
                    source = work["source"]
                    sha = inputs[kind][name]
                    size = source_sizes[(kind, name)]
                    require(work["id"] == version["workID"] and work["adoptedVersionID"] == version["id"] and version["kind"] == "original", name)
                    require(source == version["source"] and source["assetID"] == item["assetID"] and source["contentSHA256"] == source["catalogContentHash"] == sha, name)
                    require(source["byteCount"] == size and source["sourceLocation"] == (directory / kind / name).as_uri(), name)
                    require(source["admissionFingerprint"] == source_proof[(item["assetID"], source["projectID"], sha, size)], name)
                    row = json.loads(meta[f"wb032.item.v1/{batch}/{ordinal:03}"])
                    require(row["ordinal"] == item["ordinal"] == ordinal and row["manifestSha256"] == manifest_sha, name)
                    require(row["state"] == "delivered" and row["attempt"] == row["generation"] == 1
                            and row["tokenDigest"] is None and row["leaseUntil"] is None and row["reason"] is None, name)
                    ticket = row["ticket"]
                    final = ticket["filename"]
                    require(item["stem"] == target["stems"][ordinal - 1] == Path(name).stem and final == item["stem"] + ".jpg", name)
                    with os.fdopen(os.open(final, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=dest_fd), "rb") as stream:
                        disk = os.fstat(stream.fileno())
                        require(stat.S_ISREG(disk.st_mode) and disk.st_size == ticket["byteCount"], final)
                        require(apfs_identity(stream.fileno()) == ticket["identity"], final)
                        require(hashlib.file_digest(stream, "sha256").hexdigest() == ticket["sha256"], final)
                    files.append([name, sha, final, ticket["sha256"], ticket["byteCount"]])
                require(set(os.listdir(dest_fd)) == {f[2] for f in files}, f"remaining stage or unexpected file {destination}")
            finally:
                os.close(dest_fd)
            groups[group].append(digest(files))
            batches.append(dict(batchID=batch, group=group, manifestSHA256=manifest_sha, deliveryMappingSHA256=digest(files)))
        require(set(groups) == set(timings), "unexpected or missing groups")
        for group, values in groups.items():
            require(len(values) == 1 + len(timings[group]) and len(set(values)) == 1, f"count or contents of warm-up and timed deliveries {group}")
        require(seen_destinations == {p for p in output.iterdir() if p.is_dir()}, "unrecorded output directory")
    return dict(receiptsSHA256=file_sha(db_path), inputsSHA256=file_sha(directory / "inputs.json"), groups={k: v[0] for k, v in groups.items()},
                batchCount=len(batches), itemCount=sum(int(b["group"].split("/")[1]) for b in batches), batches=batches, timings=timings)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--round", type=Path, action="append", required=True, help="native round, in original location; all rounds must use the same source set")
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    if sys.platform != "darwin" or args.report.exists():
        parser.error("requires original APFS outputs on macOS and an unused report path")
    results = {str(r): verify_round(r.resolve()) for r in args.round}
    common = next(iter(results.values()))
    require(all(r["groups"] == common["groups"] and r["inputsSHA256"] == common["inputsSHA256"] for r in results.values()), "round mismatch")
    report = {"passed": True, "groups": common["groups"], "batches": sum(r["batchCount"] for r in results.values()),
              "items": sum(r["itemCount"] for r in results.values()), "rounds": results}
    with args.report.open("x") as stream:
        json.dump(report, stream, indent=2)
        stream.write("\n")
    print(f"Verified {report['batches']} batches and {report['items']} items.")
