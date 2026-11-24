"""Balanced release crossover, with reporting deferred until the transaction ends."""

from pathlib import Path
from statistics import median
import math
import os
import tempfile
from fixtures import cases, digest, drive


def measure(binaries, rounds):
    modes = ["scan", "address", "cached"]
    orders = [(0, 1, 2), (2, 1, 0), (1, 2, 0), (0, 2, 1), (2, 0, 1), (1, 0, 2)]
    case = next(s for s in cases.policies if s[0] == "empty-decoys-link")
    rows = []
    summary = {}
    sampled = []
    with tempfile.TemporaryDirectory(dir="/tmp") as tmp:
        for block in range(-1, rounds):
            for vm in [0, 4096] if block % 2 == 0 else [4096, 0]:
                for slot in orders[block % 6]:
                    arm = modes[slot]
                    folder = Path(tmp) / f"{block}-{vm}-{arm}"
                    case_result = drive(binaries, arm, case, vm, folder)
                    events = case_result["events"]
                    ack_count = 0
                    for action in events:
                        name = action["action"]
                        g = action["guards"]
                        if not g:
                            continue
                        if name == "acknowledgeItem":
                            ack_count += 1
                            name += "/commit" if ack_count == 1 else "/replay"
                        w = [p for p in g if p["state"] == 2]
                        assert (
                            w
                            and all(p["allowed"] for p in g)
                            and len({p["holdNs"] for p in w}) == 1
                        )
                        begin = next(p for p in g if p["phase"] == "read")
                        end = w[-1]
                        record = {
                            "round": block,
                            "arm": arm,
                            "stressVMAs": vm,
                            "action": name,
                            "holdNs": end["holdNs"],
                            "guardNsInWrite": sum(p["guardNs"] for p in w),
                            "readGuardNs": begin["guardNs"],
                            "scansInWrite": end["mapScans"] - begin["mapScans"],
                            "queriesInWrite": end["mapQueries"] - begin["mapQueries"],
                            "scanBytesInWrite": end["mapBytes"] - begin["mapBytes"],
                            "readScanLines": begin["mapLines"],
                            "beginningWALBytes": begin["walBytes"],
                            "jpegSHA256": case_result["finalSHA256"],
                        }
                        if block >= 0:
                            rows.append(record)
                    if block == 0:
                        sampled.append(
                            {
                                "arm": arm,
                                "stressVMAs": vm,
                                "ready": case_result["delivered"],
                                "duplicateAck": case_result[
                                    "idempotentAcknowledgement"
                                ],
                                "sha256": case_result["finalSHA256"],
                            }
                        )
            print("round", block, flush=True)
    for key in sorted({(r["stressVMAs"], r["action"], r["arm"]) for r in rows}):
        vm, action, arm = key
        group = [s for s in rows if (s["stressVMAs"], s["action"], s["arm"]) == key]
        ordered = sorted(r["holdNs"] for r in group)
        q95 = ordered[math.ceil(len(ordered) * 0.95) - 1]
        summary.setdefault(str(vm), {}).setdefault(action, {})[arm] = {
            "n": len(group),
            "p50HoldUs": round(median(ordered) / 1000, 3),
            "p95HoldUs": round(q95 / 1000, 3),
            "p50WriteGuardUs": round(
                median(r["guardNsInWrite"] for r in group) / 1000, 3
            ),
            "p50ReadGuardUs": round(median(r["readGuardNs"] for r in group) / 1000, 3),
            "p50ScannedBytesInWrite": median(r["scanBytesInWrite"] for r in group),
            "p50AddressQueriesInWrite": median(r["queriesInWrite"] for r in group),
        }
    result = {
        "kernel": os.uname().release,
        "runtimeSHA256": digest(binaries / "librawmaster_library.so"),
        "method": "One discarded round per arm and VMA count, then balanced order; held interval begins after BEGIN IMMEDIATE succeeds and ends after sqlite commit returns. All JSON reporting to stderr deferred until after transaction.",
        "rounds": rounds,
        "records": rows,
        "samples": sampled,
        "summary": summary,
    }

    return result
