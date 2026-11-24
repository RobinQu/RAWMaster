#!/usr/bin/env python3
"""Join every Camera Raw feature to its measurement evidence and verify offline reference receipts."""
import argparse
import base64
from contextlib import closing
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import runpy
import sqlite3
import struct
import sys

ROOT = Path(__file__).resolve().parents[2]
PARITY = ROOT / "docs/research/camera-raw-parity"
SPEC = ROOT / "specs"
FLUX = "black-forest-labs/flux-3-image-klein"
ARK = "doubao-seedream-5-5-261028"
PRODUCTS = {"LightFlow", "RAWMaster", "Camera Raw"}


def read(path):
    return json.loads(path.read_text(encoding="utf-8"))


def check(ok, message):
    if not ok:
        raise ValueError(message)


def by(rows, key):
    result = {key(row): row for row in rows}
    check(len(result) == len(rows), "duplicate measurement or feature ID")
    return result


def sha(value):
    return isinstance(value, str) and re.fullmatch(r"[a-f0-9]{64}", value)


def file_sha(path):
    with path.open("rb") as handle:
        digest = hashlib.sha256()
        while block := handle.read(1024 * 1024):
            digest.update(block)
        return digest.hexdigest()


def reference_receipts():
    frozen = SPEC / "031-preset-browser"
    manifest = frozen / "contracts/migration-manifest-v1.json"
    data = read(frozen / "evidence/frozen-exchange/receipt.json")
    check(file_sha(manifest) == data["manifestSHA256"], "031 migration manifest changed")
    entries = by(read(manifest)["entries"], lambda row: row["sha256"])
    check(len(entries) == data["counts"]["productionVerifiedOriginals"] == 78, "031 migration cardinality")
    check(sum(row["bytes"] for row in entries.values()) == data["counts"]["productionVerifiedOriginalBytes"],
          "031 retained XMP byte count")
    check(data["all80CatalogFileSHA256StableAcrossReplays"] and data["counts"]["productionInsertedOnReplay"] == 0,
          "031 missing idempotent migration evidence")
    quick = SPEC / "034-quick-prompt-editing/poc"
    transport = by(read(quick / "provider-results.json")["runs"], lambda r: (r["model"], r["scope"]))
    archive = by(read(quick / "archive-results.json")["tests"], lambda r: (r["model"], r["scope"]))
    check(set(transport) == set(archive) == {(m, s) for m in (FLUX, ARK) for s in ("whole", "region")},
          "034 missing provider/scope")
    for (model, scope), run in transport.items():
        check(run["reconciled"] and all(sha(run[k]) for k in ("inputSHA256", "promptSHA256", "outputSHA256")),
              f"034 {model}/{scope} incomplete provider identity")
        check(run["sameSHAAsCLI"] if model == FLUX else run["httpPOSTs"] == 1, "034 provider replay")
        result = archive[model, scope]
        check(result["attempts"] == 1 and result["sourceUnchanged"] and result["adoptUndoReopened"] and
              all(sha(result[k]) for k in ("inputSHA256", "originalSHA256", "receivedSHA256", "archivedSHA256")),
              f"034 {model}/{scope} incomplete archive identity")
        if scope == "region":
            check(result["archivedBitDepth"] == 16 and result["protectedPixels"] > 0 and result["changedPixelsInSelection"] > 0
                  and result["protectedChannelDifferences"] == 0, "034 ROI protected pixels")
    return {"presetFrozen": len(entries), "promptProviderCases": len(transport), "promptArchiveCases": len(archive)}


