"""Offline photo-library retrieval experiment. Only the explicit --prepare step uses the network."""

import argparse
import hashlib
import itertools
import json
import math
import os
import platform
import sqlite3
import sys
import tempfile
from pathlib import Path
from time import perf_counter
from urllib.request import urlopen

os.environ["VECLIB_MAXIMUM_THREADS"] = "1"
os.environ["OPENBLAS_NUM_THREADS"] = "1"
os.environ["OMP_NUM_THREADS"] = "2"
os.environ["TOKENIZERS_PARALLELISM"] = "false"

import cv2
import numpy as np
import onnx
import onnxruntime as ort
import PIL
import tokenizers
from PIL import Image, ImageOps

ROOT = Path(__file__).resolve().parents[2]
CASES = Path(__file__).with_name("retrieval-cases.json")
WORK = ROOT / "output/library-033-research/retrieval"
YUNET = ROOT / "experiments/MaskAI/Vendor/Models/yunet/face_detection_yunet_2023mar.onnx"
YUNET_HASH = "8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4"
CHINESE = "Xenova/chinese-clip-vit-base-patch16/resolve/f26904860903e70e050b8f48255e5f48401816e9/"
SIGLIP = "onnx-community/siglip2-base-patch16-224-ONNX/resolve/ba1f3b0843f24bc5417d38e19c37b287d719b2f4/"
SFACE = "opencv/face_recognition_sface/resolve/3d7082438a6e4551e840c9b2bb60b71e8da4b524/"
ASSETS = {
    "clip-q8.onnx": (CHINESE + "onnx/model_quantized.onnx", "a2c2849329eafb24100acec5a9421a39f8cb445296444c5c98855b69e5e7a751"),
    "tokenizer.json": (CHINESE + "tokenizer.json", "7dfbf1966ebf99d471c3796e9b457329d2b2182b817e144f1e904b957745c839"),
    "preprocessor_config.json": (CHINESE + "preprocessor_config.json", "61a78fdd2c7ac17b54b6190c0f4cb23423192c535003d52528d01e318a47608b"),
    "siglip-vision-q8.onnx": (SIGLIP + "onnx/vision_model_quantized.onnx", "5f2b401c1a4fc095702a5d45348e17ad46c4f87064085365b43c6e8eaa5c0070"),
    "siglip-text-q8.onnx": (SIGLIP + "onnx/text_model_quantized.onnx", "3a0603d3a00c05a80a6ded4743c16aaac7b1e62cdcc7e362e7ce418659b96400"),
    "siglip-tokenizer.json": (SIGLIP + "tokenizer.json", "cb9140fae3ac5122c972d37adf83e1248471a38147ad76f8215c8872c6fd8322"),
    "siglip-preprocessor.json": (SIGLIP + "preprocessor_config.json", "9b36b57ebaf20f09bf4c22100ccc21877ea6bfe5aead0c00c59f8af8ccefacfc"),
    "sface.onnx": (SFACE + "face_recognition_sface_2021dec.onnx", "0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79"),
}


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def yunet_source(models):
    return YUNET if YUNET.exists() and digest(YUNET) == YUNET_HASH else models / "yunet.onnx"


def prepare(models):
    models.mkdir(parents=True, exist_ok=True)
    downloads = dict(ASSETS)
    if yunet_source(models) != YUNET:
        downloads["yunet.onnx"] = ("opencv/face_detection_yunet/resolve/3cc26e7f1014a5ee5d74a42acee58bafc9d0a310/face_detection_yunet_2023mar.onnx", YUNET_HASH)
    for name, (source, expected) in downloads.items():
        dest = models / name
        if dest.exists() and digest(dest) == expected:
            continue
        temporary = dest.with_suffix(".part")
        with urlopen("https://huggingface.co/" + source, timeout=120) as source_stream, temporary.open("wb") as output:
            while block := source_stream.read(1024 * 1024):
                output.write(block)
        if digest(temporary) != expected:
            raise ValueError(f"Wrong model digest for {name}")
        temporary.replace(dest)
    split_chinese_model(models)


def split_chinese_model(models):
    model = onnx.load(str(models / "clip-q8.onnx"))
    extractor = onnx.utils.Extractor(model)
    for name, inputs, output in [
        ("clip-vision-q8.onnx", ["pixel_values"], "image_embeds"),
        ("clip-text-q8.onnx", ["input_ids", "attention_mask"], "text_embeds"),
    ]:
        onnx.save(extractor.extract_model(inputs, [output]), str(models / name))


