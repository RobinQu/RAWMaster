from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
source = ROOT / "output/lightflow-research/site/assets/index-zP4kU_H7.js"
out_dir = ROOT / "output/lightflow-research/repair-analysis"
out_dir.mkdir(parents=True, exist_ok=True)
text = source.read_text(encoding="utf-8")

# Derived, non-executable reading view only. Preserve original bytes and insert line breaks
# at structural punctuation so that minified UI and inpainting code can be inspected by line.
pretty = []
quote = None
escaped = False
for ch in text:
    pretty.append(ch)
    if escaped:
        escaped = False
        continue
    if ch == "\\" and quote:
        escaped = True
        continue
    if quote:
        if ch == quote:
            quote = None
        continue
    if ch in "'\"`":
        quote = ch
    elif ch in ";{}":
        pretty.append("\n")
(out_dir / "editor.reading-view.js").write_text("".join(pretty), encoding="utf-8")

terms = [
    "inpaint", "Inpaint", "FillGpu", "strokeBox", "localGain", "holdPatch",
    "Detect Objects", "Generative", "Heal", "Clone", "Remove", "Retouch",
    "Brush Size", "Feather", "Opacity", "Show Overlay", "Visualize Spots",
]
lines = []
for term in terms:
    lines.append(f"\n===== {term} =====")
    for match in list(re.finditer(re.escape(term), text))[:40]:
        start = max(0, match.start() - 700)
        end = min(len(text), match.end() + 1200)
        lines.append(text[start:end])
(out_dir / "keyword-contexts.txt").write_text("\n\n".join(lines), encoding="utf-8")
print(f"source_bytes={len(text.encode('utf-8'))}")
print(f"reading_view={out_dir / 'editor.reading-view.js'}")
print(f"contexts={out_dir / 'keyword-contexts.txt'}")
