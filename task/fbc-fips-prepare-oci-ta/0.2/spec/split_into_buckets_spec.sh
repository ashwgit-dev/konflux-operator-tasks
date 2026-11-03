#!/bin/env bash

set -o errexit
set -o pipefail
set -o nounset

eval "$(shellspec - -c) exit 1"

task_path=fbc-fips-prepare-oci-ta.yaml
if [[ -f "../${task_path}" ]]; then
    task_path="../${task_path}"
fi

cleanup=()
trap 'rm -rf "${cleanup[@]}"' EXIT

# Mock /utils.sh helpers used by the parallel size-fetch helper (fetch_size).
mock_utils=$(mktemp --tmpdir mock_utils_XXXXXXXXXX.sh) && cleanup+=("${mock_utils}")
cat > "${mock_utils}" << 'MOCK_UTILS_EOF'
get_image_registry_and_repository() { echo "registry.example.io/repo"; }
get_image_mirror_list() { echo ""; }
replace_image_pullspec() { echo "$1"; }
MOCK_UTILS_EOF

# Mock skopeo so size fetching returns a deterministic non-zero size for every image.
fake_bin=$(mktemp -d) && cleanup+=("${fake_bin}")
cat > "${fake_bin}/skopeo" << 'SKOPEO_MOCK'
#!/bin/bash
echo '{"LayersData":[{"Size":1048576}]}'
SKOPEO_MOCK
chmod +x "${fake_bin}/skopeo"
export PATH="${fake_bin}:${PATH}"

# Extract the split-into-buckets step script and rewrite Tekton-specific paths/vars so it
# can run locally against temp directories.
extract_script() {
  local script tekton_home results_dir buckets_dir
  tekton_home="$1"
  results_dir="$2"
  buckets_dir="$3"

  script="$(mktemp --tmpdir script_XXXXXXXXXX.sh)"
  yq -r ".spec.steps[] | select(.name == \"split-into-buckets\").script" "${task_path}" > "${script}"

  sed -i "s|. /utils.sh|source ${mock_utils}|g" "${script}"
  sed -i 's|$(results.OCP_VERSIONS.path)|'"${results_dir}"'/OCP_VERSIONS|g' "${script}"
  sed -i 's|$(results.BUCKET_INDICES.path)|'"${results_dir}"'/BUCKET_INDICES|g' "${script}"
  sed -i 's|$(results.TOTAL_IMAGES.path)|'"${results_dir}"'/TOTAL_IMAGES|g' "${script}"
  sed -i "s|/var/workdir/buckets|${buckets_dir}|g" "${script}"
  sed -i "s|/tekton/home/|${tekton_home}/|g" "${script}"

  chmod +x "${script}"
  echo "${script}"
}

Describe 'split-into-buckets (0.2 binaryless)'
  setup() {
    tekton_home=$(mktemp -d) && cleanup+=("${tekton_home}")
    results_dir=$(mktemp -d) && cleanup+=("${results_dir}")
    buckets_dir=$(mktemp -d) && cleanup+=("${buckets_dir}")
    export NUM_BUCKETS=2
    export SIZE_FETCH_PARALLEL=2
  }
  BeforeEach 'setup'

  run_split() {
    local script
    script="$(extract_script "${tekton_home}" "${results_dir}" "${buckets_dir}")"
    cleanup+=("${script}")
    bash "${script}"
  }

  It 'creates per-version buckets, pads the grid, and emits matrix results'
    cat > "${tekton_home}/related_images_by_version.json" << 'JSON'
{
  "4.18": ["imgA", "imgB", "imgC"],
  "4.19": ["imgD"]
}
JSON

    When call run_split
    The status should be success
    The output should include "Done!"

    # TOTAL_IMAGES counts (image, version) pairs: 3 + 1 = 4
    The contents of file "${results_dir}/TOTAL_IMAGES" should equal "4"

    # Grid width is the widest version. 4.18 has 3 images, capped to NUM_BUCKETS=2 -> width 2.
    The contents of file "${results_dir}/BUCKET_INDICES" should equal '["0","1"]'
    The contents of file "${results_dir}/OCP_VERSIONS" should equal '["4.18","4.19"]'

    # 4.18 fills both of its buckets.
    The path "${buckets_dir}/bucket-4.18-0.txt" should be exist
    The path "${buckets_dir}/bucket-4.18-1.txt" should be exist

    # 4.19 has one image -> one real bucket, plus a padded empty bucket for grid cell 1.
    The path "${buckets_dir}/bucket-4.19-0.txt" should be exist
    The path "${buckets_dir}/bucket-4.19-1.txt" should be exist
    The contents of file "${buckets_dir}/bucket-4.19-1.txt" should equal ""

    # Every original image lands in exactly one bucket for its version.
    all_418="$(cat "${buckets_dir}"/bucket-4.18-*.txt | sort | tr '\n' ' ')"
    The variable all_418 should equal "imgA imgB imgC "
  End

  It 'emits a minimal grid when there are no related images for any version'
    echo '{"4.18": [], "4.19": []}' > "${tekton_home}/related_images_by_version.json"

    When call run_split
    The status should be success
    The output should include "Nothing to scan"
    The contents of file "${results_dir}/TOTAL_IMAGES" should equal "0"
    The contents of file "${results_dir}/OCP_VERSIONS" should equal '["none"]'
    The contents of file "${results_dir}/BUCKET_INDICES" should equal '["0"]'
    The path "${buckets_dir}/bucket-none-0.txt" should be exist
  End

  It 'emits a minimal grid when the extraction output is missing'
    When call run_split
    The status should be success
    The output should include "No related_images_by_version.json found"
    The contents of file "${results_dir}/TOTAL_IMAGES" should equal "0"
    The contents of file "${results_dir}/OCP_VERSIONS" should equal '["none"]'
    The contents of file "${results_dir}/BUCKET_INDICES" should equal '["0"]'
    The path "${buckets_dir}/bucket-none-0.txt" should be exist
  End
End
