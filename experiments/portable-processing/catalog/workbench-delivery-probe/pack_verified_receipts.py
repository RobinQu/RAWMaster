"""Archive the individual tickets behind completed verify_benchmark_receipts.py reports."""
import argparse
import contextlib
import gzip
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import tempfile


def pack(reports, destination):
    seen = set()
    batches = 0
    files = 0
    with tempfile.NamedTemporaryFile(dir=destination.parent) as stage:
        with gzip.GzipFile(fileobj=stage, filename="", mode="wb", compresslevel=6, mtime=0) as archive:
            for report_path in reports:
                report = json.loads(report_path.read_bytes())
                if report["passed"] is not True:
                    raise ValueError(f"unverified report {report_path}")
                for round_path, run in report["rounds"].items():
                    root = Path(round_path)
                    database = root / "rawmaster" / "receipts.sqlite"
                    with database.open("rb") as stream:
                        if hashlib.file_digest(stream, "sha256").hexdigest() != run["receiptsSHA256"]:
                            raise ValueError(f"changed database {database}")
                    with contextlib.closing(sqlite3.connect(database.resolve().as_uri() + "?mode=ro&immutable=1", uri=True)) as db:
                        meta = dict(db.execute("SELECT key,value FROM lc_meta WHERE key GLOB 'wb032.*'"))
                    for batch in run["batches"]:
                        bid = batch["batchID"]
                        if bid in seen:
                            raise ValueError(f"duplicate batch {bid}")
                        seen.add(bid)
                        raw = meta["wb032.manifest.v1/" + bid]
                        frozen = json.loads(raw)
                        target = json.loads(meta["wb032.target.v1/" + bid])
                        done = meta["wb032.done.v1/" + bid]
                        if hashlib.sha256(raw.encode()).hexdigest() != batch["manifestSHA256"] or done != batch["manifestSHA256"]:
                            raise ValueError(f"inconsistent manifest {bid}")
                        items = []
                        mapping = []
                        for item in frozen["items"]:
                            n = item["ordinal"]
                            name = frozen["sourceContext"]["filenames"][n - 1]
                            value = meta[f"wb032.item.v1/{bid}/{n:03}"]
                            row = json.loads(value)
                            source = item["work"]["source"]
                            ticket = row["ticket"]
                            items.append(dict(sourceName=name, assetID=item["assetID"], projectID=source["projectID"],
                                              sourceSHA256=source["contentSHA256"], sourceBytes=source["byteCount"],
                                              admissionFingerprint=source["admissionFingerprint"], workID=item["work"]["id"],
                                              versionID=item["version"]["id"], recordSHA256=hashlib.sha256(value.encode()).hexdigest(),
                                              record=row))
                            mapping.append([name, source["contentSHA256"], ticket["filename"], ticket["sha256"], ticket["byteCount"]])
                        canonical = json.dumps(mapping, separators=(",", ":"), ensure_ascii=False).encode()
                        if hashlib.sha256(canonical).hexdigest() != batch["deliveryMappingSHA256"]:
                            raise ValueError(f"mapping differs from physical audit {bid}")
                        entry = dict(round=root.name, group=batch["group"], batchID=bid, manifestSHA256=done,
                                     receiptsSHA256=run["receiptsSHA256"], mappingSHA256=batch["deliveryMappingSHA256"],
                                     control=json.loads(meta["wb032.control.v1/" + bid]),
                                     targetName=Path(target["binding"]["path"]).name, targetIdentity=target["binding"]["identity"],
                                     items=items)
                        archive.write((json.dumps(entry, separators=(",", ":"), ensure_ascii=False) + "\n").encode())
                        batches += 1
                        files += len(items)
        stage.flush()
        os.link(stage.name, destination)
    print(f"Archived {files} tickets across {batches} verified batches.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--audit", action="append", type=Path, required=True, help="finished per-source physical audit JSON")
    parser.add_argument("--output", type=Path, required=True, help="unused .jsonl.gz filename")
    args = parser.parse_args()
    pack(args.audit, args.output)
