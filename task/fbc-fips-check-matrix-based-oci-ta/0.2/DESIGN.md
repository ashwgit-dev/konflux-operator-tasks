# Design Document: Binaryless Multi-Version FIPS Checking with Matrix Parallelism

| | |
|---|---|
| **Status** | Draft — for review |
| **Area** | `task/fbc-fips-prepare-oci-ta` 0.2, `task/fbc-fips-check-matrix-based-oci-ta` 0.2 |
| **Related** | `task/fbc-fips-check-oci-ta` 0.2 (standalone binaryless), `stepactions/fips-operator-check-step-action` 0.1 |
| **Author** | — |
| **Last updated** | 2026-11-02 |

## 1. Summary

Binaryless FBC fragments target a **list** of OCP versions. FIPS scanning is **version-dependent** (`check-payload -V=<version>` applies a per-version exception list), so each image must be scanned once per targeted version. The current standalone task does this correctly but **sequentially in a single pod**, which is slow for fragments with many related images.

This design adds a **prepare + matrix** pair that keeps the correct per-version extraction but **fans the scanning out across many pods** using a **2-dimensional Tekton matrix** (`OCP_VERSION` × `BUCKET_INDEX`). Each matrix branch scans one bucket of images for exactly one OCP version, with the correct `-V`.

## 2. Background & current state

- **`fbc-fips-check-oci-ta` 0.2 (standalone, binaryless).** Reads the version list from the `com.redhat.fbc.openshift.version` label, resolves unreleased bundles per version, extracts `relatedImages` per version, and scans. Extraction is correct and uses a shared render cache (fragment rendered once; each unique bundle rendered once). Scanning is **in-pod** only.
- **`fbc-fips-prepare-oci-ta` 0.1 + `fbc-fips-check-matrix-based-oci-ta` 0.1 (matrix family).** A single-OCP-version prepare/check pair: prepare extracts one flat image list and size-balances it into buckets; a 1-D matrix over `BUCKET_INDEX` scans the buckets in parallel. **Not version-aware.**
- **`fips-operator-check-step-action` 0.1.** The scanner. Reads one `target_ocp_version.txt`, turns it into `-V=<version>`, and scans up to `MAX_PARALLEL` images concurrently in-pod. **Unchanged by this design.**

The gap: the matrix family is single-version; the binaryless case is multi-version. This design closes that gap.

## 3. Goals / Non-goals

**Goals**
- Correctly scan every `(image, version)` pair with that version's `-V`.
- Parallelize scanning across pods (horizontal scale), not just within a pod.
- Reuse the existing step action unchanged.
- Keep the expensive extraction to a **single shared pass** (preserve the render cache).
- Follow repo conventions (tests, CHANGELOG, README, version dirs).

**Non-goals**
- Changing the FIPS decision logic (subscription / `fips-compliant` / legacy-date exemption) — ported as-is.
- Per-version attribution in failure *reporting* (see Open Questions).
- Deprecating or modifying the standalone 0.2 task (tracked separately).

## 4. Terminology

