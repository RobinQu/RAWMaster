"""Compare the production Swift metadata path with a rebuildable SQLite projection.

The input catalog is opened read-only with WAL awareness. All writes, binaries and
file-level results stay in a new private work directory. Only summary.json is portable.
"""
import argparse
import hashlib
import json
import math
import platform
import sqlite3
import statistics
import subprocess
import tempfile
import time
from pathlib import Path


def stats(samples):
    values = sorted(samples)
    return {"n": len(values), "p50_ms": round(statistics.median(values), 4),
            "p95_ms": round(values[math.ceil(len(values) * .95) - 1], 4)}


def timed(action):
    start = time.perf_counter_ns()
    value = action()
    return value, (time.perf_counter_ns() - start) / 1e6


def compile_probe(source, release, work):
    core = sorted((release / "RAWMasterCore.build").glob("*.o"))
    if not core:
        raise RuntimeError("Build the release RAWMasterCore target with the native SwiftPM build system first")
    files = [source / "Sources/RAWMaster/LibrarySnapshot.swift",
             source / "Sources/RAWMaster/AssetBrowserOrder.swift", Path(__file__).with_suffix(".swift")]
    output = work / "catalog-probe"
    subprocess.run(["swiftc", "-O", "-parse-as-library", "-swift-version", "5",
                    "-I", release / "Modules", "-I", source / "Sources/CSQLite",
                    *files, *core, "-o", output], check=True)
    return output


def make_projection(db, rows):
    db.executescript("""
        CREATE TABLE photo (
            ordinal INTEGER PRIMARY KEY, asset_id TEXT NOT NULL UNIQUE,
            filename TEXT NOT NULL, camera TEXT, rating INTEGER NOT NULL,
            missing_time INTEGER NOT NULL, reverse_time REAL NOT NULL
        );
        CREATE INDEX by_time ON photo(missing_time, reverse_time, ordinal);
        CREATE INDEX by_camera_time ON photo(camera, missing_time, reverse_time, ordinal);
        CREATE INDEX by_rating ON photo(rating);
        CREATE VIRTUAL TABLE names USING fts5(filename, tokenize='trigram');
    """)
    with db:
        db.executemany("INSERT INTO photo VALUES(?,?,?,?,?,?,?)", (
            (i, r["assetID"], r["filename"], r.get("camera"), r["rating"],
             int("captured" not in r), -r.get("captured", 0.0)) for i, r in enumerate(rows, 1)))
        db.execute("INSERT INTO names(rowid, filename) SELECT ordinal, filename FROM photo")
        db.execute("ANALYZE")


def measure_case(db, case):
    params, conditions = [], []
    if "camera" in case:
        conditions += ["camera = ?", "missing_time = 0", "reverse_time <= ?"]
        params += [case["camera"], -case["since"]]
    if "minimumRating" in case:
        conditions.append("rating >= ?")
        params.append(case["minimumRating"])
    if "needle" in case:
        needle = case["needle"]
        if len(needle) >= 3:
            conditions.append("ordinal IN (SELECT rowid FROM names WHERE names MATCH ?)")
            params.append('"' + needle.replace('"', '""') + '"')
        conditions.append("instr(filename, ?) > 0")
        params.append(needle)
    where = " WHERE " + (" AND ".join(conditions) or "1")
    order = " ORDER BY missing_time, reverse_time, ordinal"
    select = "SELECT asset_id, filename, camera, rating, missing_time, reverse_time, ordinal FROM photo"
    count = "SELECT count(*) FROM photo" + where
    first_page = select + where + order + " LIMIT 60"
    plan = [r[-1] for r in db.execute("EXPLAIN QUERY PLAN " + first_page, params)]

    # Compare every ordered ID across keyset pages, including all ties.
    page = db.execute(first_page, params).fetchall()
    ids = [r[0] for r in page]
    while len(page) == 60:
        cursor = list(page[-1][-3:])
        next_page = select + where + " AND (missing_time,reverse_time,ordinal) > (?,?,?)" + order + " LIMIT 60"
        page = db.execute(next_page, params + cursor).fetchall()
        ids.extend(r[0] for r in page)
    assert ids == case["ids"] and db.execute(count, params).fetchone()[0] == len(ids), case["name"]
    def page_and_count():
        return db.execute(first_page, params).fetchall(), db.execute(count, params).fetchone()[0]
    samples = [timed(page_and_count)[1] for _ in range(31)]
    return {"matched_files": len(ids), "all_ordered_ids_match": True,
            "swift_resident_all_matches": stats(case["warmMilliseconds"]),
            "sqlite_first_60_and_exact_count": stats(samples), "sqlite_plan": plan}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", type=Path, required=True)
    parser.add_argument("--source", type=Path, required=True, help="Swift package checkout or frozen copy")
    parser.add_argument("--release", type=Path, required=True, help="Native SwiftPM release binary directory")
    parser.add_argument("--output", type=Path, required=True, help="Parent for a new private work directory")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="query-", dir=args.output.resolve()))
    probe = compile_probe(args.source.resolve(), args.release.resolve(), work)
    backup = work / "source-backup.sqlite"
    with sqlite3.connect(args.catalog.resolve().as_uri() + "?mode=ro", uri=True) as source:
        source.execute("PRAGMA query_only=ON")
        with sqlite3.connect(backup) as dest:
            source.backup(dest)
    fixture = work / "private-fixture.json"
    subprocess.run([probe, backup, fixture], check=True)
    data = json.loads(fixture.read_text())
    projected = work / "index.sqlite"
    with sqlite3.connect(projected) as db:
        _, build_ms = timed(lambda: make_projection(db, data["rows"]))
        cases = {case["name"]: measure_case(db, case) for case in data["cases"]}
        assert db.execute("pragma quick_check").fetchone()[0] == "ok"
    with sqlite3.connect(backup.as_uri() + "?mode=ro", uri=True) as baseline:
        schema = baseline.execute("pragma user_version").fetchone()[0]
    files = sorted((args.source / "Sources/RAWMasterCore").glob("*.swift"))
    files += [args.source / "Sources/RAWMaster" / n for n in ["AssetBrowserOrder.swift", "LibrarySnapshot.swift"]]
    digest = hashlib.sha256()
    for path in files:
        digest.update(path.name.encode() + b"\0" + path.read_bytes())
    summary = {"schema_version": schema, "platform": platform.platform(), "sqlite_projection_version": sqlite3.sqlite_version,
               "production_read_sources_sha256": digest.hexdigest(), "snapshot_files": data["catalogFiles"],
               "admitted_files": data["admissions"], "groups": data["groups"],
               "catalog_open_ms": round(data["catalogOpenMilliseconds"], 3),
               "first_snapshot_ms": round(data["firstSnapshotMilliseconds"], 3),
               "subsequent_snapshot": stats(data["subsequentSnapshotMilliseconds"]),
               "projection_build_ms": round(build_ms, 3), "projection_bytes": projected.stat().st_size,
               "page_size_files": 60, "cases": cases}
    (work / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
    print(work / "summary.json")


if __name__ == "__main__":
    main()
