#!/usr/bin/env python3
"""Re-fetch the pinned public LightFlow site, verify every file, and record the receipt."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from hashlib import sha256
import json
from pathlib import Path
import subprocess
from urllib.parse import urlsplit


PINS = Path(__file__).with_name("lightflow-release.json")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path, help="directory for the local site and receipt.json")
    args = parser.parse_args()
    root = args.destination / "site"
    rows = json.loads(PINS.read_bytes())["files"]

    def fetch(row):
        rel = Path(row["path"])
        url = row["url"]
        if rel.is_absolute() or ".." in rel.parts or urlsplit(url).netloc != "lightflow.dev":
            raise ValueError(f"Unexpected resource {rel}")
        data = subprocess.check_output(["curl", "--fail", "--silent", "--show-error", "--retry", "2",
                                        "--max-time", "90", "--location", "--proto-redir", "=https", url])
        digest = sha256(data).hexdigest()
        if digest != row["sha256"] or len(data) != row["bytes"]:
            raise ValueError(f"Release changed at {url}: bytes={len(data)}, sha256={digest}")
        target = root / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        return {"path": str(rel), "bytes": len(data), "sha256": digest}

    # Check the live entry first so a new release cannot be mistaken for this build.
    homepage = next(row for row in rows if row["path"] == "index.html")
    files = [fetch(homepage)]
    with ThreadPoolExecutor(max_workers=6) as pool:
        files.extend(pool.map(fetch, (row for row in rows if row != homepage)))
    files.sort(key=lambda row: row["path"])
    receipt = {"origin": "https://lightflow.dev/", "build": "20261111155800-2d41ab1",
               "finishedUTC": datetime.now(timezone.utc).isoformat(), "fileCount": len(files),
               "fileBytes": sum(r["bytes"] for r in files), "pinsSHA256": sha256(PINS.read_bytes()).hexdigest(),
               "files": files}
    (args.destination / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(f"{receipt['fileCount']} files, {receipt['fileBytes']} verified bytes in {root}")


if __name__ == "__main__":
    main()