def summary_ms(values):
    return {k: round(float(np.percentile(values, p)), 4) for k, p in [("p50", 50), ("p95", 95)]}


def elapsed_ms(start):
    return (perf_counter() - start) * 1000


def unit(vector):
    v = vector.flatten().astype(np.float32)
    length = np.linalg.norm(v)
    if not np.isfinite(length) or length == 0:
        raise ValueError("Invalid embedding")
    return v / length


def exact_scores(matrix, vector):
    scores = np.einsum("ij,j->i", matrix, vector, optimize=False)
    if not np.isfinite(scores).all() or np.max(np.abs(scores)) > 1.0001:
        raise ValueError("Invalid cosine scores from normalized vectors")
    return scores


def session(path):
    options = ort.SessionOptions()
    options.intra_op_num_threads = 2
    options.inter_op_num_threads = 1
    options.log_severity_level = 3
    return ort.InferenceSession(str(path), options, providers=["CPUExecutionProvider"])


def load_rgb(path):
    with Image.open(path) as im:
        return ImageOps.exif_transpose(im).convert("RGB")


def prepare_pixels(path, config):
    img = load_rgb(path)
    size = config["size"]
    img = img.resize((size["width"], size["height"]), Image.Resampling(config["resample"]))
    arr = np.asarray(img, dtype=np.float32) * np.float32(config["rescale_factor"])
    arr = (arr - np.asarray(config["image_mean"], np.float32)) / np.asarray(config["image_std"], np.float32)
    return np.ascontiguousarray(arr.transpose(2, 0, 1)[None])


def rank_metrics(ranked, relevant):
    positions = [i for i, photo in enumerate(ranked, 1) if photo in relevant]
    ap = sum(k / pos for k, pos in enumerate(positions, 1)) / len(relevant)
    ideal = sum(1 / math.log2(i + 1) for i in range(1, min(5, len(relevant)) + 1))
    dcg = sum(1 / math.log2(pos + 1) for pos in positions if pos <= 5)
    return {"top": ranked[0], "hit1": int(positions[0] == 1), "AP": round(ap, 5),
            "nDCG5": round(dcg / ideal, 5), "recall5": round(sum(pos <= 5 for pos in positions) / len(relevant), 5)}


def semantic(name, models, photos, queries):
    google = name == "siglip"
    cfg_file, tok_file = ("siglip-preprocessor.json", "siglip-tokenizer.json") if google else ("preprocessor_config.json", "tokenizer.json")
    config = json.loads((models / cfg_file).read_text())
    timer = perf_counter()
    tokenizer = tokenizers.Tokenizer.from_file(str(models / tok_file))
    if google:
        tokenizer.enable_truncation(max_length=64)
        tokenizer.enable_padding(length=64, pad_id=tokenizer.token_to_id("<pad>"), pad_token="<pad>")
    tokenizer_ms = elapsed_ms(timer)
    timer = perf_counter()
    vision = session(models / f"{name}-vision-q8.onnx")
    text = session(models / f"{name}-text-q8.onnx")
    init_ms = elapsed_ms(timer)
    image_output, text_output = ("pooler_output", "pooler_output") if google else ("image_embeds", "text_embeds")
    preprocess, encode, corpus = [], [], []
    first_pixel = None
    for path in photos.values():
        timer = perf_counter()
        pixels = prepare_pixels(path, config)
        preprocess.append(elapsed_ms(timer))
        if first_pixel is None:
            first_pixel = pixels
        timer = perf_counter()
        vec = vision.run([image_output], {"pixel_values": pixels})[0]
        corpus.append(unit(vec))
        encode.append(elapsed_ms(timer))
    matrix = np.stack(corpus)
    encode_query, ranking, metrics = [], [], []
    for i, q in enumerate(queries):
        timer = perf_counter()
        tok = tokenizer.encode(q["text"])
        inputs = {"input_ids": np.asarray([tok.ids], np.int64)}
        if not google:
            inputs["attention_mask"] = np.asarray([tok.attention_mask], np.int64)
        vec = unit(text.run([text_output], inputs)[0])
        encode_query.append(elapsed_ms(timer))
        timer = perf_counter()
        ranked = np.argsort(-exact_scores(matrix, vec), kind="stable")
        ranking.append(elapsed_ms(timer))
        keys = list(photos)
        metrics.append({"query": i + 1, **rank_metrics([keys[n] for n in ranked], q["relevant"])})
        if i == 0 and not google:
            joint = session(models / "clip-q8.onnx")
            image_ref, text_ref = joint.run(["image_embeds", "text_embeds"], {**inputs, "pixel_values": first_pixel})
            parity = max(float(np.max(np.abs(corpus[0] - unit(image_ref)))),
                         float(np.max(np.abs(vec - unit(text_ref)))))
            if parity > 1e-5:
                raise ValueError(f"Tower split changed output by {parity}")
            del joint
    aggregate = {k: round(float(np.mean([v[k] for v in metrics])), 5) for k in ["hit1", "AP", "nDCG5", "recall5"]}
    result = {"dimension": matrix.shape[1], "images": len(photos), "queries": metrics, "macro": aggregate,
              "timing_ms": {"load_tokenizer": round(tokenizer_ms, 2), "load_two_sessions": round(init_ms, 2),
                            "read_decode_orient_resize_normalize": summary_ms(preprocess),
                            "first_image_encoder_l2": round(encode[0], 2), "remaining_image_encoder_l2": summary_ms(encode[1:]),
                            "first_text_tokenize_encode_l2": round(encode_query[0], 2),
                            "remaining_text_tokenize_encode_l2": summary_ms(encode_query[1:]), "exact_scan_and_sort": summary_ms(ranking)}}
    if not google:
        result["joint_vs_split_unit_vector_max_abs_error"] = parity
    return result


