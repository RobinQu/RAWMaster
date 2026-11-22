"""Run one explicit Ark image edit per case, with opt-in repeats and redacted receipts."""

import argparse
import base64
import getpass
import hashlib
import io
import json
import os
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

from PIL import Image


MODEL = "doubao-seedream-5-5-261028"
ENDPOINT = "https://ark.cn-beijing.volces.com/api/v3/images/generations"
CASES = json.loads(Path(__file__).with_name("cases.json").read_text())["cases"]


class RejectRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def request_one(case, input_dir, output_dir, secret):
    edit = CASES[case.removesuffix("-repeat")]
    data = (input_dir / edit["input"]).read_bytes()
    options = dict(model=MODEL, size="1024x1024", response_format="b64_json",
                   output_format="png", background="opaque", watermark=False)
    body = dict(options, prompt=edit["prompt"], image="data:image/png;base64," + base64.b64encode(data).decode("ascii"))
    request = urllib.request.Request(ENDPOINT, data=json.dumps(body).encode(), method="POST",
                                     headers={"Authorization": "Bearer " + secret, "Content-Type": "application/json"})
    receipt = dict(case=case, started_utc=datetime.now(timezone.utc).isoformat(), options=options,
                   input_sha256=hashlib.sha256(data).hexdigest(),
                   prompt_sha256=hashlib.sha256(edit["prompt"].encode()).hexdigest())
    start = time.monotonic()
    try:
        opener = urllib.request.build_opener(RejectRedirect)
        with opener.open(request, timeout=240) as response:
            payload = response.read(64 * 1024 * 1024)
            receipt.update(http=response.status, request_id=response.getheader("x-request-id") or response.getheader("x-tt-logid"))
        receipt["http_seconds"] = round(time.monotonic() - start, 3)
        result = json.loads(payload)
        receipt.update(model_returned=result.get("model"), usage=result.get("usage", {}))
        if len(result.get("data", [])) != 1:
            raise ValueError("single-image response required")
        item = result["data"][0]
        if item.get("error"):
            receipt["provider_error_code"] = item["error"].get("code")
            raise ValueError("no usable image")
        image = base64.b64decode(item["b64_json"], validate=True)
        with Image.open(io.BytesIO(image)) as decoded:
            decoded.load()
            receipt.update(size=list(decoded.size), mode=decoded.mode, format=decoded.format,
                           icc=bool(decoded.info.get("icc_profile")))
            if decoded.size != (1024, 1024) or decoded.format != "PNG":
                raise ValueError("unexpected output dimensions or encoding")
        (output_dir / (case + ".png")).write_bytes(image)
        receipt.update(output_sha256=hashlib.sha256(image).hexdigest(), output_bytes=len(image), status="decoded")
    except urllib.error.HTTPError as error:
        receipt.update(http=error.code, request_id=error.headers.get("x-request-id") or error.headers.get("x-tt-logid"))
        try:
            receipt["provider_error_code"] = json.loads(error.read(64 * 1024))["error"]["code"]
        except (ValueError, KeyError, TypeError):
            pass
        receipt["status"] = "http-error"
    except (ValueError, KeyError, OSError, TypeError) as error:
        receipt.update(status="outcome-unknown", error_type=type(error).__name__)
    receipt["elapsed_seconds"] = round(time.monotonic() - start, 3)
    (output_dir / (case + ".json")).write_text(json.dumps(receipt, indent=2, ensure_ascii=False) + "\n")
    print(case, receipt["status"], receipt.get("http"), receipt.get("provider_error_code", ""), receipt["elapsed_seconds"], flush=True)
    return receipt["status"] == "decoded"


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inputs", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("cases", nargs="+", choices=[*CASES, "lake-repeat"])
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    secret = os.getenv("ARK_API_KEY") or getpass.getpass("Ark API key (hidden): ")
    for case in args.cases:
        if (args.out / (case + ".json")).exists():
            raise SystemExit("An attempt already has a receipt. Choose a new output directory for a new run.")
        if not request_one(case, args.inputs, args.out, secret):
            raise SystemExit(1)
