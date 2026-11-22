"""Read a private online backup with the production Rust page API. Compare status delivery for the same 60 IDs."""
import argparse
import contextlib
import ctypes
import datetime as dt
import hashlib
import json
import math
import pathlib
import platform
import sqlite3
import statistics
import tempfile
import time

from verify import Host


class OwnedBytes(ctypes.Structure):
    _fields_ = [("data", ctypes.c_void_p), ("length", ctypes.c_size_t)]


class Reader:
    def __init__(self, dylib, source, index):
        self.lib = ctypes.CDLL(str(dylib.resolve()))
        self.lib.rm_library_request_v1.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p,
                                                   ctypes.c_size_t, ctypes.POINTER(OwnedBytes)]
        self.lib.rm_library_request_v1.restype = ctypes.c_int32
        self.lib.rm_library_release_v1.argtypes = [ctypes.POINTER(OwnedBytes)]
        self.lib.rm_library_release_v1.restype = None
        self.path = bytes(source)
        self.request = json.dumps({"operation": "page", "indexPath": str(index), "request": {"pageSize": 60}}).encode()

    def page(self):
        reply = OwnedBytes()
        status = self.lib.rm_library_request_v1(self.path, len(self.path), self.request, len(self.request), ctypes.byref(reply))
        try:
            page = json.loads(ctypes.string_at(reply.data, reply.length))
            assert status == 0 and page["status"] == "ok", page.get("error")
            return page
        finally:
            self.lib.rm_library_release_v1(ctypes.byref(reply))


def run(args, root, stack):
    copy = root / "catalog.sqlite"
    with contextlib.closing(sqlite3.connect(args.catalog.resolve().as_uri() + "?mode=ro", uri=True)) as source, \
         contextlib.closing(sqlite3.connect(copy)) as snapshot:
        source.backup(snapshot)
        total_assets = snapshot.execute("SELECT COUNT(*) FROM assets").fetchone()[0]
    catalog_sha = hashlib.sha256(copy.read_bytes()).hexdigest()
    # A restored WAL catalog may have no sidecars until the writable app host opens it.
    keeper = stack.enter_context(contextlib.closing(sqlite3.connect(copy)))
    assert keeper.execute("PRAGMA journal_mode=WAL").fetchone() == ("wal",)
    assert keeper.execute("PRAGMA user_version").fetchone() == (8,)
    reader = Reader(args.dylib, copy, root / "cache" / "index.sqlite")
    first = reader.page()
    file_ids = [item["fileID"] for item in first["items"]]
    assert len(file_ids) == len(set(file_ids)) == 60, "benchmark needs 60 distinct files on its first page"
    with contextlib.closing(Host(args.queue.resolve(), root / "queue.sqlite")) as host:
        for key in file_ids:
            host.submit(key, "library", "cpu")
        for _ in range(20):
            host.finish(host.send("claim"), result="indexed")
        expected = [host.send("status", key=key) for key in file_ids]
        assert host.send("statuses", keys=[file_ids[0], "missing", file_ids[0]]) == [expected[0], None, expected[0]]
        assert host.send("statuses", keys=[]) == []
        methods = ["pageOnly", "pageAnd60StatusCalls", "pageAndOneStatusCall"]
        samples = {name: [] for name in methods}
        for i in range(33):
            for method in methods[i % 3:] + methods[:i % 3]:
                before = time.perf_counter_ns()
                ids = [item["fileID"] for item in reader.page()["items"]]
                states = None
                if method == "pageAndOneStatusCall":
                    states = host.send("statuses", keys=ids)
                elif method == "pageAnd60StatusCalls":
                    states = [host.send("status", key=k) for k in ids]
                elapsed = (time.perf_counter_ns() - before) / 1e6
                assert ids == file_ids and (states is None or states == expected)
                if i >= 3:
                    samples[method].append(round(elapsed, 3))
    def summary(values):
        return {"p50ms": round(statistics.median(values), 3),
                "p95msNearestRank": sorted(values)[math.ceil(len(values) * .95)-1], "samplesMs": values}
    return {"measuredAtUTC": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
            "host": platform.platform(), "sqliteSnapshotSHA256": catalog_sha,
            "catalogDylibSHA256": hashlib.sha256(args.dylib.read_bytes()).hexdigest(),
            "catalogAssets": total_assets, "matchedFiles": first["totalFiles"], "page": len(file_ids),
            "settledJobs": 20, "queuedJobs": 40, "freshPageOnEveryRead": True, "warmupPerMethod": 3,
            "nPerMethod": 30, "allStatusesAndOrderMatched": True, "methods": {k: summary(v) for k, v in samples.items()}}


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    for name in ("catalog", "dylib", "queue"):
        p.add_argument(name, type=pathlib.Path)
    with tempfile.TemporaryDirectory() as directory, contextlib.ExitStack() as stack:
        print(json.dumps(run(p.parse_args(), pathlib.Path(directory), stack), indent=2))
