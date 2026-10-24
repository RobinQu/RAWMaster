#!/bin/bash
# 0 = quality accepted; 2 = valid completed evaluation, quality unmet;
# 1 = build, execution, integrity, baseline, or report failure.
set -euo pipefail
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"
if [[ -n "${RAWMASTER_SEQUENCE_FIXTURE_RECORD_CANDIDATE:-}" ]]; then
  echo "Quality evaluation cannot record behavior baselines." >&2
  exit 1
fi
canonical_report_path() {
  python3 - "$repository_root" "$1" <<'PY'
from pathlib import Path
import sys
try:
    repository = Path(sys.argv[1]).resolve(strict=True)
    requested = sys.argv[2]
    if not requested.strip():
        raise ValueError('report path must not be empty')
    # strict=False resolves every existing symlink ancestor, including when the
    # requested filename or a suffix of its parent directories does not exist.
    target = Path(requested).resolve(strict=False)
    protected = [
        (repository / 'Tests/RAWMasterImagingTests/Fixtures').resolve(strict=False),
        (repository / 'Tests/Fixtures/SequenceGroupingInputs').resolve(strict=False),
    ]
    if any(target == root or root in target.parents for root in protected):
        raise ValueError('report path resolves inside protected fixtures or input truth')
    if target.is_dir():
        raise ValueError('report path must name a file, not a directory')
    print(target)
except (OSError, RuntimeError, ValueError) as error:
    print('Unsafe quality report destination: ' + str(error), file=sys.stderr)
    sys.exit(1)
PY
}
# Validate before even querying Swift; aliases must never target public truth or goldens.
requested_report="$(canonical_report_path "${RAWMASTER_SEQUENCE_FIXTURE_REPORT-$repository_root/output/validation/sequence-fixtures-quality.json}")"
run_directory="$(mktemp -d "${TMPDIR:-/tmp}/rawmaster-fixture-quality.XXXXXX")"
trap 'rm -rf "$run_directory"' EXIT
export RAWMASTER_SEQUENCE_FIXTURE_RUN_ID="$(/usr/bin/uuidgen)"
export RAWMASTER_SEQUENCE_FIXTURE_REQUIRE_QUALITY=1
export RAWMASTER_SEQUENCE_FIXTURE_REPORT="$run_directory/report.json"
export RAWMASTER_SEQUENCE_FIXTURE_SWIFT_VERSION="$(swift --version)"
set +e
swift test --filter SequenceFixtureRegressionTests/testFullOfflineDataset
swift_status=$?
set -e
# A current complete typed report is mandatory. Old reports cannot mask a failed run.
if ! python3 - "$RAWMASTER_SEQUENCE_FIXTURE_REPORT" "$RAWMASTER_SEQUENCE_FIXTURE_RUN_ID" <<'PY'
import json, sys
try:
    report = json.load(open(sys.argv[1]))
    expected = {'burst123':123, 'burst14-context38':38, 'burst48-context72':72,
                'interval427-context439':439, 'burst193-context217':217, 'dji187-context376':376}
    assert report['schemaVersion'] == 1 and report['runID'] == sys.argv[2]
    assert report['mode'] == 'quality' and report['integrityValidated'] is True
    assert report['behaviorValidated'] is True and isinstance(report['qualityAccepted'], bool)
    cases = report['cases']
    assert len(cases) == 6 and {c['id']:c['assetCount'] for c in cases} == expected
    assert all(c['integrityValidated'] is True for c in cases)
except Exception as error:
    print('No valid completed quality report for this run: ' + str(error), file=sys.stderr)
    sys.exit(1)
PY
then
  exit 1
fi
# Recheck before publication in case an ancestor changed while the tests ran.
requested_report="$(canonical_report_path "$requested_report")"
mkdir -p "$(dirname "$requested_report")"
cp "$RAWMASTER_SEQUENCE_FIXTURE_REPORT" "$requested_report"
quality_accepted="$(python3 -c 'import json,sys; print("yes" if json.load(open(sys.argv[1]))["qualityAccepted"] else "no")' "$requested_report")"
echo "Offline JPEG quality report: $requested_report"
if [[ "$swift_status" == 0 && "$quality_accepted" == yes ]]; then exit 0; fi
if [[ "$swift_status" == 1 && "$quality_accepted" == no ]]; then exit 2; fi
echo "Test exit status and completed quality report disagree (status $swift_status)." >&2
exit 1
