from pathlib import Path
from hashlib import file_digest
import importlib.util
import os
import sys

BASE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(BASE))
spec = importlib.util.spec_from_file_location("existing_cases", BASE / "run.py")
cases = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cases)
HERE = Path(__file__).resolve().parent
cases.here = HERE


def digest(p):
    with p.open("rb") as f:
        return file_digest(f, "sha256").hexdigest()


def drive(binaries, arm, case, vm_count, folder):
    os.environ["RM_MAP_ARM"] = arm
    os.environ["RM_MAP_UNRELATED_VMAS"] = str(vm_count)
    bins = binaries
    report = cases.run(
        folder, case, bins / "filestat-keeper", bins / "librawmaster_library.so"
    )
    report["arm"] = arm
    report["unrelatedVMAsRequested"] = vm_count
    return report
