#!/usr/bin/env python3
"""DuckDB versus SQLite on RAWMaster's real catalog shape.

Schema, page query shape, sort keys, filter columns and the point-update pattern are taken from
Modules/LibraryCatalog/src/query/schema.sql and query/read.rs, not invented.

Measured paths:
  import             projection build: 200k documents + 600k tag rows, batched, one transaction
  first page         whole library, newest first, 60 rows (the default grid)
  project page       project + rating, oldest first, 60 rows (a filtered grid)
  facets             rating / camera / tag histograms, project and whole library
  tag page           two tag keys, newest first
  name prefix        normalized filename prefix (the app's filename search)
  body substring     free-text substring (the app's `text` search without FTS)
  hydrate            second read of a page: 60 rows by doc id
  asset lookup       1000 point reads by asset id (editing / receipts)
  point update       200 single-row updates, one transaction each (autocommit)
  bulk update        10k row rating change, one transaction
  churn              insert then delete a 5k document generation; WAL/checkpoint cost
  cold open          close, reopen, first page
  writers            4 threads doing disjoint point updates
  second process     another process opens the same catalog read-write and read-only

Fairness rules:
  * both engines get multi-row INSERTs in one transaction for the import;
  * SQLite gets a 256 MiB page cache (the app currently uses the 2 MiB default);
  * each engine keeps its own index design: SQLite the shipped indexes, DuckDB PK + the
    lookup indexes it needs. The shipped schema has no (gen, time) index, so SQLite is also
    measured with two added covering indexes to separate "engine" from "missing index";
  * all write and multi-process tests run on scratch copies so earlier phases do not leak in.

Run:
  output/research/db-bench/.venv/bin/python output/research/db-bench/bench.py
Environment:
  ASSETS=200000  ROUNDS=5  OUT=.../report.json
"""

from __future__ import annotations

import json
import math
import os
import platform
import shutil
import sqlite3
import statistics
import subprocess
import sys
import threading
import time
from pathlib import Path

import duckdb

ASSETS = int(os.environ.get("ASSETS", "200000"))
ROUNDS = int(os.environ.get("ROUNDS", "5"))
TAGS = 3
CHUNK = 512
# Run from the repository root. output/ is gitignored.
ROOT = Path(os.environ.get("BENCH_ROOT", "output/research/db-bench/run"))
OUT = Path(os.environ.get("OUT", "output/research/db-bench/report.json"))

COLUMNS = [
    "gen", "doc", "asset_id", "file_id", "capture_id", "project_id", "session_id",
    "session_ord", "asset_ord", "filename", "name_key", "relative_path", "path_tie",
    "camera", "camera_key", "captured", "missing_time", "time_asc", "time_desc",
    "rating", "rating_desc", "decision", "availability", "color_label", "reviewed",
    "format", "sequence_only", "body", "record", "role",
]
COLS = len(COLUMNS)
BASE = 1_700_000_000.0
CAMERAS = [
    ("Nikon Z 8", "nikon z 8"), ("Nikon Z 7II", "nikon z 7ii"),
    ("Sony A7R V", "sony a7r v"), ("Canon EOS R5", "canon eos r5"),
    ("Fujifilm X-T5", "fujifilm x-t5"), ("Panasonic S5II", "panasonic s5ii"),
    ("Leica Q3", "leica q3"), ("OM System OM-1", "om system om-1"),
]
TAG_KEYS = [f"tag-{i:02d}" for i in range(50)]
WORDS = ("golden hour sunset portrait landscape street night f/1.8 iso100 "
         "tokyo kyoto iceland coast mountain forest snow rain neon").split()