- **Pod / TaskRun.** One run of a Tekton Task is one Kubernetes Pod with a fixed CPU/memory budget.
- **In-pod parallelism.** Concurrency *inside* one pod (`MAX_PARALLEL` background scans sharing that pod's resources).
- **Fan-out.** Tekton creating *many* pods (TaskRuns) that run in parallel across the cluster — here, via `matrix`.
- **Scan unit.** A single `(image, version)` pair — the thing scanned with one `-V`.
- **Bucket.** A file listing a subset of a version's images, assigned to one scan branch.
- **Grid.** The cartesian set of `(version, bucket)` cells produced by the 2-D matrix.

## 5. Constraints

- **C1 — Multiple versions.** N target OCP versions per fragment (typically 1–6).
- **C2 — Scan is version-dependent.** Same image digest may pass under one `-V` and fail under another ⇒ scan unit is `(image, version)`; **no dedupe across versions**.
- **C3 — Extraction cache is per-process.** Fragment rendered once; each unique bundle rendered once; decisions/relatedImages are version-independent — cacheable only **within a single pod**. Splitting extraction across pods loses the cache.
- **C4 — Scanning dominates cost** for large fragments; it is the parallelization target.
- **C5 — Tekton cannot nest matrices.** A matrixed task cannot per-instance fan out another matrix.
- **C6 — One `-V` per scan run.** The step action applies a single `target_ocp_version.txt` to all images in its run ⇒ a scan unit must be **version-homogeneous**.

## 6. Chosen design (D3): shared prepare + 2-D cartesian matrix

### 6.1 Architecture

```
            ┌──────────────────────────────────────────────────────────┐
            │ fbc-fips-prepare-oci-ta (0.2)   — ONE pod                  │
            │  1. read version list from label  -> 4.18 4.19 4.20 4.21   │
            │  2. extract unreleased relatedImages PER VERSION           │
            │     (shared fragment + per-bundle render cache)            │
            │  3. size-balance each version's images into buckets        │
            │  4. pad grid; write bucket-<v>-<i>.txt + metadata          │
            │  results: OCP_VERSIONS, BUCKET_INDICES, BUCKETS_ARTIFACT,  │
            │           TOTAL_IMAGES                                     │
            └──────────────────────────────────────────────────────────┘
                         │ matrix: OCP_VERSION[*] × BUCKET_INDEX[*]
        ┌──────────┬──────────┬──────────┬───────────── … (versions × width pods)
        ▼          ▼          ▼          ▼
   check(4.18,0) check(4.18,1) check(4.19,0) …   — fbc-fips-check-matrix-based-oci-ta (0.2)
        │  each: read bucket-<v>-<i>.txt; write target_ocp_version.txt=<v>
        ▼
   fips-operator-check-step-action  (scan images with -V=<v>, MAX_PARALLEL in-pod)
```

### 6.2 Task 1 — `fbc-fips-prepare-oci-ta` 0.2

**Step `get-unique-related-images`** (ported from standalone 0.2 extraction):
- Read version list from `com.redhat.fbc.openshift.version`; validate `>= 4.15`.
- Render fragment once; for each version resolve its index (with previous-version fallback), find unreleased bundles across all arches, decide SCAN/SKIP per bundle (cached), and collect SCAN bundles' `relatedImages` per version.
- Output `related_images_by_version.json`: `{ "4.18": ["img@sha", ...], "4.19": [...] }`.
- Also write `related-images-map.txt` (mirror map), `images_processed.txt`, and on failure `test_output.txt`.

**Step `split-into-buckets`** (new):
- Read `related_images_by_version.json`; keep versions with ≥1 image.
- For each version, size-balance (skopeo size, sort desc, greedy lightest-bucket) into `min(NUM_BUCKETS, images)` buckets → `bucket-<version>-<i>.txt`.
- `grid_width = max` bucket count across versions; **pad** every version to `grid_width` with empty bucket files (so every cell has a file).
- Copy metadata files (notably **not** a global `target_ocp_version.txt`).
- Emit results.

**Step `create-buckets-artifact`:** push `/var/workdir/buckets` as the `BUCKETS_ARTIFACT` (unchanged from 0.1).

**Params:** `SOURCE_ARTIFACT`, `image-digest`, `image-url`, `image-mirror-set-path`, `ociStorage`, `NUM_BUCKETS` (**per version** / grid width, default 1), `SIZE_FETCH_PARALLEL`.

**Results:**

| Result | Type | Example | Purpose |
|---|---|---|---|
| `OCP_VERSIONS` | array | `["4.18","4.19"]` | matrix dimension 1 |
| `BUCKET_INDICES` | array | `["0","1"]` | matrix dimension 2 (grid width) |
| `BUCKETS_ARTIFACT` | string | OCI ref | bucket files + metadata |
| `TOTAL_IMAGES` | string | `"12"` | count of `(image,version)` pairs |

### 6.3 Task 2 — `fbc-fips-check-matrix-based-oci-ta` 0.2

- **New param `OCP_VERSION`** (plus existing `BUCKETS_ARTIFACT`, `BUCKET_INDEX`, `MAX_PARALLEL`).
- `prepare-bucket-images` step:
  - `bucket_file = bucket-${OCP_VERSION}-${BUCKET_INDEX}.txt`.
  - Write `${OCP_VERSION}` to `target_ocp_version.txt` (so the step action gets the right `-V`).
  - Copy metadata (`related-images-map.txt`, `images_processed.txt`, `test_output.txt`).
  - If the bucket is empty/missing → **no-op success** (nothing written → step action skips).
- `fips-operator-check-step-action` runs unchanged, using `-V=${OCP_VERSION}`.
- `output-results` propagates `test_output.txt` errors from prepare, else the scan result (unchanged from 0.1).

### 6.4 Matrix wiring (pipeline)

```yaml
- name: fbc-fips-prepare
  taskRef: { name: fbc-fips-prepare-oci-ta }   # 0.2
  params:
    - { name: SOURCE_ARTIFACT, value: $(tasks.clone-repository.results.SOURCE_ARTIFACT) }
    - { name: image-digest,    value: $(tasks.build-image-index.results.IMAGE_DIGEST) }
    - { name: image-url,       value: $(tasks.build-image-index.results.IMAGE_URL) }
    - { name: ociStorage,      value: $(params.output-image) }
    - { name: NUM_BUCKETS,     value: "2" }

- name: fbc-fips-check
  runAfter: [fbc-fips-prepare]
  matrix:
    params:
      - { name: OCP_VERSION,  value: $(tasks.fbc-fips-prepare.results.OCP_VERSIONS[*]) }
      - { name: BUCKET_INDEX, value: $(tasks.fbc-fips-prepare.results.BUCKET_INDICES[*]) }
  taskRef: { name: fbc-fips-check-matrix-based-oci-ta }   # 0.2
  params:
    - { name: BUCKETS_ARTIFACT, value: $(tasks.fbc-fips-prepare.results.BUCKETS_ARTIFACT) }
    - { name: MAX_PARALLEL,     value: "2" }
```

### 6.5 Error propagation & edge cases

- **Extraction failure** (render/label errors): prepare writes `test_output.txt` and emits a **minimal 1×1 grid** (`OCP_VERSIONS=["none"]`, `BUCKET_INDICES=["0"]`, empty `bucket-none-0.txt`). The single check branch propagates the error in `TEST_OUTPUT`.
- **Nothing to scan** (no related images for any version): same minimal grid; the single branch no-ops to success.
- **Empty padded cell**: bucket file exists but is empty → check branch no-ops to success.

### 6.6 Parallelism & resources

Two layers compound: **fan-out** (versions × width pods) × **in-pod** (`MAX_PARALLEL`). Because many pods run concurrently, `MAX_PARALLEL` defaults **lower** (2) than the standalone task (8) to avoid oversubscribing nodes.

### 6.7 Worked example (4 versions, `NUM_BUCKETS=2`)

```
extraction: 4.18:[A,B,C]  4.19:[A,B,C]  4.20:[A,B,C]  4.21:[C,D]
buckets:    4.18-0:[A,C] 4.18-1:[B]   ... 4.21-0:[C] 4.21-1:[D]
grid width = 2
OCP_VERSIONS = ["4.18","4.19","4.20","4.21"]   BUCKET_INDICES = ["0","1"]
matrix -> 4 × 2 = 8 pods, each -V = its version
```

Note A is scanned under 4.18, 4.19, 4.20 (three scan units) — required by C2.

## 7. Alternatives considered

| Design | Partition | Max branches | Why not chosen |
|---|---|---|---|
| **D0 Standalone** | in-pod loop | 1 | no horizontal scaling; fine only for small fragments |
| **D1 Version matrix** | per version | #versions | coarse — a big version is one slow branch |
| **D2 Composite matrix** | per (version,bucket) | #real buckets | exact fan-out but needs composite-key parsing; kept as fallback for very uneven counts |
| **D3 2-D matrix (chosen)** | per (version,bucket) | versions × width | clean native params + literal grid; cost = a few padded no-op branches |
| D4 Nested matrix | — | — | **impossible** in Tekton (C5) |
| D5 Flat union matrix | per image | #buckets | **incorrect** — breaks per-version `-V` (C2) |
| D6 Dynamic fan-out (custom task) | arbitrary | arbitrary | needs custom controller/RBAC; overkill for small N |

All viable designs share the same extraction; they differ only in partition/fan-out, so switching later is localized to the bucketing/results step and matrix wiring.

## 8. Correctness

The only subtle correctness property is **C2**: because `check-payload -V` applies a per-version exception set, an image must be scanned under every version that lists it. The design preserves this by keying buckets on `(version, bucket)` and never deduping an image across versions. D5 (union) is rejected precisely because it violates this.

## 9. Testing

- **ShellSpec (unit).**
  - prepare: `split-into-buckets` — per-version bucketing, grid padding, `(image,version)` totals, minimal-grid fallbacks. *(implemented, passing)*
  - check: `prepare-bucket-images` — version→`-V`, bucket selection, empty/missing-cell no-op.
- **Tekton integration.** A pipeline applying prepare + matrix check against a fixture fragment; assert fan-out shape and a success + an expected-failure case (`test/assert-task-failure`).
- `bash -n` + Checkton + yamllint via CI.

## 10. Rollout, migration & consistency

- New **version dirs** (`0.2`) for both tasks; 0.1 untouched (per repo multi-version rules).
- Both are **standalone OCI-TA** tasks (no `recipe.yaml`) — authored directly.
- CHANGELOG + README for each 0.2.
- Optional: `.tekton/*-v02-*` CI pipelines mirroring the v01 component pipelines.
- Keep container image digests and shared params aligned with the 0.1 family and the standalone 0.2 (variant-consistency rules).

## 11. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Padded empty branches waste TaskRuns | Small N; branches no-op fast. Fall back to D2 if it becomes material. |
| Node oversubscription (many pods × MAX_PARALLEL) | Lower default `MAX_PARALLEL` (2); tune per cluster. |
| Re-scanning shared images per version looks wasteful | Required by C2; document it. |
| Extraction is a single point of failure | Error propagated via `test_output.txt` + minimal grid so the pipeline reports cleanly. |

## 12. Open questions

1. Expected N (versions) and images-per-version? (D2 vs D3; `NUM_BUCKETS` default.)
2. `NUM_BUCKETS` = per-version grid width (current) or global budget?
3. Do failures need per-version attribution, or is per-image sufficient?
4. Fix standalone D0 independently, or steer users to the matrix variant?