def complete_link(vectors, cutoff):
    groups = [[i] for i in range(len(vectors))]
    matrix = np.asarray(vectors)
    similarities = np.einsum("ij,kj->ik", matrix, matrix, optimize=False)
    if not np.isfinite(similarities).all():
        raise ValueError("Invalid face similarity matrix")
    while len(groups) > 1:
        candidates = ((float(similarities[np.ix_(groups[a], groups[b])].min()), a, b)
                      for a, b in itertools.combinations(range(len(groups)), 2))
        score, a, b = max(candidates, key=lambda row: (row[0], -row[1], -row[2]))
        if score < cutoff:
            break
        groups[a].extend(groups.pop(b))
    return groups


def face_baseline(models, photos, cases, long_edge=None):
    opts = cases["face_operating_point"]
    cv2.setNumThreads(2)
    detector = cv2.FaceDetectorYN.create(str(yunet_source(models)), "", (320, 320), opts["yunet_confidence"], opts["yunet_nms_iou"], 5000)
    recognizer = cv2.FaceRecognizerSF.create(str(models / "sface.onnx"), "")
    vectors, times_detect, times_recognize = [], [], []
    chosen, counts = {}, {}
    for key, path in photos.items():
        bgr = np.ascontiguousarray(np.asarray(load_rgb(path))[:, :, ::-1])
        h, w = bgr.shape[:2]
        timer = perf_counter()
        scale = min(1, (long_edge or opts["resize_long_edge"]) / max(w, h))
        dims = (round(w * scale), round(h * scale))
        small = cv2.resize(bgr, dims, interpolation=cv2.INTER_AREA)
        detector.setInputSize(dims)
        _, boxes = detector.detect(small)
        times_detect.append(elapsed_ms(timer))
        counts[key] = len(boxes) if boxes is not None else 0
        for box in ([] if boxes is None else boxes):
            timer = perf_counter()
            orig = box.copy()
            orig[:14:2] *= w / dims[0]
            orig[1:14:2] *= h / dims[1]
            crop = recognizer.alignCrop(bgr, orig)
            v = unit(recognizer.feature(crop))
            times_recognize.append(elapsed_ms(timer))
            roi = cases["nominated_face_center_boxes"].get(key)
            cx, cy = (orig[0] + orig[2] / 2) / w, (orig[1] + orig[3] / 2) / h
            if roi and roi[0] <= cx <= roi[2] and roi[1] <= cy <= roi[3] and (key not in chosen or box[-1] > chosen[key][0]):
                chosen[key] = (float(box[-1]), len(vectors))
            vectors.append(v)
    timer = perf_counter()
    groups = complete_link(vectors, opts["sface_cosine_complete_link"]) if vectors else []
    clustering_ms = elapsed_ms(timer)
    assigned = {i: c for c, group in enumerate(groups) for i in group}
    truth = {key: label for label, names in enumerate(cases["labeled_face_groups"]) for key in names}
    pairs = {"true_positive": 0, "true_negative": 0, "false_positive": 0, "false_negative": 0}
    for a, b in itertools.combinations(truth, 2):
        predicted = a in chosen and b in chosen and assigned[chosen[a][1]] == assigned[chosen[b][1]]
        correct = predicted == (truth[a] == truth[b])
        pairs[("true_" if correct else "false_") + ("positive" if predicted else "negative")] += 1
    return {"detections": sum(counts.values()), "images_with_detections": sum(n > 0 for n in counts.values()),
            "input_long_edge_limit": long_edge or opts["resize_long_edge"],
            "target_windows": len(cases["nominated_face_center_boxes"]), "target_windows_hit": len(chosen),
            "missed_target_ids": sorted(cases["nominated_face_center_boxes"].keys() - chosen.keys()),
            "empty_control_images": len(cases["empty_face_controls"]), "empty_control_boxes": sum(counts[k] for k in cases["empty_face_controls"]),
            "cluster_count_including_singletons": len(groups), "cluster_sizes": sorted(map(len, groups), reverse=True),
            "identity_pair_counts": pairs, "identity_labeled_targets": len(truth), "embedding_dimension": len(vectors[0]) if vectors else None,
            "timing_ms": {"first_resize_detect": round(times_detect[0], 2), "remaining_resize_detect": summary_ms(times_detect[1:]),
                          "per_face_align_encode_l2": summary_ms(times_recognize) if vectors else None, "complete_link": round(clustering_ms, 2)}}


