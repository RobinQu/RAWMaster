"""Measure existing Lightroom Classic catalogs without writing to the source.

Only aggregate counts are emitted. Each SQLite handle is backed up separately.
Preview joins are candidates from these snapshots, not a guarantee of an exact look.
"""
import argparse
from contextlib import closing
import hashlib
import json
from pathlib import Path
import re
import sqlite3
import subprocess
import tempfile


def snapshot(source, target):
    with closing(sqlite3.connect(source.as_uri() + "?mode=ro", uri=True)) as reader:
        reader.execute("PRAGMA query_only=ON")
        with closing(sqlite3.connect(target)) as writer:
            reader.backup(writer)


def decode_jpeg(path, temp):
    with path.open("rb") as stream:
        if stream.read(3) != bytes.fromhex("FFD8FF"):
            return False
    output = temp / "preview.png"
    output.unlink(missing_ok=True)
    result = subprocess.run(["/usr/bin/sips", "-s", "format", "png", "-Z", "64", str(path),
                             "--out", str(output)], capture_output=True)
    return result.returncode == 0 and output.is_file() and output.read_bytes().startswith(b"\x89PNG\r\n\x1a\n")


def decode_packed_level(path, temp):
    # These observed AgHg records carry a header size, payload length and padding length.
    # Keep the sample bounded and require a complete record chain before using any level.
    levels = []
    with path.open("rb") as stream:
        end = path.stat().st_size
        while stream.tell() < end:
            start = stream.tell()
            header = stream.read(24)
            if len(header) != 24 or header[:4] != b"AgHg":
                return False
            header_size = int.from_bytes(header[4:6], "big")
            length = int.from_bytes(header[8:16], "big")
            padding = int.from_bytes(header[16:24], "big")
            next_start = start + header_size + length + padding
            if not 24 <= header_size <= 256 or next_start > end:
                return False
            label = stream.read(header_size - 24).rstrip(b"\0")
            if re.fullmatch(rb"level_[0-9]+", label) and 4 <= length <= 128 * 1024 * 1024:
                levels.append((int(label[6:]), stream.tell(), length))
            stream.seek(next_start)
        for _, offset, length in sorted(levels, reverse=True):
            stream.seek(offset)
            jpeg = stream.read(length)
            if jpeg.startswith(bytes.fromhex("FFD8FF")) and jpeg.endswith(bytes.fromhex("FFD9")):
                extracted = temp / "packed-level.jpg"
                extracted.write_bytes(jpeg)
                if decode_jpeg(extracted, temp):
                    return True
    return False


