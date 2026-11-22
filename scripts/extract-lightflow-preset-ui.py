#!/usr/bin/env python3
import collections
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "output/lightflow-research/site/assets/index-zP4kU_H7.js"
OUT = ROOT / "output/lightflow-research/preset-analysis"
OUT.mkdir(parents=True, exist_ok=True)
text = SOURCE.read_text(encoding="utf-8")
commands = collections.Counter(re.findall(r"preset\.[A-Za-z_][A-Za-z0-9_]*", text))
preview_commands = collections.Counter(re.findall(r"preview\.[A-Za-z_][A-Za-z0-9_]*", text))
terms = ["Search presets", "Apply a preset to set its amount", "Favorites", "preset.save", "preview.set", "preview.end"]
chunks = []
for term in terms:
    starts = [match.start() for match in re.finditer(re.escape(term), text)]
    chunks.append(f"\n===== {term} ({len(starts)} occurrences) =====\n")
    for index, start in enumerate(starts[:8]):
        left = max(0, start - (9000 if term == "Search presets" else 2500))
        right = min(len(text), start + (14000 if term == "Search presets" else 4500))
        chunks.append(f"\n--- occurrence {index + 1}, offset {start} ---\n{text[left:right]}\n")
(OUT / "keyword-contexts.txt").write_text("".join(chunks), encoding="utf-8")
summary = {
    "source": str(SOURCE),
    "bytes": len(text.encode("utf-8")),
    "presetCommands": dict(commands.most_common()),
    "previewCommands": dict(preview_commands.most_common()),
    "termOccurrences": {term: len(list(re.finditer(re.escape(term), text))) for term in terms},
}
(OUT / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(json.dumps(summary, ensure_ascii=False, indent=2))
