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

tekton_home=$(mktemp -d) && cleanup+=("${tekton_home}")
workspace_dir=$(mktemp -d) && cleanup+=("${workspace_dir}")

export FBC_TEST_BUNDLE_JSON="${tekton_home}/bundle_mock.json"
export FBC_TEST_OCP_VERSION_RAW='["v4.18"]'

mock_utils=$(mktemp --tmpdir mock_utils_XXXXXXXXXX.sh) && cleanup+=("${mock_utils}")
cat > "${mock_utils}" << 'MOCK_UTILS_EOF'
get_image_manifests() { echo '{"amd64": "sha256:abc123"}'; }
get_ocp_version_from_fbc_fragment() { echo "${FBC_TEST_OCP_VERSION_RAW}"; }
get_image_registry_and_repository() { echo "registry.redhat.io/redhat/redhat-operator-index"; }
render_opm() {
    local tmpfile; tmpfile=$(mktemp)
    echo '{"name":"test-operator","schema":"olm.package"}' > "$tmpfile"
    echo "$tmpfile"
}
extract_unique_package_names_from_catalog() { echo "test-operator"; }
get_unreleased_bundle() { echo "registry.redhat.io/test-operator/bundle:v1.0.0"; }
extract_related_images_from_bundle() { echo "registry.redhat.io/test-operator/operand:v1.0.0"; }
make_result_json() {
    local result=""
    while [ $# -gt 0 ]; do
        case "$1" in
            -r) result="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    echo "{\"result\":\"${result}\"}"
}
process_image_digest_mirror_set() { echo '{}'; }
MOCK_UTILS_EOF

fake_bin=$(mktemp -d) && cleanup+=("${fake_bin}")
cat > "${fake_bin}/opm" << 'OPM_MOCK'
#!/bin/bash
cat "${FBC_TEST_BUNDLE_JSON}"
OPM_MOCK
chmod +x "${fake_bin}/opm"
export PATH="${fake_bin}:${PATH}"

extract_script() {
  local script
  script="$(mktemp --tmpdir script_XXXXXXXXXX.sh)"
  yq -r ".spec.steps[] | select(.name == \"get-unique-related-images\").script" "${task_path}" > "${script}"

  sed -i "s|. /utils.sh|source ${mock_utils}|g" "${script}"
  sed -i 's|$(context.task.name)|fbc-fips-prepare-oci-ta|g' "${script}"
  sed -i "s|/tekton/home/|${tekton_home}/|g" "${script}"

  chmod +x "${script}"
  echo "${script}"
}

prepare_script="$(extract_script)"
cleanup+=("${prepare_script}")

write_bundle_json() {
    local subscription="$1"

    jq -n --arg sub "${subscription}" \
      '{properties: [{type: "olm.csv.metadata", value: {annotations: {"operators.openshift.io/valid-subscription": $sub, "createdAt": "2025-06-15T00:00:00Z"}}}]}' \
      > "${FBC_TEST_BUNDLE_JSON}"
}

setup_test() {
    rm -f "${tekton_home}"/*.txt "${tekton_home}"/*.json
    export FBC_TEST_OCP_VERSION_RAW='["v4.18"]'
    write_bundle_json '["OpenShift Kubernetes Engine"]'
}

Describe "binaryless OCP version resolution for fbc-fips-prepare-oci-ta 0.2"
    export IMAGE_URL=registry.io/test-operator/fbc-fragment:tag
    export IMAGE_DIGEST=sha256:abc123
    export SOURCE_CODE_DIR="${workspace_dir}"
    export IMAGE_MIRROR_SET_PATH=".tekton/images-mirror-set.yaml"

    BeforeEach setup_test

    It "fails clearly when the openshift.version label is absent (plain-string fallback)"
        export FBC_TEST_OCP_VERSION_RAW="v4.18"
        When call "${prepare_script}"
        The status should be success
        The output should include "was not found on the FBC fragment"
        The contents of file "${tekton_home}/test_output.txt" should include "FAILURE"
    End

    It "extracts relatedImages per OCP version when the label is a JSON array"
        When call "${prepare_script}"
        The status should be success
        The output should include "Target OCP versions: 4.18"
        The output should include "Related images per OCP version"
        The contents of file "${tekton_home}/related_images_by_version.json" should include "registry.redhat.io/test-operator/operand:v1.0.0"
    End

    It "fails when the lowest target OCP version is below v4.15"
        export FBC_TEST_OCP_VERSION_RAW='["v4.14"]'
        When call "${prepare_script}"
        The status should be success
        The output should include "must target OCP version >= v4.15"
        The contents of file "${tekton_home}/test_output.txt" should include "FAILURE"
    End
End