def candidate_controls(directory):
    current, groups = runpy.run_path(str(ROOT / "scripts/check-control-performance.py"))["load"](directory / "controls.json")
    build = read(directory / "test-build.json")
    check(build["build"] == "Release" and current["binarySHA256"] == build["testBinariesSHA256"]["RAWMasterImagingTests"],
          "candidate controls do not match the supplied Release test bundle")
    summary_file = directory / "summary.json"
    summary = read(summary_file) if summary_file.exists() else {}
    provenance = {"binarySHA256": current["binarySHA256"], "uiTestBinarySHA256": build["testBinariesSHA256"]["RAWMasterUITests"],
                  "sourceSHA256": current["sourceSHA256"],
                  "protocol": current["protocol"], "officialReleasePassed": summary.get("passed"),
                  "officialReleaseStatus": summary.get("status"), "regressionPassed": summary.get("regressionPassed"),
                  "timingGatesRequired": summary.get("timingGatesRequired"), "hostedUI": summary.get("hostedUI")}
    ui_file = directory / "ui.json"
    if ui_file.is_file():
        ui = read(ui_file)
        provenance["ui"] = {"mode": ui.get("mode"), "boundary": ui.get("boundary")}
    rows = {k: {"state": "measured" if row else "inconclusive", "evidence": str(directory / "controls.json"),
                "boundary": "resident 2400px control return", "measurement": row} for k, row in groups.items()}
    provenance["featureInputs"] = {"residentControls": len(rows)}
    inspection = directory / "inspection.json"
    if inspection.is_file():
        data, observations = runpy.run_path(str(ROOT / "scripts/check-inspection-performance.py"))["qualify"](inspection)
        check(data["sourceSHA256"] == current["sourceSHA256"] and
              data["binarySHA256"] == build["testBinariesSHA256"]["RAWMasterUITests"],
              "candidate inspection does not match this source and UI test bundle")
        check(not rows.keys() & observations.keys(), "duplicate control/inspection measurements")
        rows.update({k: {**row, "evidence": str(inspection)} for k, row in observations.items()})
        provenance["featureInputs"]["inspection"] = len(observations)
    rendered = directory / "rendered-controls.json"
    if rendered.is_file():
        witness = runpy.run_path(str(ROOT / "scripts/performance/rendered_control_witness.py"))
        data, _ = witness["load"](rendered)
        check(data["binarySHA256"] == build["testBinariesSHA256"]["RAWMasterImagingTests"],
              "candidate rendered-file controls do not match this Release test bundle")
        observed = witness["rendered_rows"](rendered, str(rendered))
        check(not rows.keys() & observed.keys(), "duplicate resident and rendered-file controls")
        rows.update(observed)
        provenance["featureInputs"]["renderedControls"] = sum(v["state"] == "measured" for v in observed.values())
    super_report = directory / "super-resolution.json"
    if super_report.is_file():
        data, metrics = runpy.run_path(str(ROOT / "scripts/check-super-resolution-performance.py"))["qualify"](super_report)
        check(data["rawSHA256"] == current["sourceSHA256"], "candidate super-resolution used a different source")
        # The 2x report has no executable digest of its own. Bind the actual frozen test product used by the driver.
        binary = directory / "test-products/RAWMasterImagingTests.xctest/Contents/MacOS/RAWMasterImagingTests"
        command = directory / "super-resolution.command.json"
        if binary.is_file() and command.is_file():
            outcome = read(command)
            check(file_sha(binary) == current["binarySHA256"] and outcome.get("status") == "passed" and outcome.get("exitCode") == 0,
                  "candidate super-resolution execution or frozen test product mismatch")
            state = "measured"
        else:
            state = "unbound-test-product"
        rows["detail-super-resolution"] = {"state": state, "evidence": str(super_report),
            "boundary": "normal export through complete learned 2x TIFF16", "measurement": metrics}
        provenance["featureInputs"]["superResolution"] = state
    return rows, provenance


