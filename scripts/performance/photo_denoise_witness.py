"""Verify the versioned photographic denoiser's fixed color and adjustable luma contract."""
import math

PHOTO_V1 = "waifu2x-vgg7-photo-noise2-cc385f97-f32-v1"
DNG_V1 = "waifu2x-vgg7-photo-noise2-cc385f97-output-dng-v1"
PHOTO_V2 = "waifu2x-vgg7-photo-noise2-cc385f97-full-chroma-v2"
DNG_V2 = "waifu2x-vgg7-photo-noise2-cc385f97-full-chroma-output-dng-v2"


def validate_component_witness(row, legacy_model):
    values = row["componentWitness"]
    measured = values["inRangeOpaque"]
    if (values["sampled"] != 256 * 192 or not 1000 < measured <= values["sampled"]
            or not 32 < values["sourceToFullChromaChangedByTwoCodes"] <= measured
            or not 32 < values["sourceToFullLumaChangedByTwoCodes"] <= measured
            or row["legacyModel"] != legacy_model):
        raise ValueError("Missing source signal, gamut coverage, or historical model " + row["source"])
    for field, limit in (("p95ZeroVsSourceLumaRGB8", 1.5), ("p95HalfVsMidpointLumaRGB8", 1.5),
                         ("p95ZeroAndHalfVsFullChromaRGB8", 2)):
        value = values[field]
        if not math.isfinite(value) or not 0 <= value <= limit:
            raise ValueError(f"{row['source']}: component mismatch {field}={value}")

    current_model = PHOTO_V2 if legacy_model == PHOTO_V1 else DNG_V2
    if type(row.get("nativePredictionCacheEligible")) is not bool or row.get("closedInputResidentBytes") != 0:
        raise ValueError("Photo prediction eligibility or capture cleanup missing: " + row["source"])
    for entry in row["requests"]:
        state = entry["state"]
        expected_model = "disabled" if state in ("original", "disabled") else legacy_model if state.startswith("legacy") else current_model
        passes = entry.get("neuralGPUCompletions")
        if type(passes) is not int or passes < 0:
            raise ValueError(f"{row['source']}: missing completed native GPU pass count for {state}")
        if row["nativePredictionCacheEligible"] and ((state == "zero" and passes == 0)
                or (state in ("full", "half", "fresh35") and passes != 0)):
            raise ValueError(f"{row['source']}: native prediction reuse was not witnessed at {state}")
        if entry.get("denoiseModel") != expected_model:
            raise ValueError(f"{row['source']}: incorrect model recorded for {state}")
    hashes = {s["state"]: s["sampleRGBASHA256"] for s in row["requests"]}
    if (len(hashes) != len(row["requests"]) or hashes["original"] != hashes["legacy-zero"]
            or hashes["full"] != hashes["legacy-full"] or hashes["full"] != hashes["replay100"]
            or hashes["disabled"] != hashes["original"]
            or len({hashes[k] for k in ("original", "zero", "half", "fresh35", "full")}) != 5
            or hashes["legacy35"] == hashes["fresh35"]):
        raise ValueError("Missing v1/v2 pixel change, isolation, or reversible reset: " + row["source"])


def verify_legacy_replay(current, prior):
    if current["sourceSHA256"] != prior["sourceSHA256"] or current["nativePixels"] != prior["nativePixels"]:
        raise ValueError("Source or dimensions changed: " + current["source"])
    now = {s["state"]: s["sampleRGBASHA256"] for s in current["requests"]}
    old = {s["state"]: s["sampleRGBASHA256"] for s in prior["requests"]}
    v1_states = {"original": "original", "legacy-zero": "zero", "legacy35": "fresh35", "legacy-full": "full"}
    if "componentWitness" in prior and (now.keys() != old.keys() or any(value != old[key] for key, value in now.items())):
        raise ValueError("The same photographic model no longer returns the same pixels: " + current["source"])
    for active, historic in v1_states.items():
        if now[active] != old[active if active in old else historic]:
            raise ValueError(f"{current['source']}: reopened {active} pixels differ from the previous release")