def document(i: int) -> tuple:
    camera, camera_key = CAMERAS[i % len(CAMERAS)]
    captured = BASE + i * 1800.0
    filename = f"DSC_{i:06d}.ARW"
    project = f"p{i % 40:02d}"
    session = f"s{i % 500:03d}"
    record = json.dumps({
        "id": f"a{i:08d}", "fileName": filename, "projectID": project,
        "sessionID": session, "rating": i % 6, "decision": ("keep", "pending", "reject")[i % 3],
        "camera": camera, "lens": f"lens-{i % 12:02d}", "capturedAt": captured,
        "tags": [TAG_KEYS[(i + k) % len(TAG_KEYS)] for k in range(TAGS)],
        "note": " ".join(WORDS[(i + k) % len(WORDS)] for k in range(6)),
    }, separators=(",", ":"))
    body = " ".join([
        filename, camera, project, " ".join(WORDS[(i + k) % len(WORDS)] for k in range(8)),
    ])
    return (
        i + 1, 1, f"a{i:08d}", f"f{i:08d}", f"c{i // 10:08d}", project, session,
        i, i, filename, filename.lower(), f"{project}/{filename}",
        f"{i:08d}", camera, camera_key, captured, 0, captured, captured - i * 0.001,
        i % 6, 5 - (i % 6), ("keep", "pending", "reject")[i % 3],
        ("online", "offline")[i % 2], None if i % 7 else "red", i % 2,
        "arw", 1 if i % 11 == 0 else 0, body, record,
        ("original", "virtual")[i % 5 == 0],
    )


def tags(i: int):
    for k in range(TAGS):
        key = TAG_KEYS[(i + k) % len(TAG_KEYS)]
        yield (i + 1, key, key.replace("-", " ").title())


def documents(start: int, count: int):
    return [document(i) for i in range(start, start + count)]


def tag_rows(start: int, count: int):
    return [t for i in range(start, start + count) for t in tags(i)]


def values_sql(rows: int, columns: int) -> str:
    return ",".join(["(" + ",".join("?" * columns) + ")"] * rows)


INSERT = lambda n: f"INSERT INTO documents VALUES {values_sql(n, COLS)}"  # noqa: E731
INSERT_TAGS = lambda n: f"INSERT INTO doc_tags VALUES {values_sql(n, 3)}"  # noqa: E731

# --------------------------------------------------------------------------------------------
# schemas


SQLITE_DDL = """
CREATE TABLE documents (
    doc INTEGER PRIMARY KEY, gen INTEGER NOT NULL,
    asset_id TEXT NOT NULL, file_id TEXT NOT NULL, capture_id TEXT NOT NULL,
    project_id TEXT NOT NULL, session_id TEXT NOT NULL,
    session_ord INTEGER NOT NULL, asset_ord INTEGER NOT NULL,
    filename TEXT NOT NULL, name_key TEXT NOT NULL, relative_path TEXT NOT NULL,
    path_tie TEXT NOT NULL, camera TEXT, camera_key TEXT, captured REAL,
    missing_time INTEGER NOT NULL, time_asc REAL NOT NULL, time_desc REAL NOT NULL,
    rating INTEGER NOT NULL, rating_desc INTEGER NOT NULL, decision TEXT NOT NULL,
    availability TEXT NOT NULL, color_label TEXT, reviewed INTEGER NOT NULL,
    format TEXT NOT NULL, sequence_only INTEGER NOT NULL, body TEXT NOT NULL,
    record TEXT NOT NULL, role TEXT NOT NULL,
    UNIQUE(gen, project_id, file_id)
);
CREATE INDEX docs_asset ON documents(gen, asset_id);
CREATE INDEX docs_file ON documents(gen, file_id, asset_id, project_id);
CREATE INDEX docs_capture ON documents(gen, capture_id, asset_id, project_id, file_id);
CREATE INDEX docs_camera ON documents(gen, camera_key, missing_time, time_desc);
CREATE INDEX docs_rating ON documents(gen, rating);
CREATE INDEX docs_session ON documents(gen, session_id);
CREATE TABLE doc_tags (
    doc INTEGER NOT NULL, key TEXT NOT NULL, display TEXT NOT NULL,
    PRIMARY KEY(doc, key)
) WITHOUT ROWID;
CREATE INDEX tags_lookup ON doc_tags(key, doc);
"""