def feature_report(release=None):
    catalog = read(PARITY / "feature-matrix.json")
    performance = read(PARITY / "performance-data.json")
    features = by(catalog["features"], lambda r: r["id"])
    measured = by(performance["controlMatrix"]["controls"], lambda r: r["id"])
    check(features.keys() == measured.keys(), "Camera Raw catalog and performance ID sets differ")
    observations, build = candidate_controls(release) if release else ({}, None)
    rows = []
    for fid, feature in features.items():
        history = measured[fid]
        check(feature["status"] == history["implementation"] and feature["panel"] == history["panel"], f"wrong join: {fid}")
        check(set(history["products"]) == PRODUCTS and set(history["canvas"]) <= PRODUCTS, f"wrong products: {fid}")
        for sample in [*history["products"].values(), *history["canvas"].values()]:
            if sample.get("evidence"):
                check((PARITY / sample["evidence"]).is_file(), f"{fid}: missing {sample['evidence']}")
            if sample.get("state") == "measured":
                check(sample.get("boundary") and sample.get("evidence"), f"{fid}: incomplete clock boundary")
        rows.append({"id": fid, "panel": feature["panel"], "name": feature["name"], "status": feature["status"],
                     "contract": feature["acceptance"], "difference": feature["difference"], "codeRefs": feature["codeRefs"],
                     "historicalProcessing": history["products"], "historicalCanvas": history["canvas"],
                     "candidateProcessing": observations.get(fid, {"state": "no-control-receipt"})})
    processing = sum(all(p["state"] == "measured" for p in row["historicalProcessing"].values()) for row in rows)
    screens = sum(all(row["historicalCanvas"].get(p, {}).get("state") == "measured" for p in PRODUCTS) for row in rows)
    gate = performance["parityGate"]
    check((processing, screens) == (gate["threeProductProcessingRows"], gate["threeProductScreenRows"]),
          "published coverage differs from per-ID measurements")
    return {"baseline": catalog["meta"]["cameraRawBaseline"], "panels": dict(Counter(r["panel"] for r in rows)),
            "features": len(rows), "historicalProcessingThreeWay": processing, "historicalCanvasThreeWay": screens,
            "historicalParityGate": gate, "references": reference_receipts(), "candidateBuild": build,
            "candidateMeasuredFeatureIDs": sum(r["candidateProcessing"]["state"] == "measured" for r in rows),
            "candidateControlIDsOutsideFeatureCatalog": sorted(observations.keys() - features.keys()), "rows": rows}


def verify_adaptive(root):
    expected = {"subject": ("c21d5229b88db9cce13c58c47fbe9f44980753a601a5f7897b91f3ce47eb7f6d",
                            "0a0775e6f803329341b954fd4d0ed08d6cc71b3b226c34d0218865761e31f0d8"),
                "sky": ("055748f89e720487be706f9c501962b1dde87d9f5181c24f5bd4c07a6883bfcd",
                        "4e7e80f4e34e3f9d2b77c93c4c0864fb2a8b950df69e615b5e99b7bad6a9739f")}
    binaries = set()
    common = "8f96d2fd4fa0c76741ee09b486a4a5e17c8c893ce714060f2fe65eb34c891e1c"
    for target, (xmp, second) in expected.items():
        directory = root / target
        record = read(directory / "receipt.json")
        check(record["target"] == target and record["status"] == "passed" and record["build"] == "release" and
              record["sourceXmpSHA256"] == xmp and record["crossPhotoAdoptionRejected"], f"{target}: missing preset or rejection")
        check(sha(record["testBinarySHA256"]), f"{target}: missing test binary")
        binaries.add(record["testBinarySHA256"])
        photos = by(record["photos"], lambda p: p["sourceSHA256"])
        check(set(photos) == {common, second} and len({p["pngSHA256"] for p in photos.values()}) == 2, f"{target}: shared coverage")
        for photo_id, row in photos.items():
            folder = directory / photo_id[:12]
            check(read(folder / "receipt.json") == row and row["presetSHA256"] == xmp and row["sourceSHA256After"] == photo_id,
                  f"{target}: photo receipt mismatch")
            stats, pixels, output = row["analysis"], row["pixelComparison"], row["export"]
            check(stats["sourceContentID"] == photo_id and stats["successfulGenerations"] == stats["flashRawDecodes"] == 1
                  and stats["exactHits"] == 0 and stats["modelInvocations"] > 0
                  and stats["visionRequests" if target == "subject" else "landscapeRuns"] > 0, f"{target}: missing fresh inference")
            check(sha(row["recipeSHA256"]) and sha(row["pngSHA256"]) and
                  row["modelInvocationsAtReopenedDraw"] == row["modelInvocationsAfterExport"] == 0,
                  f"{target}: offline replay evidence")
            check(pixels["protectedPixels"] > 0 and pixels["protectedMaximumRGBA16Difference"] == 0 and
                  pixels["selectedChangedRGBPixels"] > 0 and output["bitsPerComponent"] == 16 and
                  [output["width"], output["height"]] == [stats["orientedWidth"], stats["orientedHeight"]],
                  f"{target}: incomplete TIFF16 pixel evidence")
            outputs = [(output["file"], output["sha256"]), ("disabled-layer-control.tiff", row["controlTIFFSHA256"])]
            if not row["toggleUsesSameRenderer"]:
                outputs.append(("same-renderer-zero-coverage.tiff", row["zeroCoverageTIFFSHA256"]))
            for name, digest in outputs:
                check(Path(name).name == name and sha(digest) and file_sha(folder / name) == digest,
                      f"{target}: output digest mismatch for {name}")
    check(len(binaries) == 1, "Adaptive receipts use different builds")
    return {"cases": 4, "testBinarySHA256": binaries.pop()}


