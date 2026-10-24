#!/usr/bin/env python3
"""Run a benchmark with a process-group watchdog and explicit failure evidence."""
import argparse
import json
import os
import signal
import subprocess
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--timeout', type=float, default=180)
    parser.add_argument('--log', type=Path, required=True)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command or args.timeout <= 0:
        parser.error('A command and positive timeout are required')
    args.log.parent.mkdir(parents=True, exist_ok=True)
    result = {'status': 'failed', 'timeoutSeconds': args.timeout}
    with args.log.open('wb') as output:
        process = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = process.wait(timeout=args.timeout)
            result.update(status='passed' if code == 0 else 'command-failed', exitCode=code)
        except subprocess.TimeoutExpired:
            result['status'] = 'timeout'
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            code = 124
    args.log.with_suffix('.command.json').write_text(json.dumps(result, indent=2) + '\n')
    if code != 0:
        (args.log.parent / 'summary.json').write_text(json.dumps({'passed': False, 'command': args.log.stem, **result}, indent=2) + '\n')
        print(f"Benchmark {result['status']}; inspect {args.log}")
    return code


if __name__ == '__main__':
    raise SystemExit(main())