DUCK_DDL = """
CREATE TABLE documents (
    doc BIGINT PRIMARY KEY, gen INTEGER NOT NULL,
    asset_id VARCHAR NOT NULL, file_id VARCHAR NOT NULL, capture_id VARCHAR NOT NULL,
    project_id VARCHAR NOT NULL, session_id VARCHAR NOT NULL,
    session_ord INTEGER NOT NULL, asset_ord INTEGER NOT NULL,
    filename VARCHAR NOT NULL, name_key VARCHAR NOT NULL, relative_path VARCHAR NOT NULL,
    path_tie VARCHAR NOT NULL, camera VARCHAR, camera_key VARCHAR, captured DOUBLE,
    missing_time INTEGER NOT NULL, time_asc DOUBLE NOT NULL, time_desc DOUBLE NOT NULL,
    rating INTEGER NOT NULL, rating_desc INTEGER NOT NULL, decision VARCHAR NOT NULL,
    availability VARCHAR NOT NULL, color_label VARCHAR, reviewed INTEGER NOT NULL,
    format VARCHAR NOT NULL, sequence_only INTEGER NOT NULL, body VARCHAR NOT NULL,
    record VARCHAR NOT NULL, role VARCHAR NOT NULL,
    UNIQUE(gen, project_id, file_id)
);
CREATE INDEX docs_asset ON documents(gen, asset_id);
CREATE INDEX docs_session ON documents(gen, session_id);
CREATE TABLE doc_tags (doc BIGINT NOT NULL, key VARCHAR NOT NULL, display VARCHAR NOT NULL,
                       PRIMARY KEY(doc, key));
CREATE INDEX tags_lookup ON doc_tags(key, doc);
"""

# --------------------------------------------------------------------------------------------
# building


def sqlite_connect(path: Path, synchronous: str = "FULL") -> sqlite3.Connection:
    db = sqlite3.connect(path, isolation_level=None, check_same_thread=False)
    db.execute("PRAGMA journal_mode=WAL")
    db.execute(f"PRAGMA synchronous={synchronous}")
    db.execute("PRAGMA cache_size=-262144")
    db.execute("PRAGMA temp_store=MEMORY")
    db.execute("PRAGMA busy_timeout=5000")
    return db


def build_sqlite(path: Path) -> float:
    for suffix in ("", "-wal", "-shm"):
        Path(str(path) + suffix).unlink(missing_ok=True)
    db = sqlite_connect(path)
    db.executescript(SQLITE_DDL)
    started = time.perf_counter()
    db.execute("BEGIN")
    for start in range(0, ASSETS, CHUNK):
        count = min(CHUNK, ASSETS - start)
        db.execute(INSERT(count), [v for r in documents(start, count) for v in r])
        db.execute(INSERT_TAGS(count * TAGS), [v for t in tag_rows(start, count) for v in t])
    db.execute("COMMIT")
    elapsed = time.perf_counter() - started
    db.execute("ANALYZE")
    db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    db.close()
    return elapsed


def build_duck(path: Path) -> float:
    path.unlink(missing_ok=True)
    db = duckdb.connect(str(path))
    db.execute("SET threads=8")
    db.execute("SET memory_limit='4GB'")
    db.execute("SET preserve_insertion_order=false")
    db.execute(DUCK_DDL)
    started = time.perf_counter()
    db.execute("BEGIN")
    for start in range(0, ASSETS, CHUNK):
        count = min(CHUNK, ASSETS - start)
        db.execute(INSERT(count), [v for r in documents(start, count) for v in r])
        db.execute(INSERT_TAGS(count * TAGS), [v for t in tag_rows(start, count) for v in t])
    db.execute("COMMIT")
    elapsed = time.perf_counter() - started
    db.execute("ANALYZE")
    db.execute("CHECKPOINT")
    db.close()
    return elapsed


# --------------------------------------------------------------------------------------------
# timing


def median(samples: list[float]) -> float:
    return statistics.median(samples)


def percentile(samples: list[float], fraction: float) -> float:
    ordered = sorted(samples)
    return ordered[min(len(ordered) - 1, math.ceil(len(ordered) * fraction) - 1)]


def measure(fn, rounds: int = ROUNDS, warmup: bool = True) -> dict:
    if warmup:
        fn()
    samples = []
    for _ in range(rounds):
        started = time.perf_counter()
        fn()
        samples.append((time.perf_counter() - started) * 1000)
    return {"median": round(median(samples), 3), "p95": round(percentile(samples, 0.95), 3),
            "samples": [round(s, 3) for s in samples]}


# --------------------------------------------------------------------------------------------
# read panel


PAGE_ALL = "SELECT doc, record FROM documents WHERE gen=? ORDER BY time_desc LIMIT 60"
PAGE_PROJECT = ("SELECT doc, record FROM documents WHERE gen=? AND project_id=? AND rating>=? "
                "AND time_asc>? ORDER BY time_asc LIMIT 60")
FACET_RATING = ("SELECT rating, count(DISTINCT file_id), count(DISTINCT capture_id) "
                "FROM documents WHERE gen=? AND project_id=? GROUP BY rating")
