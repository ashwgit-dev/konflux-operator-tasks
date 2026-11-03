#!/bin/env bash

set -o errexit
set -o pipefail
set -o nounset

eval "$(shellspec - -c) exit 1"

task_path=fbc-fips-check-matrix-based-oci-ta.yaml
if [[ -f "../${task_path}" ]]; then
    task_path="../${task_path}"
fi

cleanup=()
trap 'rm -rf "${cleanup[@]}"' EXIT

extract_step_script() {
  local step_name="$1"
  local script
  script="$(mktemp --tmpdir script_XXXXXXXXXX.sh)"
  yq -r ".spec.steps[] | select(.name == \"${step_name}\").script" "${task_path}" > "${script}"
  echo "${script}"
}

Describe 'prepare-bucket-images (0.2 binaryless)'
  setup() {
    tekton_home=$(mktemp -d) && cleanup+=("${tekton_home}")
    buckets_dir=$(mktemp -d) && cleanup+=("${buckets_dir}")

    script="$(extract_step_script prepare-bucket-images)"
    cleanup+=("${script}")
    sed -i "s|/var/workdir/buckets|${buckets_dir}|g" "${script}"
    sed -i "s|/tekton/home|${tekton_home}|g" "${script}"
    chmod +x "${script}"
  }
  BeforeEach 'setup'

  run_prepare() {
    bash "${script}"
  }

  It 'selects the bucket for the given OCP version and index, and writes target_ocp_version.txt'
    printf 'imgA\nimgB\n' > "${buckets_dir}/bucket-4.18-1.txt"
    export OCP_VERSION=4.18
    export BUCKET_INDEX=1

    When call run_prepare
    The status should be success
    The output should include "Ready to process 2 images"
    The contents of file "${tekton_home}/target_ocp_version.txt" should equal "4.18"
    The contents of file "${tekton_home}/unique_related_images.txt" should equal "imgA imgB "
  End

  It 'does not pick a different version or index sharing the same bucket directory'
    printf 'imgA\n' > "${buckets_dir}/bucket-4.18-0.txt"
    printf 'imgB\nimgC\n' > "${buckets_dir}/bucket-4.19-0.txt"
    export OCP_VERSION=4.19
    export BUCKET_INDEX=0

    When call run_prepare
    The status should be success
    The output should include "Ready to process 2 images"
    The contents of file "${tekton_home}/target_ocp_version.txt" should equal "4.19"
    The contents of file "${tekton_home}/unique_related_images.txt" should equal "imgB imgC "
  End

  It 'no-ops without writing unique_related_images.txt when the bucket is empty'
    : > "${buckets_dir}/bucket-4.19-1.txt"
    export OCP_VERSION=4.19
    export BUCKET_INDEX=1

    When call run_prepare
    The status should be success
    The output should include "No images in this bucket"
    The contents of file "${tekton_home}/target_ocp_version.txt" should equal "4.19"
    The path "${tekton_home}/unique_related_images.txt" should not be exist
  End

  It 'copies metadata files (including test_output.txt) alongside the OCP version'
    : > "${buckets_dir}/bucket-none-0.txt"
    echo '{"result":"ERROR","note":"boom"}' > "${buckets_dir}/test_output.txt"
    export OCP_VERSION=none
    export BUCKET_INDEX=0

    When call run_prepare
    The status should be success
    The output should include "No images in this bucket"
    The contents of file "${tekton_home}/test_output.txt" should equal '{"result":"ERROR","note":"boom"}'
    The contents of file "${tekton_home}/target_ocp_version.txt" should equal "none"
  End

  It 'fails when the (version, index) bucket file does not exist'
    export OCP_VERSION=4.20
    export BUCKET_INDEX=5

    When call run_prepare
    The status should be failure
    The output should include "ERROR: Bucket file not found"
  End
End

Describe 'output-results (0.2 binaryless)'
  setup() {
    tekton_home=$(mktemp -d) && cleanup+=("${tekton_home}")
    results_dir=$(mktemp -d) && cleanup+=("${results_dir}")

    script="$(extract_step_script output-results)"
    cleanup+=("${script}")
    sed -i 's|$(results.IMAGES_PROCESSED.path)|'"${results_dir}"'/IMAGES_PROCESSED|g' "${script}"
    sed -i 's|$(results.TEST_OUTPUT.path)|'"${results_dir}"'/TEST_OUTPUT|g' "${script}"
    sed -i "s|/tekton/home|${tekton_home}|g" "${script}"
    chmod +x "${script}"
  }
  BeforeEach 'setup'

  run_output() {
    bash "${script}"
  }

  It 'propagates an ERROR recorded by the prepare task, ignoring the step action output'
    echo '{"result":"ERROR","note":"could not render fragment"}' > "${tekton_home}/test_output.txt"
    export OCP_VERSION=none
    export BUCKET_INDEX=0
    export STEP_ACTION_OUTPUT=""

    When call run_output
    The status should be success
    The output should include "Propagating ERROR from prepare task"
    The contents of file "${results_dir}/TEST_OUTPUT" should equal '{"result":"ERROR","note":"could not render fragment"}'
  End

  It 'uses the step action output when the prepare task succeeded'
    export OCP_VERSION=4.18
    export BUCKET_INDEX=0
    export STEP_ACTION_OUTPUT='{"result":"SUCCESS"}'

    When call run_output
    The status should be success
    The output should include "FIPS check complete"
    The contents of file "${results_dir}/TEST_OUTPUT" should equal '{"result":"SUCCESS"}'
  End

  It 'skips without writing TEST_OUTPUT when there was nothing to check'
    export OCP_VERSION=4.19
    export BUCKET_INDEX=1
    export STEP_ACTION_OUTPUT=""

    When call run_output
    The status should be success
    The output should include "No images to check in this bucket, skipping"
    The path "${results_dir}/TEST_OUTPUT" should not be exist
  End

  It 'writes IMAGES_PROCESSED when the prepare task recorded one'
    echo '{"image": {"pullspec": "registry.io/frag:tag", "digests": ["sha256:abc"]}}' > "${tekton_home}/images_processed.txt"
    export OCP_VERSION=4.18
    export BUCKET_INDEX=0
    export STEP_ACTION_OUTPUT='{"result":"SUCCESS"}'

    When call run_output
    The status should be success
    The output should include "FIPS check complete"
    The contents of file "${results_dir}/IMAGES_PROCESSED" should equal '{"image": {"pullspec": "registry.io/frag:tag", "digests": ["sha256:abc"]}}'
  End
End
