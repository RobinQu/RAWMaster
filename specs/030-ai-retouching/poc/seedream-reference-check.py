"""Send one public target + one public lighting reference to the pinned Beijing endpoint."""
import argparse
import base64
import getpass
import hashlib
import io
import json
import os
from pathlib import Path
import time
import urllib.error
import urllib.request

from PIL import Image
from seedream import ENDPOINT, MODEL, RejectRedirect

CASES = {"portrait": ("relight", "photo", (1024, 1024)), "lake": ("landscape", "transferred", (1248, 832))}


def submit(case, evidence, output, key):
    folder, label, size = CASES[case]
    frozen = json.loads((evidence / folder / "runs.json").read_text())["cases"][label]
    refs = frozen["references"]
    images = []
    for item in refs:
        payload = (evidence / folder / item["file"]).read_bytes()
        if hashlib.sha256(payload).hexdigest() != item["sha256"]:
            raise ValueError("Unexpected frozen image")
        images.append("data:image/png;base64," + base64.b64encode(payload).decode("ascii"))
    options = {"model": MODEL, "size": f"{size[0]}x{size[1]}", "output_format": "png",
               "watermark": False, "response_format": "b64_json", "background": "opaque"}
    receipt = {"case": case, "options": options, "referencesInRequestOrder": refs, "prompt": frozen["prompt"]}
    receipt_path = output / (case + ".json")
    if receipt_path.exists():
        raise FileExistsError("Use a new output directory for a new attempt")
    request = urllib.request.Request(ENDPOINT, method="POST", headers={
        "Authorization": "Bearer " + key, "Content-Type": "application/json"},
        data=json.dumps({**options, "image": images, "prompt": frozen["prompt"]}).encode())
    start = time.monotonic()
    try:
        with urllib.request.build_opener(RejectRedirect).open(request, timeout=180) as response:
            receipt["http"] = response.status
            receipt["requestId"] = response.getheader("x-request-id") or response.getheader("x-tt-logid")
            result = json.loads(response.read(64 * 1024 * 1024))
        receipt["httpSeconds"] = round(time.monotonic() - start, 3)
        receipt["modelReturned"] = result.get("model")
        receipt["usage"] = result.get("usage", {})
        if len(result.get("data", [])) != 1:
            raise ValueError("Expected one output")
        data = base64.b64decode(result["data"][0]["b64_json"], validate=True)
        with Image.open(io.BytesIO(data)) as image:
            image.load()
            if image.size != size or image.format != "PNG":
                raise ValueError("Size or format mismatch")
            receipt["mode"] = image.mode
        (output / (case + ".png")).write_bytes(data)
        receipt["sha256"] = hashlib.sha256(data).hexdigest()
        receipt["status"] = "decoded"
    except urllib.error.HTTPError as error:
        receipt.update(http=error.code, status="http-error", requestId=error.headers.get("x-request-id"))
        try:
            receipt["providerCode"] = json.loads(error.read(65536))["error"]["code"]
        except (KeyError, ValueError, TypeError):
            pass
    except (ValueError, OSError, KeyError, TypeError) as error:
        receipt.update(status="outcome-unknown", errorType=type(error).__name__)
    receipt["elapsedSeconds"] = round(time.monotonic() - start, 3)
    receipt_path.write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n")
    print(case, receipt["status"], receipt.get("http"), receipt.get("providerCode", ""), receipt["elapsedSeconds"], flush=True)
    return receipt["status"] == "decoded"


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("cases", nargs="+", choices=CASES)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    key = os.environ.get("ARK_API_KEY") or getpass.getpass("Ark key (hidden): ")
    for name in args.cases:
        if not submit(name, args.evidence, args.output, key):
            raise SystemExit(1)
