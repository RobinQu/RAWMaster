"""Check a SQLite R-tree against an exhaustive scan of existing Lightroom GPS rows.

The source opens read-only. Coordinates, photo IDs and fence centers stay in memory.
Only counts, the SQLite version and elapsed times are written to the requested output.
"""
import argparse
from contextlib import closing
import json
import math
from pathlib import Path
import sqlite3
import statistics
import time


def lon_offset(lon, origin):
    return (lon - origin + 180) % 360 - 180


def angle_between(lat, lon, lat0, lon0):
    a, b = math.radians(lat), math.radians(lat0)
    chord = math.sin((a - b) / 2) ** 2 + math.cos(a) * math.cos(b) * math.sin(
        math.radians(lon_offset(lon, lon0)) / 2) ** 2
    return 2 * math.asin(math.sqrt(min(1, chord)))


def longitude_ranges(low, high):
    if high - low >= 360:
        return [(-180, 180)]
    start = lon_offset(low, 0)
    end = start + high - low
    return [(start, end)] if end <= 180 else [(start, 180), (-180, end - 360)]


def inside_polygon(x, y, vertices):
    inside = False
    for (ax, ay), (bx, by) in zip(vertices, vertices[1:] + vertices[:1]):
        cross = (bx - ax) * (y - ay) - (by - ay) * (x - ax)
        if abs(cross) < 1e-12 and min(ax, bx) <= x <= max(ax, bx) and min(ay, by) <= y <= max(ay, by):
            return True
        if (ay > y) != (by > y) and x < (bx - ax) * (y - ay) / (by - ay) + ax:
            inside = not inside
    return inside


def measure(db, points, predicate, latitude_range, longitude_intervals):
    oracle = {key for key, (lat, lon) in points.items() if predicate(lat, lon)}
    sql = """SELECT id FROM geo WHERE max_lat >= ? AND min_lat <= ?
             AND max_lon >= ? AND min_lon <= ?"""

    def indexed():
        candidates = {row[0] for lo, hi in longitude_intervals
                      for row in db.execute(sql, (*latitude_range, lo, hi))}
        return candidates, {key for key in candidates if predicate(*points[key])}

    candidates, matched = indexed()
    if matched != oracle:
        raise ValueError("Indexed result differs from exhaustive scan")
    elapsed = []
    for _ in range(31):
        start = time.perf_counter_ns()
        indexed()
        elapsed.append((time.perf_counter_ns() - start) / 1e6)
    return {"bbox_candidates": len(candidates), "matches": len(matched), "same_ids_as_full_scan": True,
            "warm_n": len(elapsed), "p50_ms": round(statistics.median(elapsed), 3),
            "p95_ms": round(sorted(elapsed)[math.ceil(.95 * len(elapsed)) - 1], 3)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    with closing(sqlite3.connect(args.catalog.resolve(strict=True).as_uri() + "?mode=ro", uri=True)) as source:
        source.execute("PRAGMA query_only=ON")
        source.execute("BEGIN")
        images = source.execute("SELECT COUNT(*) FROM Adobe_images").fetchone()[0]
        rows = source.execute("""SELECT i.id_local, e.gpsLatitude, e.gpsLongitude
            FROM Adobe_images i JOIN AgHarvestedExifMetadata e ON e.image=i.id_local
            WHERE e.hasGPS=1 AND e.gpsLatitude BETWEEN -90 AND 90
            AND e.gpsLongitude BETWEEN -180 AND 180 ORDER BY i.id_local""").fetchall()
    if not rows:
        raise ValueError("No usable GPS points in this catalog")
    points = {k: (lat, lon) for k, lat, lon in rows}
    if len(points) != len(rows):
        raise ValueError("Multiple GPS records for the same image require a provenance decision")
    _, lat0, lon0 = rows[len(rows) // 2]
    radius = math.radians(25 / 111.19508)
    span = math.degrees(radius)
    lat_min, lat_max = max(-90, lat0 - span), min(90, lat0 + span)
    lon_span = 180 if lat_min == -90 or lat_max == 90 else math.degrees(
        math.asin(min(1, math.sin(radius) / math.cos(math.radians(lat0)))))
    # The selected real photo is also a vertex, so inclusion on the polygon boundary is exercised.
    polygon = [(0, 0), (.3, -.1), (.6, .3), (.1, .6)]
    with closing(sqlite3.connect(":memory:")) as db:
        db.execute("CREATE VIRTUAL TABLE geo USING rtree(id,min_lat,max_lat,min_lon,max_lon)")
        db.executemany("INSERT INTO geo VALUES(?,?,?,?,?)", [(k, a, a, b, b) for k, a, b in rows])
        circle = measure(db, points, lambda a, b: angle_between(a, b, lat0, lon0) <= radius,
                         (lat_min, lat_max), longitude_ranges(lon0 - lon_span, lon0 + lon_span))
        poly = measure(db, points, lambda a, b: inside_polygon(lon_offset(b, lon0), a - lat0, polygon),
                       (lat0 - .1, lat0 + .6), longitude_ranges(lon0, lon0 + .6))
    report = {"sqlite": sqlite3.sqlite_version, "catalog_images": images, "usable_gps": len(rows),
              "no_usable_gps": images - len(rows), "circle_25_km": circle, "local_polygon": poly}
    with args.output.open("x") as out:
        json.dump(report, out, indent=2)
        out.write("\n")


if __name__ == "__main__":
    main()