def export_named_coverage_fixtures(root, destination):
    source_hash = "8f96d2fd4fa0c76741ee09b486a4a5e17c8c893ce714060f2fe65eb34c891e1c"
    source = {"sourceContentID": source_hash, "exifOrientation": 1, "orientedWidth": 9504, "orientedHeight": 6336}
    bindings = []
    prepared = []
    for role in ("sky", "subject"):
        directory = root / role
        library = directory / "library.sqlite"
        wal = directory / "library.sqlite-wal"
        check(library.is_file() and (not wal.exists() or wal.stat().st_size == 0), f"{role}: expected a closed, checkpointed test library")
        photo = directory / source_hash[:12] / "receipt.json"
        receipt = read(photo)
        with closing(sqlite3.connect(library.resolve().as_uri() + "?mode=ro&immutable=1", uri=True)) as connection:
            [row] = connection.execute(
                """SELECT w.data FROM editing_works w JOIN assets a ON a.id=w.asset_id
                   WHERE json_extract(a.data,'$.contentHash')=?""", (source_hash,),
            ).fetchall()
        [work_json] = row
        work = json.loads(work_json)
        [layer] = work["liveRecipe"]["adjustmentsV3"]["masks"]
        [adoption] = work["livePresetAdoptions"]
        snapshot = layer["semanticSnapshot"]
        png = base64.b64decode(layer["subjectPNG"], validate=True)
        checksum = hashlib.sha256(png).hexdigest()
        check(work["source"]["contentSHA256"] == adoption["sourceID"] == source_hash and snapshot["source"] == source,
              f"{role}: saved layer is bound to another source")
        check(layer["enabled"] and layer["kind"] == "subject" and snapshot["target"] == role and
              snapshot["pngSHA256"] == receipt["pngSHA256"] == checksum and checksum in adoption["assetHashes"] and
              adoption["resultFingerprint"] == receipt["recipeSHA256"] and adoption["sourceSHA256"] == receipt["presetSHA256"] and
              snapshot["modelHashes"] == receipt["modelHashes"] and snapshot["analysisDecoder"] == receipt["analysis"]["decoder"],
              f"{role}: saved mask diverged from the verified Adaptive receipt")
        bindings.append({"id": layer["id"].lower(), "role": role, "snapshot": snapshot, "receiptSHA256": file_sha(photo)})
        prepared.append((role, layer, png))
    destination.mkdir()
    for role, layer, png in prepared:
        (destination / (role + ".layer.json")).write_text(json.dumps(layer, sort_keys=True) + "\n", encoding="utf-8")
        (destination / (role + ".png")).write_bytes(png)
    (destination / "bindings.json").write_text(json.dumps(bindings, indent=2) + "\n", encoding="utf-8")


def tiff16_rows(path):
    """Read the uncompressed contiguous RGBA16 strips used by the 034/035 regional compositor."""
    body = path.read_bytes()
    check(body[:2] in (b"II", b"MM"), f"invalid TIFF byte order: {path.name}")
    order = "<" if body[:2] == b"II" else ">"
    magic, directory = struct.unpack_from(order + "HI", body, 2)
    check(magic == 42, f"expected classic TIFF: {path.name}")
    count, = struct.unpack_from(order + "H", body, directory)
    tags = {}
    for index in range(count):
        entry = directory + 2 + index * 12
        tag, kind, size = struct.unpack_from(order + "HHI", body, entry)
        if tag not in (256, 257, 258, 259, 262, 273, 274, 277, 279, 284):
            continue
        check(kind in (3, 4) and size > 0, f"invalid TIFF tag {tag}")
        width, code = (2, "H") if kind == 3 else (4, "I")
        start = entry + 8 if width * size <= 4 else struct.unpack_from(order + "I", body, entry + 8)[0]
        tags[tag] = struct.unpack_from(order + str(size) + code, body, start)
    check(tags[256] == tags[257] == (1024,) and tags[258] == (16, 16, 16, 16)
          and tags[259] == tags[274] == tags[284] == (1,) and tags[262] == (2,) and tags[277] == (4,),
          f"expected top-first RGB+alpha TIFF16: {path.name}")
    offsets, sizes = tags[273], tags[279]
    check(len(offsets) == len(sizes) and all(start + size <= len(body) for start, size in zip(offsets, sizes))
          and sum(sizes) == 1024 * 1024 * 8, "incomplete TIFF pixel strips")
    pixels = b"".join(body[start:start + size] for start, size in zip(offsets, sizes))
    return order, memoryview(pixels)