def catalogue(models, cases):
    """Index the real, existing six sequences once and replay the same files after reopening."""
    base = ROOT / "Tests/RAWMasterImagingTests/Fixtures/SequenceGrouping/v1/cases"
    paths = sorted(base.glob("*/files/*.jpg"))
    namespaces = sorted({p.parent.parent.name for p in paths})
    if not paths or len(namespaces) != 6:
        raise ValueError("The six photographic fixture sequences are required")
    config = json.loads((models / "siglip-preprocessor.json").read_text())
    encoder = session(models / "siglip-vision-q8.onnx")
    model_key = ASSETS["siglip-vision-q8.onnx"][1] + "/" + ASSETS["siglip-preprocessor.json"][1]
    manifest = hashlib.sha256()
    encode_ms, prep_ms = [], []
    with tempfile.TemporaryDirectory(dir=WORK) as tmp:
        database = Path(tmp) / "index.sqlite"
        db = sqlite3.connect(database)
        db.executescript("""
            CREATE TABLE embeddings(model TEXT NOT NULL, hash TEXT NOT NULL, vec BLOB NOT NULL, PRIMARY KEY(model,hash));
            CREATE TABLE photos(id INTEGER PRIMARY KEY, scope TEXT NOT NULL, hash TEXT NOT NULL);
            CREATE INDEX scope_ids ON photos(scope,id);
        """)
        timer = perf_counter()
        for i, path in enumerate(paths):
            h = digest(path)
            manifest.update((str(path.relative_to(base)) + "\t" + h + "\n").encode())
            db.execute("INSERT INTO photos VALUES(?,?,?)", (i, path.parent.parent.name, h))
            present = db.execute("SELECT 1 FROM embeddings WHERE model=? AND hash=?", (model_key, h)).fetchone()
            if not present:
                stage = perf_counter()
                pix = prepare_pixels(path, config)
                prep_ms.append(elapsed_ms(stage))
                stage = perf_counter()
                v = unit(encoder.run(["pooler_output"], {"pixel_values": pix})[0])
                encode_ms.append(elapsed_ms(stage))
                db.execute("INSERT INTO embeddings VALUES(?,?,?)", (model_key, h, v.astype("<f4").tobytes()))
            if i % 32 == 31:
                db.commit()
        db.commit()
        total_ms = elapsed_ms(timer)
        db.close()
        db = sqlite3.connect(database)
        timer = perf_counter()
        for path in paths:
            if not db.execute("SELECT 1 FROM embeddings WHERE model=? AND hash=?", (model_key, digest(path))).fetchone():
                raise AssertionError("Uncovered original on replay")
        replay_ms = elapsed_ms(timer)
        hits = []
        tok = tokenizers.Tokenizer.from_file(str(models / "siglip-tokenizer.json"))
        tok.enable_padding(length=64, pad_id=tok.token_to_id("<pad>"), pad_token="<pad>")
        tok.enable_truncation(max_length=64)
        text = session(models / "siglip-text-q8.onnx")
        queries = [unit(text.run(["pooler_output"], {"input_ids": np.array([tok.encode(q["text"]).ids], np.int64)})[0])
                   for q in cases["queries"]]
        for scope in (None, "burst14-context38"):
            load_ms, rank_ms = [], []
            sql = "SELECT e.vec FROM photos p JOIN embeddings e ON p.hash=e.hash WHERE e.model=?"
            params = [model_key]
            if scope is not None:
                sql += " AND p.scope=?"
                params.append(scope)
            sql += " ORDER BY p.id"
            for query in queries:
                stage = perf_counter()
                rows = db.execute(sql, params).fetchall()
                matrix = np.frombuffer(b"".join(row[0] for row in rows), dtype="<f4").reshape(len(rows), -1)
                load_ms.append(elapsed_ms(stage))
                stage = perf_counter()
                np.argsort(-exact_scores(matrix, query), kind="stable")[:5]
                rank_ms.append(elapsed_ms(stage))
            hits.append({"scope": scope or "all", "rows": len(rows), "queries": len(queries),
                         "read_candidate_blobs_ms": summary_ms(load_ms), "exact_rank_top5_ms": summary_ms(rank_ms)})
        total_vector_bytes = db.execute("SELECT SUM(length(vec)) FROM embeddings").fetchone()[0]
        db.close()
        return {"model": "siglip", "model_key": model_key, "sqlite_version": sqlite3.sqlite_version,
                "logical_photos": len(paths), "unique_encoded": len(encode_ms), "corpus_sha256": manifest.hexdigest(),
                "first_index_ms_excl_model_load": round(total_ms, 2), "rehash_and_lookup_after_reopen_ms": round(replay_ms, 2),
                "replay_model_calls": 0, "prep_ms": summary_ms(prep_ms), "encode_ms": summary_ms(encode_ms),
                "vector_bytes": total_vector_bytes, "sqlite_bytes": database.stat().st_size, "search": hits}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepare", action="store_true", help="Download pinned model/config files only, and separate Chinese-CLIP towers")
    parser.add_argument("--catalogue", action="store_true", help="Run the full repository photo-proxy indexing and replay experiment")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    models = WORK / "models"
    if args.prepare:
        prepare(models)
        return
    for name, (_, sha) in ASSETS.items():
        if digest(models / name) != sha:
            raise ValueError(f"Unverified model input: {name}")
    if digest(yunet_source(models)) != YUNET_HASH:
        raise ValueError("Unexpected YuNet revision")
    cases = json.loads(CASES.read_text())
    photos = {}
    for key, item in cases["samples"].items():
        path = ROOT / item["file"]
        if digest(path) != item["sha256"]:
            raise ValueError(f"Fixture changed: {key}")
        photos[key] = path
    result = {"protocol": cases["protocol"], "cases_sha256": digest(CASES),
              "runtime": {"platform": platform.platform(), "python": sys.version.split()[0], "onnxruntime": ort.__version__,
                          "provider": "CPUExecutionProvider", "intra_op_threads": 2, "inter_op_threads": 1,
                          "opencv": cv2.__version__, "numpy": np.__version__, "Pillow": PIL.__version__,
                          "tokenizers": tokenizers.__version__, "onnx": onnx.__version__},
              "models_sha256": dict([(name, cfg[1]) for name, cfg in ASSETS.items()] + [("yunet", YUNET_HASH)])}
    if args.catalogue:
        result["catalogue"] = catalogue(models, cases)
    else:
        split_chinese_model(models)
        for name in ["clip", "siglip"]:
            result[name] = semantic(name, models, photos, cases["queries"])
            print(name, result[name]["macro"], flush=True)
        result["faces"] = face_baseline(models, photos, cases)
        result["faces_exploratory_larger_input"] = face_baseline(models, photos, cases, long_edge=1024)
    output = args.output or (WORK / ("catalogue-results.json" if args.catalogue else "results.json"))
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print("Saved", output)


if __name__ == "__main__":
    main()