FACET_CAMERA = ("SELECT camera_key, min(camera), count(DISTINCT file_id), count(DISTINCT capture_id) "
                "FROM documents WHERE gen=? AND project_id=? GROUP BY camera_key "
                "ORDER BY camera_key IS NULL, camera_key")
FACET_RATING_ALL = ("SELECT rating, count(DISTINCT file_id), count(DISTINCT capture_id) "
                    "FROM documents WHERE gen=? GROUP BY rating")
FACET_CAMERA_ALL = ("SELECT camera_key, min(camera), count(DISTINCT file_id), count(DISTINCT capture_id) "
                    "FROM documents WHERE gen=? GROUP BY camera_key "
                    "ORDER BY camera_key IS NULL, camera_key")
FACET_TAG_ALL = ("SELECT t.key, min(t.display), count(DISTINCT t.doc) "
                 "FROM doc_tags t GROUP BY t.key ORDER BY t.key")
TAG_PAGE = ("SELECT d.doc, d.record FROM documents d JOIN doc_tags t ON t.doc=d.doc "
            "WHERE d.gen=? AND d.project_id=? AND t.key IN (?,?) "
            "GROUP BY d.doc, d.record, d.time_desc ORDER BY d.time_desc LIMIT 60")
NAME_PREFIX = ("SELECT doc FROM documents WHERE gen=? AND name_key>=? AND name_key<? "
               "ORDER BY name_key LIMIT 60")
BODY_SEARCH = "SELECT doc FROM documents WHERE gen=? AND body LIKE '%golden hour%' LIMIT 60"
HYDRATE_IDS = [1 + i * 37 for i in range(60)]
HYDRATE = f"SELECT doc, record FROM documents WHERE doc IN ({','.join(map(str, HYDRATE_IDS))})"
ASSET_LOOKUP = "SELECT record FROM documents WHERE gen=? AND asset_id=?"


def read_panel(execute) -> dict:
    result = {}
    result["first_page"] = measure(lambda: execute(PAGE_ALL, (1,)).fetchall())
    result["project_page"] = measure(lambda: execute(PAGE_PROJECT, (1, "p07", 3, 0.0)).fetchall())
    result["facet_rating"] = measure(lambda: execute(FACET_RATING, (1, "p07")).fetchall())
    result["facet_camera"] = measure(lambda: execute(FACET_CAMERA, (1, "p07")).fetchall())
    result["facet_rating_all"] = measure(lambda: execute(FACET_RATING_ALL, (1,)).fetchall())
    result["facet_camera_all"] = measure(lambda: execute(FACET_CAMERA_ALL, (1,)).fetchall())
    result["facet_tag_all"] = measure(lambda: execute(FACET_TAG_ALL).fetchall())
    result["tag_page"] = measure(
        lambda: execute(TAG_PAGE, (1, "p07", "tag-07", "tag-23")).fetchall())
    result["name_prefix"] = measure(
        lambda: execute(NAME_PREFIX, (1, "dsc_01", "dsc_02")).fetchall())
    result["body_search"] = measure(lambda: execute(BODY_SEARCH, (1,)).fetchall())
    result["hydrate"] = measure(lambda: execute(HYDRATE).fetchall())

    def lookups():
        for i in range(1000):
            execute(ASSET_LOOKUP, (1, f"a{i * 7:08d}")).fetchone()

    result["asset_lookup"] = measure(lookups)
    return result


# --------------------------------------------------------------------------------------------
# write panel


