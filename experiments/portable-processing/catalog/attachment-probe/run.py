import argparse
from contextlib import closing
import hashlib
import json
from pathlib import Path
import platform
import sqlite3
import subprocess
import tempfile


def probe(binary, mode, wal_state):
    with tempfile.TemporaryDirectory(prefix="rawmaster-attachment-") as temporary:
        result = subprocess.check_output([binary, temporary, mode, wal_state], text=True)
        row = json.loads(result)
        main = Path(temporary) / "database.sqlite"
        with closing(sqlite3.connect(main.as_uri() + "?mode=ro&immutable=1", uri=True)) as connection:
            writer, marker = connection.execute("select writer,marker from probe where id=1").fetchone()
            integrity = connection.execute("pragma quick_check").fetchone()[0]
        row["afterClose"] = {"writer": writer, "marker": marker, "quickCheck": integrity,
                             "mainSHA256": hashlib.sha256(main.read_bytes()).hexdigest()}
    assert (writer, marker) == ("same-writer", row["markerBefore"]) and integrity == "ok"
    assert row["txnBefore"] == row["txnAfter"] == (1 if mode == "read" else 2)
    assert row["forbiddenSQL"] == row["changesBefore"] == row["changesAfter"] == 0
    assert (row["wal"]["bytes"] == 0) == (wal_state == "empty")
    controls = ("connectionFileStat", "mainFileStat", "walFileStat")
    row["allControlsUnavailable"] = all(row[control + "RC"] in (0, 12) and row[control + "Bytes"] == 0
                                         for control in controls)
    return row


def main():
    parser = argparse.ArgumentParser(description="Check attachment diagnostic capability on the host SQLite")
    parser.add_argument("--output", type=Path, required=True, help="a new directory for the binary and JSON receipt")
    output = parser.parse_args().output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    source = Path(__file__).resolve().with_name("capability.c")
    binary = output / "capability"
    subprocess.run(["/usr/bin/clang", "-std=c11", "-D_DARWIN_C_SOURCE", "-O1", "-Wall", "-Wextra", "-Werror",
                    source, "-lsqlite3", "-o", binary], check=True)
    cases = [probe(binary, mode, wal_state) for mode in ("read", "write") for wal_state in ("empty", "dirty")]
    receipt = {"macOS": platform.mac_ver()[0], "arch": platform.machine(), "cases": cases,
               "available": not all(row["allControlsUnavailable"] for row in cases)}
    (output / "receipt.json").write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n")
    print(output / "receipt.json")


if __name__ == "__main__":
    main()