def inspect_catalog(path, temp):
    local = temp / "catalog.sqlite"
    snapshot(path, local)
    with closing(sqlite3.connect(local)) as db:
        tables = {row[0] for row in db.execute("SELECT name FROM sqlite_schema WHERE type='table'")}
        # The aliases and fields below are tied to the observed sample schemas.
        domain = {"images": "Adobe_images", "files": "AgLibraryFile", "folders": "AgLibraryFolder",
                  "volumes": "AgLibraryRootFolder", "collections_all_types": "AgLibraryCollection",
                  "collection_memberships": "AgLibraryCollectionImage", "folder_stack_memberships": "AgLibraryFolderStackImage",
                  "collection_stack_memberships": "AgLibraryCollectionStackImage", "keyword_memberships": "AgLibraryKeywordImage",
                  "develop_rows": "Adobe_imageDevelopSettings"}
        counts = {name: db.execute("SELECT COUNT(*) FROM " + table).fetchone()[0] if table in tables else None
                  for name, table in domain.items()}
        version = db.execute("SELECT value FROM Adobe_variablesTable WHERE name='Adobe_DBVersion'").fetchone()
        if "Adobe_images" not in tables or not version:
            raise RuntimeError("Unknown catalog layout")
        def value(sql):
            return db.execute(sql).fetchone()[0]
        counts["virtual_copies"] = value("SELECT count(*) FROM Adobe_images WHERE masterImage IS NOT NULL")
        counts["missing_master_reference"] = value("""SELECT count(*) FROM Adobe_images i
            LEFT JOIN Adobe_images m ON m.id_local=i.masterImage WHERE i.masterImage IS NOT NULL AND m.id_local IS NULL""")
        counts["missing_file_reference"] = value("""SELECT count(*) FROM Adobe_images i
            LEFT JOIN AgLibraryFile f ON f.id_local=i.rootFile WHERE f.id_local IS NULL""")
        counts["smart_collections"] = value("""SELECT count(*) FROM AgLibraryCollection
            WHERE creationId='com.adobe.ag.library.smart_collection'""")
        counts["groups_of_collections"] = value("""SELECT count(*) FROM AgLibraryCollection
            WHERE creationId='com.adobe.ag.library.group'""")
        sample = db.execute("""SELECT CAST(text AS BLOB) FROM Adobe_imageDevelopSettings
            WHERE length(text)>0 ORDER BY id_local LIMIT 24""").fetchall()
        # Store and reopen opaque payloads in the research scratch directory, without parsing Adobe settings.
        for i, (payload,) in enumerate(sample):
            dest = temp / ("opaque-%d.bin" % i)
            dest.write_bytes(payload)
            assert hashlib.sha256(payload).digest() == hashlib.sha256(dest.read_bytes()).digest()
        result = {"catalog_bytes": path.stat().st_size, "adobe_db_version": str(version[0]), "counts": counts,
                  "opaque_sample_byte_roundtrips": len(sample),
                  "lrcat_data_kind": "directory" if path.with_suffix(".lrcat-data").is_dir() else
                                     ("file" if path.with_suffix(".lrcat-data").is_file() else "missing")}
        folder = path.with_name(path.stem + " Previews.lrdata")
        if not (folder / "previews.db").is_file():
            result["previews"] = {"status": "no adjacent previews.db"}
            return result
        preview = temp / "previews.sqlite"
        snapshot(folder / "previews.db", preview)
        db.execute("ATTACH ? AS pv", (str(preview),))
        seen = {row[0] for row in db.execute("SELECT name FROM pv.sqlite_schema WHERE type='table'")}
        if not {"ImageCacheEntry", "Pyramid"} <= seen:
            result["previews"] = {"status": "unprobed preview index schema"}
            return result
        joined = """FROM pv.ImageCacheEntry e JOIN Adobe_images i ON i.id_local=e.imageId
            JOIN pv.Pyramid p ON p.uuid=e.uuid AND p.digest=e.digest"""
        previews = {"status": "index inspected", "image_candidates": value("SELECT COUNT(DISTINCT i.id_local) "+joined),
                    "virtual_copy_candidates": value("SELECT COUNT(DISTINCT i.id_local) "+joined+" WHERE i.masterImage IS NOT NULL"),
                    "sampled_candidates": 0, "sampled_level_jpeg_decoded": 0,
                    "sampled_unpacked_jpeg_decoded": 0, "sampled_packed_jpeg_decoded": 0}
        for uuid, digest in db.execute("SELECT e.uuid,e.digest "+joined+" ORDER BY (i.masterImage IS NULL),i.id_local LIMIT 3"):
            previews["sampled_candidates"] += 1
            bucket = folder / uuid[0].upper() / uuid[:4].upper()
            if not bucket.is_dir():
                continue
            prefix = uuid + "-" + digest + "_"
            levels = [p for p in bucket.iterdir() if p.name.startswith(prefix) and p.name[len(prefix):].isdigit()]
            if any(decode_jpeg(p, temp) for p in sorted(levels, key=lambda p: int(p.name[len(prefix):]), reverse=True)):
                previews["sampled_unpacked_jpeg_decoded"] += 1
            else:
                packed = bucket / (uuid + "-" + digest + ".lrprev")
                if not packed.is_file() or not decode_packed_level(packed, temp):
                    continue
                previews["sampled_packed_jpeg_decoded"] += 1
            previews["sampled_level_jpeg_decoded"] += 1
        result["previews"] = previews
        return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("catalogs", type=Path, nargs="+")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    results = []
    args.output.parent.mkdir(parents=True, exist_ok=True)
    for path in sorted((p.resolve(strict=True) for p in args.catalogs), key=lambda p: (p.stat().st_size, p.name)):
        with tempfile.TemporaryDirectory(prefix="lr-census-", dir=args.output.parent) as directory:
            results.append(inspect_catalog(path, Path(directory)))
    with args.output.open("x") as out:
        json.dump(results, out, ensure_ascii=False, indent=2)
        out.write("\n")


if __name__ == "__main__":
    main()