def write_panel_sqlite(path: Path, synchronous: str) -> dict:
    db = sqlite_connect(path, synchronous)
    result = {}

    def point():
        for i in range(200):
            n = 1 + i * 11
            db.execute("UPDATE documents SET rating=?, rating_desc=? WHERE doc=?", (5, 0, n))

    result["point_update"] = measure(lambda: point(), rounds=1, warmup=False)

    def bulk():
        db.execute("UPDATE documents SET rating=?, rating_desc=? WHERE gen=? AND doc BETWEEN ? AND ?",
                   (4, 1, 1, 1, 10000))

    result["bulk_update"] = measure(bulk, rounds=2)

    def insert_generation():
        db.execute("BEGIN")
        for start in range(ASSETS, ASSETS + 5000, CHUNK):
            count = min(CHUNK, ASSETS + 5000 - start)
            db.execute(INSERT(count), [v for r in documents(start, count) for v in r])
            db.execute(INSERT_TAGS(count * TAGS), [v for t in tag_rows(start, count) for v in t])
        db.execute("COMMIT")

    def delete_generation():
        db.execute("BEGIN")
        db.execute("DELETE FROM doc_tags WHERE doc BETWEEN ? AND ?", (ASSETS + 1, ASSETS + 5000))
        db.execute("DELETE FROM documents WHERE doc BETWEEN ? AND ?", (ASSETS + 1, ASSETS + 5000))
        db.execute("COMMIT")

    result["insert_5k"] = measure(insert_generation, rounds=1, warmup=False)
    result["page_after_insert"] = measure(lambda: db.execute(PAGE_ALL, (1,)).fetchall(), rounds=2)
    result["delete_5k"] = measure(delete_generation, rounds=1, warmup=False)

    before = path.stat().st_size
    wal = Path(str(path) + "-wal")
    wal_before = wal.stat().st_size if wal.exists() else 0
    checkpoint = measure(lambda: db.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchall(),
                         rounds=1, warmup=False)
    result["checkpoint"] = checkpoint
    result["file_mb_before_checkpoint"] = round((before + wal_before) / 1e6, 1)
    result["file_mb_after_checkpoint"] = round(path.stat().st_size / 1e6, 1)
    db.close()
    return result


def write_panel_duck(path: Path) -> dict:
    db = duckdb.connect(str(path))
    db.execute("SET threads=8")
    db.execute("SET memory_limit='4GB'")
    result = {}

    def point():
        for i in range(200):
            n = 1 + i * 11
            db.execute("UPDATE documents SET rating=?, rating_desc=? WHERE doc=?", (5, 0, n))

    result["point_update"] = measure(point, rounds=1, warmup=False)

    def bulk():
        db.execute("UPDATE documents SET rating=?, rating_desc=? WHERE gen=? AND doc BETWEEN ? AND ?",
                   (4, 1, 1, 1, 10000))

    result["bulk_update"] = measure(bulk, rounds=2)

    def insert_generation():
        db.execute("BEGIN")
        for start in range(ASSETS, ASSETS + 5000, CHUNK):
            count = min(CHUNK, ASSETS + 5000 - start)
            db.execute(INSERT(count), [v for r in documents(start, count) for v in r])
            db.execute(INSERT_TAGS(count * TAGS), [v for t in tag_rows(start, count) for v in t])
        db.execute("COMMIT")

    def delete_generation():
        db.execute("BEGIN")
        db.execute("DELETE FROM doc_tags WHERE doc BETWEEN ? AND ?", (ASSETS + 1, ASSETS + 5000))
        db.execute("DELETE FROM documents WHERE doc BETWEEN ? AND ?", (ASSETS + 1, ASSETS + 5000))
        db.execute("COMMIT")

    result["insert_5k"] = measure(insert_generation, rounds=1, warmup=False)
    result["page_after_insert"] = measure(lambda: db.execute(PAGE_ALL, (1,)).fetchall(), rounds=2)
    result["delete_5k"] = measure(delete_generation, rounds=1, warmup=False)

    before = path.stat().st_size
    wal = Path(str(path) + ".wal")
    wal_before = wal.stat().st_size if wal.exists() else 0
    result["checkpoint"] = measure(lambda: db.execute("CHECKPOINT").fetchall(),
                                   rounds=1, warmup=False)
    result["file_mb_before_checkpoint"] = round((before + wal_before) / 1e6, 1)
    result["file_mb_after_checkpoint"] = round(path.stat().st_size / 1e6, 1)
    db.close()
    return result


# --------------------------------------------------------------------------------------------
# operational


def commit_cost(engine: str, path: Path, synchronous: str = "FULL",
                fullfsync: bool = False, fsync_mode: str = "STANDARD") -> dict:
    """Isolate the durability cost: 200 autocommit single-row inserts into a tiny table."""
    samples = []
    for _ in range(3):
        if engine == "sqlite":
            db = sqlite_connect(path, synchronous)
            if fullfsync:
                db.execute("PRAGMA fullfsync=ON")
            db.execute("CREATE TABLE IF NOT EXISTS commit_probe(x INTEGER)")
        else:
            db = duckdb.connect(str(path))
            db.execute(f"SET fsync_mode='{fsync_mode}'")
            db.execute("CREATE TABLE IF NOT EXISTS commit_probe(x INTEGER)")
        started = time.perf_counter()
        for i in range(200):
            db.execute("INSERT INTO commit_probe VALUES (?)", (i,))
        samples.append((time.perf_counter() - started) * 1000)
        db.execute("DROP TABLE commit_probe")
        db.close()
    return {"median": round(median(samples), 1), "samples": [round(s, 1) for s in samples],
            "per_commit_ms": round(median(samples) / 200, 3)}


