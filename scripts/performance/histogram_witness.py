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


def native_pixel_separation(witness):
    """Hold out three or more A/B pairs after choosing positions from the first pair."""
    samples = witness["samples"]
    points = witness["coordinates"]
    if (len(samples) < 8 or len(samples) % 2 or len(points) > 256 or len(set(map(tuple,points))) != len(points)
            or any(len(s) != len(points) for s in samples) or any(len(pixel)!=3 or
            any(type(v) is not int or not 0 <= v <= 255 for v in pixel) for frame in samples for pixel in frame)):
        raise ValueError("Incomplete native pixel comparison")
    hits = 0
    for i in range(len(points)):
        # The calibration pair selects a channel and sign. Subsequent pairs must
        # reproduce the direction across both entire populations, with a 2-code gap.
        initial = [samples[1][i][c]-samples[0][i][c] for c in range(3)]
        channel = max(range(3),key=lambda c:abs(initial[c]))
        if abs(initial[channel]) < 2: raise ValueError("Invalid native pixel calibration")
        high, low = (1,0) if initial[channel]>0 else (0,1)
        highs = [s[i][channel] for s in samples[2+high::2]]
        lows = [s[i][channel] for s in samples[2+low::2]]
        hits += min(highs) >= max(lows)+2
    return {"calibratedTiles":len(points),"verifiedTiles":hits,
            "qualified":len(points)>=16 and hits>=.9*len(points)}
