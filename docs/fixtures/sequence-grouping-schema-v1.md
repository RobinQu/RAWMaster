# Sequence JPEG fixtures schema v1

The converter input is `Tests/Fixtures/SequenceGroupingInputs/v1/cases.json`.
The published dataset is `Tests/RAWMasterImagingTests/Fixtures/SequenceGrouping/v1`.
All paths in these JSON documents are relative. The external original-media base is supplied only at execution with `--source-base`.

## Dataset index (`index.json`)

```json
{"schemaVersion":1,"datasetID":"sequence-grouping-jpeg-v1","converterVersion":"sequence-fixtures-imageio-v1","assetCount":1265,"recipe":{"maximumPixel":1024,"jpegQuality":0.8,"colorSpace":"sRGB","orientation":1,"rawMode":"embedded-preview-only","exposureAbsoluteToleranceSeconds":0.00000001,"exposureRelativeTolerance":0.000001},"cases":[{"id":"burst123","assetCount":123,"manifestPath":"cases/burst123/manifest.json","metadataPath":"cases/burst123/metadata.json","truthPath":"truth/burst123.json","manifestSHA256":"hex","metadataSHA256":"hex","truthSHA256":"hex","completeGroupTruth":true,"unknownAssetIDs":[]}]}
```

Case IDs/counts: `burst123`/123, `burst14-context38`/38, `burst48-context72`/72, `interval427-context439`/439, `burst193-context217`/217, `dji187-context376`/376. Only the DJI case has `completeGroupTruth:false` and `unknownAssetIDs:["asset0374","asset0375"]`. 0187 is known inside; 0188 is unknown. No negative labels are inferred from other context or directory limits.

## Per-case manifest

```json
{"schemaVersion":1,"scopeID":"fixture-burst123","sessionID":"fixture-burst123","orderVersion":"session-natural-path-v1","files":[{"assetID":"asset0000","ordinal":0,"relativePath":"files/asset0000.jpg","jpegSHA256":"hex","width":1024,"height":683,"sourceCapture":{"relativePath":"2026-10-04-c/DCIM/100MSDCF/DSC02468.ARW","originalExtension":"ARW","sha256":"hex"}}]}
```

This is a ProbeManifest-compatible document (extra provenance fields are ignored by its decoder). `relativePath` is relative to the containing case directory. Every asset has its own JPEG, including both DNG and JPG assets at the same capture time. `assetID` and original ordinal never change.

**FixtureJPEGIdentity** is the actual JPEG bytes/hash plus fixture metadata revision. Core manifest, token and source-declaration fingerprints MUST be built anew from these bytes by the real reader. **SourceCapture** is provenance only: its original hash/path cannot become the current JPEG contentHash or retain the old RAW assertion/token.

## Per-case metadata

```json
{"schemaVersion":1,"caseID":"burst123","assets":[{"assetID":"asset0000","sourceCapture":{"dateTimeOriginalRaw":"2026:10:02 12:12:13","subsecTimeOriginalRaw":"648","offsetTimeOriginalRaw":null,"exposureSeconds":0.001,"cameraMake":"SONY","cameraModel":"ILCE-1M2","orientation":8},"expectedJPEG":{"dateTimeOriginalRaw":"2026:10:02 12:12:13","subsecTimeOriginalRaw":"648","offsetTimeOriginalRaw":null,"exposureSeconds":0.001,"cameraMake":"SONY","cameraModel":"ILCE-1M2","orientation":1},"exposureRoundtrip":{"actualSeconds":0.001,"absoluteDifferenceSeconds":0.0,"allowedDifferenceSeconds":0.00000001},"sourceIntegrity":{"sha256Before":"hex","sha256After":"hex","credentialUnchanged":true}}]}
```

Every capture-object key is present; absent source metadata is explicit JSON null, never a wildcard or synthesized UTC/date. `expectedJPEG.exposureSeconds` is the source numeric exposure; its actual decoded value is recorded separately. Allowed numeric error is max(1e-8 seconds, abs(source)*1e-6). Missing exposure must remain missing. Exact date/subsec/offset/make/model strings must roundtrip unchanged. Original orientation is provenance only; upright output orientation is 1. Dimensions and hashes are in the manifest. No GPS, body/lens serial, MakerNotes, absolute paths, raw metadata dumps or private stat credentials are published.

Sidecars verify expectations; they are never injected into reader/preprocessor/detector. The offline harness must invoke the actual SequenceCaptureReader and inspect actual JPEG metadata/pixels. Transcoding may change features and grouping; JPEG behavior is measured, not assumed identical to RAW.

## Human truth and behavior baselines

`truth/<case>.json` is directly ProbeLabels-compatible: schemaVersion 1, role `development-regression-fixture`, groups `{id,kind,assetIDs}`, negativePairs `{from,to}`. Existing five cases retain exact human memberships/negative edges. DJI has one known-positive interval group of 374 assets, no negatives, and two unknown assets identified by index metadata. Its exact/full-quality endpoint acceptance is NOT established; evaluating the known-positive subset does not manufacture a negative endpoint. All cases are now development/regression, not fresh holdouts.

Human truth is physically separate from behavior goldens. Core owns approved goldens outside `truth` (and never generates them silently during tests). A default known-behavior regression pass does not mean human quality acceptance. A dedicated full-quality command must report known failures and exit nonzero while any case is not accepted; missing negative support/unknown full extent cannot become success.

## Input specification and publication

`cases.json` contains schemaVersion, datasetID, recipe, and cases with id, sourceRelativeRoot, files `{assetID,ordinal,relativePath}`, truthPath (relative to the input-spec directory), completeGroupTruth, unknownAssetIDs. Existing frozen manifests/labels and filename-only inventory supply the scope; no directory scan selects data.

The converter stages the entire tree under ignored `output/`, writes and verifies all frames, source before/after full SHA256 and fresh file credentials, metadata and output dimensions/hash, and only then atomically renames the complete directory into an absent final destination on the same filesystem. Any failure aborts publication without dropping assets or decoding RAW as fallback. Original sources are read-only. Detailed local execution errors/receipts belong in output, not fixture sidecars.