def cold_open(engine: str, path: Path) -> dict:
    samples = []
    for _ in range(5):
        started = time.perf_counter()
        if engine == "sqlite":
            db = sqlite3.connect(path)
            db.execute("PRAGMA cache_size=-262144")
            db.execute(PAGE_ALL, (1,)).fetchall()
            db.close()
        else:
            db = duckdb.connect(str(path))
            db.execute("SET threads=8")
            db.execute(PAGE_ALL, (1,)).fetchall()
            db.close()
        samples.append((time.perf_counter() - started) * 1000)
    return {"median": round(median(samples), 2), "p95": round(percentile(samples, 0.95), 2),
            "samples": [round(s, 2) for s in samples]}


def writers(engine: str, path: Path) -> dict:
    errors: list[str] = []
    retries = [0]
    barrier = threading.Barrier(4)

    def worker(offset: int):
        try:
            if engine == "sqlite":
                db = sqlite_connect(path, "FULL")
                barrier.wait()
                for i in range(50):
                    n = 1 + offset * 50 + i
                    db.execute("BEGIN IMMEDIATE")
                    db.execute("UPDATE documents SET rating=? WHERE doc=?", (2, n))
                    db.execute("COMMIT")
                db.close()
            else:
                db = duckdb.connect(str(path))
                barrier.wait()
                for i in range(50):
                    n = 1 + offset * 50 + i
                    for attempt in range(4):
                        try:
                            db.execute("UPDATE documents SET rating=? WHERE doc=?", (2, n))
                            break
                        except Exception:
                            retries[0] += 1
                            if attempt == 3:
                                raise
                db.close()
        except Exception as error:  # noqa: BLE001 - reported
            errors.append(f"{type(error).__name__}: {error}")

    started = time.perf_counter()
    threads = [threading.Thread(target=worker, args=(t,)) for t in range(4)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    return {"wall_ms": round((time.perf_counter() - started) * 1000, 1),
            "error_count": len(errors), "errors": errors[:3], "retries": retries[0]}


def explain(engine: str, path: Path, sql: str, params: tuple) -> str:
    db = (sqlite3.connect(path) if engine == "sqlite" else duckdb.connect(str(path)))
    try:
        prefix = "EXPLAIN QUERY PLAN " if engine == "sqlite" else "EXPLAIN "
        rows = db.execute(prefix + sql, params).fetchall()
        return " | ".join(str(r[-1]) for r in rows)[:1500]
    finally:
        db.close()


CHILD = r"""
import sys
engine, path, mode = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    if engine == "sqlite":
        import sqlite3
        db = sqlite3.connect(path, timeout=2)
        if mode == "rw":
            db.execute("BEGIN IMMEDIATE"); db.execute("COMMIT")
        else:
            db.execute("SELECT count(*) FROM documents").fetchone()
        db.close()
    else:
        import duckdb
        db = duckdb.connect(path, read_only=(mode == "ro"))
        db.execute("SELECT count(*) FROM documents").fetchone()
        if mode == "rw":
            db.execute("UPDATE documents SET rating=rating WHERE doc=1")
        db.close()
    print("OK")
except Exception as error:
    print(type(error).__name__ + ": " + str(error)[:200])
"""


def second_process(engine: str, path: Path) -> dict:
    result = {}
    for mode in ("rw", "ro"):
        proc = subprocess.run([sys.executable, "-c", CHILD, engine, str(path), mode],
                              capture_output=True, text=True, timeout=30)
        result[mode] = (proc.stdout.strip() or proc.stderr.strip())[:200]
    return result


# --------------------------------------------------------------------------------------------


def copy(src: Path, dst: Path):
    for suffix in ("", "-wal", "-shm"):
        Path(str(dst) + suffix).unlink(missing_ok=True)
    shutil.copy2(src, dst)
    wal = Path(str(src) + "-wal")
    if wal.exists():
        shutil.copy2(wal, Path(str(dst) + "-wal"))


def main() -> int:
    ROOT.mkdir(parents=True, exist_ok=True)
    sqlite_path = ROOT / "sqlite.db"
    duck_path = ROOT / "duck.db"
    print(f"assets={ASSETS} rounds={ROUNDS} duckdb={duckdb.__version__} "
          f"sqlite={sqlite3.sqlite_version} cpus={os.cpu_count()}")
    print(platform.platform())

    sqlite_import = build_sqlite(sqlite_path)
    print(f"sqlite import {sqlite_import:.1f}s  {sqlite_path.stat().st_size / 1e6:.1f} MB")
    duck_import = build_duck(duck_path)
    print(f"duckdb import {duck_import:.1f}s  {duck_path.stat().st_size / 1e6:.1f} MB")

    report = {
        "assets": ASSETS, "rounds": ROUNDS,
        "duckdb": duckdb.__version__, "sqlite": sqlite3.sqlite_version,
        "platform": platform.platform(), "cpus": os.cpu_count(),
        "import": {
            "sqlite_s": round(sqlite_import, 2), "duckdb_s": round(duck_import, 2),
        },
    }

    # Read-only panels.
    db = sqlite3.connect(sqlite_path)
    db.execute("PRAGMA cache_size=-262144")
    report["sqlite"] = {"file_mb": round(sqlite_path.stat().st_size / 1e6, 1),
                        "read": read_panel(db.execute)}
    report["sqlite"]["plans"] = {
        "first_page": explain("sqlite", sqlite_path, PAGE_ALL, (1,)),
        "project_page": explain("sqlite", sqlite_path, PAGE_PROJECT, (1, "p07", 3, 0.0)),
        "asset_lookup": explain("sqlite", sqlite_path, ASSET_LOOKUP, (1, "a0000007")),
    }
    db.close()

    db = sqlite3.connect(sqlite_path)
    db.execute("PRAGMA cache_size=-262144")
    db.execute("CREATE INDEX docs_time ON documents(gen, time_desc)")
    db.execute("CREATE INDEX docs_project_time ON documents(gen, project_id, time_asc)")
    db.execute("ANALYZE")
    report["sqlite_indexed"] = {"file_mb": round(sqlite_path.stat().st_size / 1e6, 1),
                                "read": read_panel(db.execute)}
    report["sqlite_indexed"]["plans"] = {
        "first_page": explain("sqlite", sqlite_path, PAGE_ALL, (1,)),
        "project_page": explain("sqlite", sqlite_path, PAGE_PROJECT, (1, "p07", 3, 0.0)),
        "asset_lookup": explain("sqlite", sqlite_path, ASSET_LOOKUP, (1, "a0000007")),
    }
    db.close()

    db = duckdb.connect(str(duck_path))
    db.execute("SET threads=8")
    report["duckdb"] = {"file_mb": round(duck_path.stat().st_size / 1e6, 1),
                        "read": read_panel(db.execute)}
    report["duckdb"]["plans"] = {
        "first_page": explain("duckdb", duck_path, PAGE_ALL, (1,)),
        "project_page": explain("duckdb", duck_path, PAGE_PROJECT, (1, "p07", 3, 0.0)),
        "asset_lookup": explain("duckdb", duck_path, ASSET_LOOKUP, (1, "a0000007")),
    }
    db.close()

    # Write panels on scratch copies.
    write_sqlite = ROOT / "write-sqlite.db"
    copy(sqlite_path, write_sqlite)
    report["sqlite"]["write_full"] = write_panel_sqlite(write_sqlite, "FULL")
    report["sqlite"]["commit_full"] = commit_cost("sqlite", write_sqlite, "FULL")
    # macOS: synchronous=FULL alone syncs the WAL with fsync(2). Only fullfsync=ON promotes
    # that to fcntl(F_FULLFSYNC), which is the call that actually flushes the drive cache.
    probe = sqlite3.connect(write_sqlite, isolation_level=None)
    report["sqlite"]["fullfsync_default"] = probe.execute("PRAGMA fullfsync").fetchone()[0]
    probe.close()
    report["sqlite"]["commit_fullfsync"] = commit_cost(
        "sqlite", write_sqlite, "FULL", fullfsync=True)
    report["sqlite"]["write_normal"] = write_panel_sqlite(write_sqlite, "NORMAL")
    report["sqlite"]["commit_normal"] = commit_cost("sqlite", write_sqlite, "NORMAL")
    write_sqlite.unlink(missing_ok=True)
    for suffix in ("-wal", "-shm"):
        Path(str(write_sqlite) + suffix).unlink(missing_ok=True)

    write_duck = ROOT / "write-duck.db"
    copy(duck_path, write_duck)
    report["duckdb"]["write"] = write_panel_duck(write_duck)
    report["duckdb"]["commit"] = commit_cost("duckdb", write_duck)
    report["duckdb"]["commit_full"] = commit_cost("duckdb", write_duck, fsync_mode="FULL")
    write_duck.unlink(missing_ok=True)
    Path(str(write_duck) + ".wal").unlink(missing_ok=True)

    # Operational.
    report["cold_open"] = {"sqlite": cold_open("sqlite", sqlite_path),
                           "duckdb": cold_open("duckdb", duck_path)}

    concurrent_sqlite = ROOT / "concurrent-sqlite.db"
    concurrent_duck = ROOT / "concurrent-duck.db"
    copy(sqlite_path, concurrent_sqlite)
    copy(duck_path, concurrent_duck)
    report["writers"] = {"sqlite": writers("sqlite", concurrent_sqlite),
                         "duckdb": writers("duckdb", concurrent_duck)}
    concurrent_sqlite.unlink(missing_ok=True)
    for suffix in ("-wal", "-shm"):
        Path(str(concurrent_sqlite) + suffix).unlink(missing_ok=True)
    concurrent_duck.unlink(missing_ok=True)
    Path(str(concurrent_duck) + ".wal").unlink(missing_ok=True)

    # Second process while this one holds the file open.
    report["second_process"] = {}
    keep = sqlite3.connect(sqlite_path, isolation_level=None)
    report["second_process"]["sqlite"] = second_process("sqlite", sqlite_path)
    keep.close()
    keep = duckdb.connect(str(duck_path))
    report["second_process"]["duckdb"] = second_process("duckdb", duck_path)
    keep.close()

    OUT.write_text(json.dumps(report, indent=2, ensure_ascii=False))
    print(f"\nwrote {OUT}")

    panels = [("sqlite", report["sqlite"]["read"]),
              ("sqlite+idx", report["sqlite_indexed"]["read"]),
              ("duckdb", report["duckdb"]["read"])]
    names = ["first_page", "project_page", "facet_rating", "facet_camera",
             "facet_rating_all", "facet_camera_all", "facet_tag_all", "tag_page",
             "name_prefix", "body_search", "hydrate", "asset_lookup"]
    print(f"\n{'read (ms)':20s}" + "".join(f"{label:>13s}" for label, _ in panels))
    for name in names:
        print(f"{name:20s}" + "".join(f"{panel[name]['median']:12.2f} " for _, panel in panels))
    print(f"\n{'write (ms)':20s}{'sqlite FULL':>13s}{'sqlite NORMAL':>15s}{'duckdb':>13s}")
    for name in ["point_update", "bulk_update", "insert_5k", "delete_5k", "checkpoint"]:
        print(f"{name:20s}"
              f"{report['sqlite']['write_full'][name]['median']:12.1f} "
              f"{report['sqlite']['write_normal'][name]['median']:14.1f} "
              f"{report['duckdb']['write'][name]['median']:12.1f} ")
    print(f"\n{'commit/row (ms)':20s}"
          f"{report['sqlite']['commit_full']['per_commit_ms']:12.3f} "
          f"{report['sqlite']['commit_normal']['per_commit_ms']:14.3f} "
          f"{report['duckdb']['commit']['per_commit_ms']:12.3f} ")
    print(f"F_FULLFSYNC commit: sqlite {report['sqlite']['commit_fullfsync']['per_commit_ms']:.3f} ms  "
          f"duckdb {report['duckdb']['commit_full']['per_commit_ms']:.3f} ms  "
          f"(sqlite fullfsync default={report['sqlite']['fullfsync_default']})")
    print(f"file MB: sqlite {report['sqlite']['file_mb']:.1f}  "
          f"duckdb {report['duckdb']['file_mb']:.1f}")
    print(f"cold open+page (ms): sqlite {report['cold_open']['sqlite']['median']:.2f}  "
          f"duckdb {report['cold_open']['duckdb']['median']:.2f}")
    print(f"writers: {json.dumps(report['writers'], ensure_ascii=False)}")
    print(f"second process: {json.dumps(report['second_process'], ensure_ascii=False)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
