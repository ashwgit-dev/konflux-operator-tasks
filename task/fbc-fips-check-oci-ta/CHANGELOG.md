# Changelog

## 0.2

### Added

- Binaryless, multi-version variant of `fbc-fips-check-oci-ta`. Reads the **list** of target OCP versions from the `com.redhat.fbc.openshift.version` label and extracts/scans unreleased relatedImages **per version**, sharing the fragment render and per-bundle render across all versions. Binaryless FBC fragments are only permitted for OCP versions >= v4.15.

### Fixed

- Fail with a clear error instead of crashing on a `jq` parse error when `get_ocp_version_from_fbc_fragment` falls back to a plain version string (returned when the `com.redhat.fbc.openshift.version` label is missing) instead of the expected JSON array.

## Unreleased

### Fixed

- Bumped the `konflux-test` image to `v1.5.9`.
- Updated the `fips-operator-check-step-action` revision parameter to use `check-payload` release `0.4.1`.
- Bumped the `konflux-test` image to `v1.5.7`.
- Updated the `fips-operator-check-step-action` revision parameter to `006b00e`.
- Replace the ad-hoc 4-line minor-version arithmetic with a call to the shared `get_prev_ocp_version()` helper now available in `utils.sh` (`konflux-test:v1.5.0`). The helper correctly handles the v5.0 → v4.22 cross-major boundary.
- Updated the `fips-operator-check-step-action` revision parameter to use `check-payload` release `0.3.14`.
- Updated the `fips-operator-check-step-action` revision parameter to use `check-payload` release `0.3.15`.
- Updated the `fips-operator-check-step-action` revision parameter to use `check-payload` release `0.3.17`.

## 0.1

### Added

- Initial version of `fbc-fips-check-oci-ta` task
- Trusted Artifacts (`SOURCE_ARTIFACT`) variant of FBC fragment FIPS checking with `check-payload`
- Scans relatedImages from unreleased operator bundles in an FBC fragment image
- Parameters include `MAX_PARALLEL` and `image-mirror-set-path` for mirror resolution

### Note

This is the Trusted Artifacts variant of `fbc-fips-check` (`fbc-fips-check` uses a workspace source instead of `SOURCE_ARTIFACT`).
