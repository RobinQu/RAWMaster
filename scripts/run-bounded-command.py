#!/usr/bin/env python3
"""Run one owned command with a bounded wall clock and an append-only log."""
import argparse
import os
import signal
import subprocess
import sys
import time


def descendants(root: int) -> list[int]:
    found: list[int] = []
    try:
        children = subprocess.check_output(["pgrep", "-P", str(root)], text=True).split()
    except (subprocess.CalledProcessError, FileNotFoundError):
        children = []
    for child in children:
        pid = int(child)
        found.extend(descendants(pid))
        found.append(pid)
    return found


def signal_pids(pids: list[int], sig: int) -> None:
    for pid in pids:
        try:
            os.kill(pid, sig)
        except ProcessLookupError:
            pass


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--seconds", type=float, required=True)
    parser.add_argument("--log", required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command or args.seconds <= 0:
        parser.error("positive --seconds and a command are required")
    os.makedirs(os.path.dirname(os.path.abspath(args.log)), exist_ok=True)
    started = time.monotonic()
    with open(args.log, "ab", buffering=0) as log:
        log.write(f"\nBOUNDED START {time.strftime('%Y-%m-%d %H:%M:%S')} timeout={args.seconds}\n".encode())
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        timed_out = False
        try:
            result = process.wait(timeout=args.seconds)
        except subprocess.TimeoutExpired:
            timed_out = True
            owned = descendants(process.pid)
            signal_pids(owned, signal.SIGTERM)
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                signal_pids(owned, signal.SIGKILL)
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()
            result = 124
        elapsed = time.monotonic() - started
        log.write(f"BOUNDED END exit={result} timedOut={str(timed_out).lower()} elapsed={elapsed:.6f}\n".encode())
    return result


if __name__ == "__main__":
    sys.exit(main())
