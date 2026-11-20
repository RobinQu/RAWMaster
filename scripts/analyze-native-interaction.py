#!/usr/bin/env python3
"""Summarize measured native preview completion events from an interaction trace."""

import hashlib
import json
import sys
from pathlib import Path


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: analyze-native-interaction.py INPUT.jsonl OUTPUT.json")
    source = Path(sys.argv[1])
    destination = Path(sys.argv[2])
    payload = source.read_bytes()
    events = [json.loads(line) for line in payload.splitlines() if line.strip()]
    completions = []
    for event in events:
        if event.get("event") != "preview.draw-return":
            continue
        completions.append({
            key: event.get(key)
            for key in (
                "operationID", "frameID", "control", "eventAssociation",
                "inputKind", "inputOrigin", "revision", "displayedRevision",
                "requestedRevision", "revisionLag", "quality", "outcome",
                "pixelWidth", "pixelHeight", "inputToDrawReturnMilliseconds",
                "parameterToDrawReturnMilliseconds", "metricBoundary",
                "paneVisibility", "uptimeSeconds",
            )
        })
    shutdown = [event for event in events if event.get("event") == "preview.cache.shutdown-summary"]
    result = {
        "schemaVersion": 1,
        "tracePath": str(source),
        "traceSHA256": hashlib.sha256(payload).hexdigest(),
        "traceEventCount": len(events),
        "drawReturnCount": len(completions),
        "drawReturns": completions,
        "shutdownSummaries": shutdown,
        "caution": "AppKit draw-return only; not WindowServer presentation and not a cross-application speed comparison.",
    }
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
