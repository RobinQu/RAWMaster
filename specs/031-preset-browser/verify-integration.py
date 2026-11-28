"""Verify the four real-window Release receipts against the frozen inputs and measured gates."""
import argparse
import json
import math
from pathlib import Path
from statistics import median

BIRD = "8f96d2fd4fa0c76741ee09b486a4a5e17c8c893ce714060f2fe65eb34c891e1c"
PORTRAIT = "0a0775e6f803329341b954fd4d0ed08d6cc71b3b226c34d0218865761e31f0d8"
FLASHRAW = "flashraw-0.3.1-linear-srgb-bilinear"
PAIR_GATE = "paired.30Warm.presetP95AtMostManualP95"


class WindowLatencyExceeded(ValueError):
    """A complete, consistent window receipt exceeds its stated latency requirement."""


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def p95(samples):
    require(all(math.isfinite(x) and x > 0 for x in samples), "invalid latency sample")
    return sorted(samples)[math.ceil(0.95 * len(samples)) - 1]


def verify(name, data):
    pair_pending = (name == "paired" and data["status"] == "failed" and data["passes"] is False
                    and data["gates"].get(PAIR_GATE) is False)
    require(pair_pending or (data["status"] == "passed" and data["passes"] is True),
            data.get("failure", "window run failed"))
    require(data["build"] == "release" and data["composition"] == "AppModel.editing / ImageEngines.editing",
            "requires the shipping composition in Release")
    portrait = name == "portrait"
    sha = PORTRAIT if portrait else BIRD
    stored = (6000, 4000) if portrait else (9504, 6336)
    require(data["sourceSHA256"] == data["sourceSHA256After"] == sha, "source fingerprint mismatch")
    require((data["sourcePixelWidth"], data["sourcePixelHeight"]) == stored, "capture dimensions mismatch")
    initial = data["engineAfterInitialSettled"]
    viewport_decoded = False
    if name in ("classic", "paired") and data["initialFrame"]["approximate"] is True:
        # The shipping viewport can finish on a FlashRaw proxy without filling the canonical pool.
        before = data["engineBeforeApp"]
        previous_counts = before["flashRawDecodesByStage"]
        viewport_decoded = initial["fallbacks"] == before["fallbacks"] and all(
            any(stage.endswith(" · bilinear · " + region) and count > previous_counts.get(stage, 0)
                for stage, count in initial["flashRawDecodesByStage"].items())
            for region in ("全图", "区域")
        )
    require(data["recipeRawDecoder"] == FLASHRAW and (initial["canonicalTextureFills"] > 0 or viewport_decoded),
            "requires FlashRaw-backed initial frame")
    require(data["gates"] and all(v is True or (pair_pending and k == PAIR_GATE)
                                  for k, v in data["gates"].items()), "unexpected reported gate failed")

    if name == "classic":
        samples = []
        for case, count in (("filterLook", 8), ("filterIntensity", 8), ("filterCompound", 6)):
            series = data[case]["interactive"]["samplesMs"]
            draws = data[case]["draws"]
            require(len(draws) == len(series) == count, "incomplete Classic case")
            require(all(d["approximate"] and d["quality"] == "interactive" for d in draws), "unexpected frame route")
            require(all((d["width"], d["height"]) == (d["renderedWidth"], d["renderedHeight"]) == (2400, 1600)
                        for d in draws), "drawn and rendered rasters differ from the frozen viewport")
            cold, warm = data[case]["engineAfterFirstSample"], data[case]["engineAfterLastSample"]
            require(cold["flashRawDecodesByStage"] and cold["flashRawDecodesByStage"] == warm["flashRawDecodesByStage"]
                    and cold["fallbacks"] == warm["fallbacks"], "warm filter change repeated a RAW decode or fell back")
            samples.extend(series[1:])
        require(median(samples) <= 20 and p95(samples) <= 33, "Classic window latency exceeded")
        before, after = data["engineAfterInitialSettled"], data["engineAfterInteraction"]
        require(after["fallbacks"] == before["fallbacks"] and after["sourceCaptures"] == before["sourceCaptures"],
                "interactive fallback or new capture")
        return
    if name == "paired":
        pair = data["pairedExposure"]
        for arm in ("preset", "manual"):
            require(len(pair[arm]["warm"]["samplesMs"]) == 30, "paired warm cardinality")
        rows = pair["draws"]
        require(len(rows) == 62, "missing settled draw")
        for i in range(31):
            first, second = rows[2*i:2*i+2]
            order = ("preset", "manual") if i % 2 == 0 else ("manual", "preset")
            require((first["path"], second["path"]) == order and first["pair"] == second["pair"] == i,
                    "missing matched AB/BA pair")
            require(first["resultRecipeSHA256"] == second["resultRecipeSHA256"]
                    and first["quality"] == second["quality"] == "settled", "paired recipe or frame differs")
            for row in (first, second):
                require(row["baselineDrawNS"] <= row["inputNS"] <= row["committedNS"]
                        <= row["drawBeganNS"] <= row["drawReturnedNS"], "invalid order of matched draw timestamps")
                require((row["width"], row["height"]) == (row["renderedWidth"], row["renderedHeight"]) == (2400, 1600),
                        "paired edit used a different viewport")
                arm = pair[row["path"]]
                sample = arm["firstMs"] if i == 0 else arm["warm"]["samplesMs"][i-1]
                require(math.isclose(sample, (row["drawReturnedNS"] - row["inputNS"])/1e6, abs_tol=1e-6)
                        and math.isclose(row["synchronousCommandMs"], (row["committedNS"] - row["inputNS"])/1e6, abs_tol=1e-6),
                        "reported latency does not match the timestamps")
        preset, manual = (p95(pair[arm]["warm"]["samplesMs"]) for arm in ("preset", "manual"))
        require(pair["passes"] is (preset <= manual) and data["gates"][PAIR_GATE] is (preset <= manual)
                and data["passes"] is (preset <= manual), "reported verdict disagrees with the observed p95s")
        if preset > manual:
            raise WindowLatencyExceeded(f"SC-02 preset p95 {preset:.3f} ms exceeds matched manual p95 {manual:.3f} ms")
        return

    orientation, width, height = (8, 4000, 6000) if portrait else (1, 9504, 6336)
    first = data["maskAnalysisAfterFirst"]
    require(first["decoder"] == FLASHRAW and first["flashRawDecodes"] == 1 and first["coreImageRawDecodes"] == 0,
            "mask analysis decoder mismatch")
    require(first["sourceContentID"] == sha and (first["orientation"], first["orientedWidth"], first["orientedHeight"])
            == (orientation, width, height), "mask coordinate system mismatch")
    warm = data["subjectWarm"]["samplesMs"]
    require(0 < data["subjectFirstMs"] <= 6000 and len(warm) == 30 and max(warm) <= 250, "mask latency exceeded")
    for field, hits, generations in (("First", 0, 1), ("Warm", 30, 1), ("Background", 30, 2), ("Return", 31, 2)):
        require(data["maskCountersAfter"+field] == {"exactHits": hits, "freshNonBrushCandidates": generations},
                "mask reuse counter mismatch")
    require(data["freshEditorInvocationsBeforeReopen"] == data["freshEditorInvocationsAtSettled"] ==
            data["freshEditorInvocationsAfterExport"] == 0, "frozen mask invoked inference")
    output, pixels = data["export"], data["togglePixelComparison"]
    require((output["width"], output["height"], output["bitsPerComponent"]) == (width, height, 16)
            and data["sourceSHA256AfterExport"] == sha, "native TIFF dimensions, precision or source changed")
    require(pixels["protectedPixels"] > 0 and pixels["protectedMaximumRGBA16Difference"] == 0
            and pixels["selectedBrighterPixels"] > 0 and pixels["selectedRGBSumGain"] > 0, "mask pixel gate failed")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("receipts", type=Path, help="directory containing classic.json, paired.json, portrait.json and bird.json")
    parser.add_argument("--confirm", action="store_true", help="also require independent confirm-classic and confirm-paired window runs")
    args = parser.parse_args()
    failures = []
    cases = ["classic", "paired", "portrait", "bird"]
    if args.confirm:
        cases.extend(["confirm-classic", "confirm-paired"])
    for name in cases:
        try:
            verify(name.removeprefix("confirm-"), json.loads((args.receipts / f"{name}.json").read_bytes()))
        except (KeyError, ValueError, OSError, TypeError, IndexError) as error:
            failures.append(f"{name}: {error}")
        else:
            print(f"{name}: PASS")
    if failures:
        raise SystemExit("\n".join(failures))
