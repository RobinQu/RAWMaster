from pathlib import Path
import json
import re

root = Path(__file__).resolve().parents[1]
log_path = root / "Validation" / "full-suite.log"
text = log_path.read_text(encoding="utf-8")
records = []
pattern = re.compile(r"MODEL_RESULT\s+(\S+)\s+coverage=([0-9.]+)\s+pixels=(\d+)\s+ms=([0-9.]+)\s+notes=\[(.*)\]")
for line in text.splitlines():
    match = pattern.search(line)
    if not match:
        continue
    records.append({
        "name": match.group(1),
        "coverage": float(match.group(2)),
        "selectedPixels": int(match.group(3)),
        "elapsedMilliseconds": float(match.group(4)),
        "notes": match.group(5),
    })
summary = {
    "suite": "MASK_AI_MODEL_TESTS=1 swift test",
    "testCount": 13,
    "failures": 0 if "Executed 13 tests, with 0 failures" in text else None,
    "records": records,
    "maximumResidentSetBytes": None,
    "peakMemoryBytes": None,
}
rss = re.search(r"^\s*(\d+)\s+maximum resident set size", text, re.MULTILINE)
if rss:
    summary["maximumResidentSetBytes"] = int(rss.group(1))
peak = re.search(r"^\s*(\d+)\s+peak memory footprint", text, re.MULTILINE)
if peak:
    summary["peakMemoryBytes"] = int(peak.group(1))
output = root / "Validation" / "results.json"
output.write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
print(f"Wrote {output} with {len(records)} model results; peakMemoryBytes={summary['peakMemoryBytes']}")
