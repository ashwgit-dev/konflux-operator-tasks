# Design: binaryless, multi-version FIPS matrix (0.2)

This document explains the main design changes in `fbc-fips-check-matrix-based-oci-ta`
0.2 compared to 0.1, and the changes in its paired producer task
`fbc-fips-prepare-oci-ta` 0.2 that drive them.

The two tasks are a pair and must move together:

- `fbc-fips-prepare-oci-ta` — extracts the relatedImages that need scanning and
  writes them into bucket files + array results for matrix expansion (the producer).
- `fbc-fips-check-matrix-based-oci-ta` — one matrix worker that scans a single
  bucket with `check-payload` (the consumer).

## 1. The core change: 1-D matrix → 2-D matrix

### 0.1 model

A binary-backed FBC fragment has **one** target OCP version. The prepare task
derived that single version, extracted the unique relatedImages across the whole
fragment, and distributed them into `N` buckets:

```
bucket-0.txt, bucket-1.txt, ... bucket-<N-1>.txt
target_ocp_version.txt          # one shared version for all buckets
```

The pipeline fanned out a **1-dimensional** matrix over `BUCKET_INDEX` only. Every
check worker read the single shared `target_ocp_version.txt` and scanned its bucket.

### 0.2 model

A **binaryless** FBC fragment declares a **list** of target OCP versions via the
`com.redhat.fbc.openshift.version` label, e.g. `["v4.15","v4.16","v4.17"]`. Each
targeted version must be scanned independently because `check-payload` applies a
**per-OCP-version exception set** via `-V=<version>`. The same image under v4.15 and
v4.17 is two distinct scans.

So the unit of work is no longer a bucket — it is an **(OCP version, bucket) cell**.
The prepare task now emits a per-version bucket grid:

```
bucket-<version>-<index>.txt    # e.g. bucket-4.15-0.txt, bucket-4.16-0.txt
```

and two array results instead of one, so the pipeline fans out a **2-dimensional**
matrix `OCP_VERSION[*] × BUCKET_INDEX[*]`:

- `OCP_VERSIONS` — e.g. `["4.15","4.16","4.17"]`
- `BUCKET_INDICES` — e.g. `["0","1"]` (the grid **width**)

This is the central design shift. Everything below follows from it.

## 2. Changes to the check worker (`fbc-fips-check-matrix-based-oci-ta`)

The worker is deliberately thin; most of the change is in the producer. Its diff:

| Concern | 0.1 | 0.2 |
|---|---|---|
| New param | — | `OCP_VERSION` (which version's bucket to scan; `"none"` for the fallback grid) |
| `BUCKET_INDEX` meaning | which bucket | which bucket **within** the OCP version |
| Bucket file read | `bucket-${BUCKET_INDEX}.txt` | `bucket-${OCP_VERSION}-${BUCKET_INDEX}.txt` |
| Target OCP version | copied from the shared `target_ocp_version.txt` shipped by prepare | **written by the worker itself** from the `OCP_VERSION` param |
| Log labels | `bucket N` | `OCP <v> bucket N` |

The key behavioral change: prepare 0.2 **no longer ships a shared
`target_ocp_version.txt`**. Each worker owns its version and writes its own
`target_ocp_version.txt` from the `OCP_VERSION` param, which
`fips-operator-check-step-action` then passes to `check-payload` as `-V`.

## 3. Changes to the producer (`fbc-fips-prepare-oci-ta`) that drive this

### 3.1 Version discovery is label-based, not base-image-derived

0.2 reads the version **list** from the `com.redhat.fbc.openshift.version` label
and fails fast with a clear message (rather than crashing on a `jq` parse error) if:

- the label is missing / is not a JSON array — this task only supports binaryless
  fragments (`get_ocp_version_from_fbc_fragment` returns a plain version string as a
  fallback, which is now explicitly rejected), or
- the minimum targeted version is `< v4.15` (binaryless is only permitted `>= v4.15`).

### 3.2 Render once, attribute per version

Work that is version-independent is done **once** and reused across all versions to
avoid redundant renders:

- the fragment's per-arch digests,
- the fragment render + its package list,
- each **bundle's** SCAN/SKIP decision and its extracted relatedImages
  (memoized in `bundle_scan_decision_map` / `bundle_related_images_map`).

Work that **is** version-specific is done per version:

- resolving that version's target index
  (`registry.redhat.io/.../redhat-operator-index:v<version>`, with the
  `get_prev_ocp_version` fallback when the fragment has packages not yet released in
  that version's index),
- finding the unreleased bundles against that index,
- attributing the surviving relatedImages to that version
  (`ocp_version_related_images_map[version]`).

The result is serialized to a single document the splitter consumes:

```json
{ "4.15": ["img@sha", ...], "4.16": [...] }   # related_images_by_version.json
```

The **dedupe key is `(image, version)`**, not `image`. The same image can legitimately
appear under several versions. `TOTAL_IMAGES` now counts `(image, version)` pairs.

> Note: the `createdAt`-based legacy FIPS exemption (bundles created before the
> 2025-01-31 cutoff with a qualifying subscription are exempt unless they claim
> `fips-compliant=true`) now lives in prepare's per-bundle decision. This mirrors
> the logic already present in the standalone `fbc-fips-check` family and keeps the
> SCAN/SKIP decision in one place.

### 3.3 Per-version bucketing with a uniform grid width

Each version's images are size-fetched and load-balanced into buckets with the same
greedy "assign to lightest bucket" algorithm as 0.1, but now:

- `NUM_BUCKETS` means buckets **per OCP version** (the grid width target),
- each version computes `actual_buckets = max(1, min(NUM_BUCKETS, num_images))`,
- the grid is padded to the **widest** version so every `(version, index)` cell has a
  file; empty padded cells are a harmless no-op in the worker.

A rectangular grid is required because a Tekton matrix is a Cartesian product
`OCP_VERSION[*] × BUCKET_INDEX[*]` — every version must have a file at every index.

### 3.4 The "always run one worker" fallback

0.1 always launched at least one worker (even with no images) so that an error from
prepare — propagated via `test_output.txt` in the bucket artifact — still surfaces.

0.2 preserves this with a **minimal 1×1 grid**: it emits `OCP_VERSIONS=["none"]`,
`BUCKET_INDICES=["0"]`, and an empty `bucket-none-0.txt`. This is why the worker's
`OCP_VERSION` param documents `"none"` as a valid value. A single worker runs, copies
`test_output.txt`, and either propagates the error or no-ops.

## 4. Contract summary (what the pipeline wires together)

| | 0.1 | 0.2 |
|---|---|---|
| Matrix dimensions | `BUCKET_INDEX` | `OCP_VERSION` × `BUCKET_INDEX` |
| prepare results | `BUCKET_INDICES`, `TOTAL_IMAGES` | `OCP_VERSIONS`, `BUCKET_INDICES`, `TOTAL_IMAGES` |
| bucket files | `bucket-<i>.txt` | `bucket-<version>-<i>.txt` |
| target version source | shared `target_ocp_version.txt` from prepare | each worker writes its own from `OCP_VERSION` |
| dedupe key | `image` | `(image, version)` |
| `NUM_BUCKETS` | total buckets | buckets per version (grid width) |
| supported fragments | binary-backed (single version) | binaryless (version list, `>= v4.15`) |

## 5. Why not keep it 1-D?

Collapsing all versions into one bucket set would force a single `-V` value and lose
the per-version `check-payload` exception sets, producing both false positives and
false negatives. Running the versions sequentially inside one task would serialize
what is naturally parallel work. Expanding the matrix to two dimensions keeps each
scan correct (correct `-V`) and fully parallel across both versions and buckets.