def verify_flux(root):
    record = read(root / "receipt.json")
    check(record["status"] == "passed" and sha(record["testBinarySHA256"]), "missing real FLUX controller receipt")
    db = root / "catalog/library.sqlite"
    with closing(sqlite3.connect(db.resolve().as_uri() + "?mode=ro", uri=True)) as conn:
        jobs = [json.loads(row[0]) for row in conn.execute("SELECT data FROM processing_jobs")]
        works = [json.loads(row[0]) for row in conn.execute("SELECT data FROM editing_works")]
        versions = [json.loads(row[0]) for row in conn.execute("SELECT data FROM editing_versions")]
    check(len(jobs) == len(works) == 1 and len(versions) == 2, "unexpected FLUX work, version or job count")
    job, work = jobs[0], works[0]
    check(len(job["attempts"]) == record["attemptsAfterReopen"] == 1, "duplicate FLUX submission")
    attempt, request = job["attempts"][0], job["request"]
    candidate = by(versions, lambda v: v["id"])[record["candidateVersionID"]]
    original = record["originalVersionID"]
    check(job["id"] == record["jobID"] and attempt["id"] == record["attemptID"] and attempt["workerJoined"]
          and attempt["state"] == "succeeded" and attempt["submissionIntentAt"] and not attempt.get("remoteID")
          and work["adoptedVersionID"] == work["originalVersionID"] == original
          and request["inputVersionID"] == candidate["parentVersionID"] == original
          and record["adoptionRevisions"] == [0, 1, 2] and work["adoptionRevision"] == 2
          and job["resultVersionID"] == attempt["resultVersionID"] == candidate["id"], "FLUX version history differs")
    check(request["profile"]["model"] == FLUX and not request["profile"].get("credentialReference")
          and hashlib.sha256(request["prompt"].encode()).hexdigest() == record["promptSHA256"]
          == "60cea9057403fdcdaeba9699f0ff28d5c402930d9d56a7ec27d4327fb2329405", "different model or 034 request")
    frozen = request["quickPrompt"]
    roi = [480, 496, 512, 512]
    for field, header in [("selection", "selectionTopLeftXYWH"), ("context", "contextTopLeftXYWH")]:
        check([frozen[field][k] for k in ("x", "y", "width", "height")] == record[header], f"FLUX {field} mismatch")
    check(record["selectionTopLeftXYWH"] == roi and record["contextTopLeftXYWH"] == [403, 419, 621, 605]
          and record["basisSHA256"] == "65be31e87166a386b8b4ced901c2db701a795a1140930cab6ea0bde1112b00a3"
          and record["inputSize"] == [1024, 1008] and
          record["archivedBitDepth"] == 16 and record["archivedSize"] == [1024, 1024], "different input or output extent")
    check(record["inputMatches034"] and record["inputSHA256"] == "2256f27433ff1e088df0638fc066606982009251f7669ae637d6cc9de3b06fb9",
          "the controller's regional PNG differs from the 034 native reference")
    received = attempt["receivedOutput"]
    actual = received["configuration"]
    check(record["worker"].items() <= actual.items() and actual["usage"] == "local" and
          actual["actualModel"] == FLUX and actual["preset"] == "q8-16" and actual["steps"] == "16" and actual["seed"] == "8521"
          and actual["modelRevision"] == "1755314e2216b2a2c5cc0dd899d4e49ee3404d2c"
          and actual["weightsRevision"] == "d9790a1ceaba200e8b773fb236f7c9fa754283a7"
          and actual["runtimeRevision"] == "a8a400745949770d4de3b18c31684169da4b0af5" and int(actual["peakMLXBytes"]) > 0,
          "missing real pinned FLUX worker evidence")
    check(file_sha(root / "originals/lake-input.png") == record["sourceSHA256"] == work["source"]["contentSHA256"]
          == "17e0c427790397572821339d541e9169b67a4dbb76123bd8d146a441d81c2034", "different original source")
    archive = (db.parent / "Editing Archive").resolve()
    paths = {}
    for name, artifact in [("input", request["inputArtifact"]), ("basis", frozen["basis"]["artifact"]),
                           ("received", received["artifact"]), ("archived", candidate["artifact"])]:
        path = (archive / artifact["relativePath"]).resolve()
        check(path.is_relative_to(archive) and file_sha(path) == artifact["sha256"] == record[name + "SHA256"],
              "incorrect frozen file " + name)
        paths[name] = path
    order0, before = tiff16_rows(paths["basis"])
    order1, after = tiff16_rows(paths["archived"])
    check(order0 == order1, "different TIFF byte order")
    x, y, w, h = roi
    selected, protected = 0, 0
    for row in range(1024):
        a, b = row * 1024 * 8, (row + 1) * 1024 * 8
        if y <= row < y + h:
            left, right = a + x * 8, a + (x + w) * 8
            check(before[a:left] == after[a:left] and before[right:b] == after[right:b], "changed protected row")
            selected += sum(before[p:p + 8] != after[p:p + 8] for p in range(left, right, 8))
            protected += 1024 - w
        else:
            check(before[a:b] == after[a:b], "changed protected row")
            protected += 1024
    check(selected > 0 and record["pixelComparison"] == {"selectedPixels": w*h, "selectedChangedPixels": selected,
          "protectedPixels": protected, "protectedChangedPixels": 0}, "TIFF16 evidence differs")
    preview = record["previewDuringFlux"]
    check(preview["preSubmission"] == "preparing" and not preview["intentWhileWaiting"] and preview["heldMemoryBytes"] > 0
          and preview["previewSourceSHA256"] == "503aa25139ab5cabccdc919c4e76643b97e51cf202643766d9606ad36406c442",
          "missing resource wait or different second photo")
    for phase in ("whileWaiting", "whileRunning"):
        frame = preview[phase]
        check(frame["quality"] == "settled" and frame["drawReturnedNS"] >= frame["drawBeganNS"] >= frame["inputNS"]
              and frame["width"] == frame["renderedWidth"] and frame["height"] == frame["renderedHeight"],
              f"invalid independent window draw during {phase}")
    return {"testBinarySHA256": record["testBinarySHA256"], "attempts": 1, "protectedPixels": protected,
            "selectedChangedPixels": selected, "archivedSHA256": record["archivedSHA256"],
            "inputMatches034": record["inputSHA256"] == "2256f27433ff1e088df0638fc066606982009251f7669ae637d6cc9de3b06fb9"}



