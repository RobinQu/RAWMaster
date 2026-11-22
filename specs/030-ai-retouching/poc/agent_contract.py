"""Offline contract probe for already-parsed editing intents. No model or network client."""

from dataclasses import dataclass, replace
import json


@dataclass(frozen=True)
class Shot:
    photo: str
    revision: int = 1
    people: int = 1
    strict: bool = False
    clean_ancestry: bool = True


@dataclass(frozen=True)
class Intent:
    tool: str
    region: str = ""


STRICT_TOOLS = {"subjectLight", "balanceExposure", "whiteBalance"}
KNOWN_TOOLS = STRICT_TOOLS | {"clone", "generatePatch"}
MODEL = "doubao-seedream-5-5-261028"


def decision(shot, intent, upload_scope=None):
    if intent.tool not in KNOWN_TOOLS:
        return "unsupported"
    if shot.strict and not shot.clean_ancestry:
        return "require-clean-source"
    if shot.strict and intent.tool not in STRICT_TOOLS:
        return "blocked-by-documentary-policy"
    if intent.tool == "subjectLight" and not intent.region:
        if shot.people != 1:
            return "select-person" if shot.people else "skip-no-person"
    if intent.tool == "generatePatch":
        if not intent.region:
            return "select-region"
        if upload_scope != (shot.photo, shot.revision, intent.region, MODEL):
            return "review-upload"
        return "request-candidate"
    return "draft-native-recipe"


def apply_candidate(base, current, already_applied):
    if already_applied:
        return "previous-receipt"
    if base != current:
        return "retain-unapplied-stale-candidate"
    return "append-history"


def probe():
    clean = Shot("event-01", strict=True)
    selected = Shot("lake-01")
    patch = Intent("generatePatch", "sign-matte-v1")
    scope = (selected.photo, selected.revision, patch.region, MODEL)
    tests = [
        ("strict-exposure", decision(clean, Intent("balanceExposure")), "draft-native-recipe"),
        ("strict-cloud", decision(clean, patch, (clean.photo, clean.revision, patch.region, MODEL)), "blocked-by-documentary-policy"),
        ("strict-clone", decision(clean, Intent("clone", "sign")), "blocked-by-documentary-policy"),
        ("strict-edited-parent", decision(replace(clean, clean_ancestry=False), Intent("whiteBalance")), "require-clean-source"),
        ("unknown-tool", decision(clean, Intent("freeform")), "unsupported"),
        ("missing-scope", decision(selected, patch), "review-upload"),
        ("changed-scope", decision(selected, Intent("generatePatch", "whole-frame"), scope), "review-upload"),
        ("changed-revision", decision(replace(selected, revision=2), patch, scope), "review-upload"),
        ("approved-scope", decision(selected, patch, scope), "request-candidate"),
        ("late-return", apply_candidate(1, 2, False), "retain-unapplied-stale-candidate"),
        ("explicit-apply", apply_candidate(1, 1, False), "append-history"),
        ("duplicate-apply", apply_candidate(1, 2, True), "previous-receipt"),
    ]
    group = [Shot("a", people=1), Shot("b", people=2), Shot("c", people=0), Shot("d", people=1)]
    per_shot = [decision(shot, Intent("subjectLight")) for shot in group]
    expected = ["draft-native-recipe", "select-person", "skip-no-person", "draft-native-recipe"]
    tests.append(("per-photo-routing", per_shot, expected))
    for name, actual, expected in tests:
        if actual != expected:
            raise ValueError(f"{name}: {actual} != {expected}")
    return {"mode": "offline, typed plans and supplied facts", "case_count": len(tests),
            "decisions": {name: actual for name, actual, expected in tests}}


if __name__ == "__main__":
    print(json.dumps(probe(), indent=2))
