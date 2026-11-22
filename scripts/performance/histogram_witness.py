"""Verify separation of every A/B distribution for operators which randomize their grain."""
from itertools import combinations, product


def grain_distances(samples):
    groups = [[s["histogramBins"] for s in samples if s["state"] == state] for state in ("control", "edit")]
    if min(map(len, groups)) < 3:
        raise ValueError("Grain verification needs three reopened documents per state")
    for bins in groups[0] + groups[1]:
        if len(bins) != 768 or min(bins) < 0 or sum(bins) == 0:
            raise ValueError("Invalid histogram population")
    def distance(a, b):
        # Compare normalized counts even when Photoshop chooses a different histogram cache level.
        na, nb = sum(a), sum(b)
        return sum(abs(x / na - y / nb) for x, y in zip(a, b)) / 2
    within = max(distance(a, b) for group in groups for a, b in combinations(group, 2))
    between = min(distance(a, b) for a, b in product(*groups))
    return {"maximumWithin": within, "minimumBetween": between}