def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--feature", help="print one complete stable-ID row")
    parser.add_argument("--json", type=Path, help="save the full per-feature index")
    parser.add_argument("--release-dir", type=Path, help="bind available controls, inspection and learned 2x receipts to the supplied Release build")
    parser.add_argument("--adaptive-dir", type=Path, help="verify both current real adaptive replays, including the TIFF files")
    parser.add_argument("--named-coverage-fixtures", type=Path, help="export the two verified Adaptive layers to a new test directory")
    parser.add_argument("--flux-dir", type=Path, help="verify the actual local MLX attempt, reopened SQLite and all protected TIFF16 pixels")
    args = parser.parse_args()
    if args.named_coverage_fixtures and not args.adaptive_dir:
        parser.error("--named-coverage-fixtures requires --adaptive-dir")
    result = feature_report(args.release_dir)
    if args.adaptive_dir:
        result["candidateAdaptive"] = verify_adaptive(args.adaptive_dir)
        if result["candidateBuild"]:
            check(result["candidateAdaptive"]["testBinarySHA256"] == result["candidateBuild"]["uiTestBinarySHA256"],
                  "adaptive receipts and full release used different UI test bundles")
        if args.named_coverage_fixtures:
            export_named_coverage_fixtures(args.adaptive_dir, args.named_coverage_fixtures)
    if args.flux_dir:
        result["candidateLocalFlux"] = verify_flux(args.flux_dir)
    if args.json:
        args.json.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    view = {k: v for k, v in result.items() if k != "rows"}
    if args.feature:
        matches = [row for row in result["rows"] if row["id"] == args.feature]
        check(matches, "unknown Camera Raw feature ID " + args.feature)
        view = matches[0]
    print(json.dumps(view, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (KeyError, ValueError, OSError, TypeError, sqlite3.Error, struct.error) as error:
        sys.exit(str(error))
