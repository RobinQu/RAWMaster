# Sequence grouping JPEG regression data

The six explicit cases retain 1,265 original file identities and ordering. The input specification selects only the listed files; the converter never scans media directories. Supply the original media base separately at execution. Do not put absolute source paths in tracked files.

The published resource directory is `Tests/RAWMasterImagingTests/Fixtures/SequenceGrouping/v1`. Its index and per-case manifests contain actual JPEG hashes. Original hashes and paths are provenance, never current input identities. See `docs/fixtures/sequence-grouping-schema-v1.md` for the complete schema.

The recipe uses embedded previews for RAW sources, with no full RAW decode fallback. JPEG sources are decoded as JPEG. Each output is an upright, longest-edge-at-most-1024, quality-0.8 sRGB JPEG. DateTimeOriginal, SubsecTimeOriginal, OffsetTimeOriginal, ExposureTime, Make and Model are the only copied capture metadata. Orientation is baked into pixels and written as 1; original orientation is recorded only in provenance. GPS, device/lens serials and MakerNotes are excluded. Missing metadata remains missing. Exposure rational conversion is bounded by max(1e-8 seconds, abs(source exposure)*1e-6), with actual error recorded.

The six cases are development/regression data, not fresh independent holdouts. Immutable user memberships and explicit negative boundaries live in `truth/`; model behavior snapshots live separately in `baselines/`. Other context is unlabeled. The DJI case preserves every DNG/JPG file as a distinct asset; sharing names/times is not a pairing claim. Captures 0001–0187 (374 assets) are known inside the interval sequence. Capture 0188 (two assets) has unknown membership; neither side of this case establishes a known negative endpoint. `completeGroupTruth:false` prevents a whole-group quality claim.

Lossy JPEG conversion can change features and grouping. The first JPEG behavior snapshot must be measured through the actual shipped reader and detector, not copied from source RAW reports. Passing the default behavior regression does not imply grouping quality passes. The separate full-quality command reports remaining failures and evidence gaps and exits nonzero while acceptance is unmet.

The converter hashes each original before processing and again after all outputs, comparing fresh filesystem credentials too. It uses bounded serial work and per-chunk memory scopes. Missing previews, metadata mismatch, output decode failure, source changes or any missing asset abort the entire publication. Staging remains outside formal test resources until all checks pass; publication is one same-filesystem rename into an absent destination. No source file is modified.

## Rebuild

Compile `scripts/make-sequence-fixtures.swift` with the macOS SDK, then run the resulting tool with `--input-spec Tests/Fixtures/SequenceGroupingInputs/v1/cases.json --source-base <local-media-base> --output Tests/RAWMasterImagingTests/Fixtures/SequenceGrouping/v1 --staging-base output/fixture-staging`. An existing final directory is deliberately refused. Review a rebuilt version in a new destination; never silently overwrite an approved dataset or behavior baseline.

## Copyright and scope

These photographic derivatives come from user-supplied photographs and are published with the user's authorization for this repository. Their copyright remains with the respective rights holders. The repository's software license does not grant a separate open license for these photographs. No third-party photo license or unrestricted reuse permission is invented here. Conversion scripts, schemas and test code are separate from photographic rights.
