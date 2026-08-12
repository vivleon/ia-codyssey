#!/usr/bin/env bash

# Demonstrate that an image tag is a mutable name while image IDs, digests,
# and containers already created from that name remain tied to their original
# image. Every mutable Docker resource is unique to this invocation.

set -Eeuo pipefail

readonly SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(CDPATH='' cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly LOG_FILE="${PROJECT_ROOT}/logs/image-tag-reference.txt"

readonly NGINX_IMAGE='nginx:alpine@sha256:4a73073bd557c65b759505da037898b61f1be6cbcc3c2c3aeac22d2a470c1752'
readonly NGINX_DIGEST='nginx@sha256:4a73073bd557c65b759505da037898b61f1be6cbcc3c2c3aeac22d2a470c1752'
readonly UBUNTU_IMAGE='ubuntu@sha256:3131b4cc82a783df6c9df078f86e01819a13594b865c2cad47bd1bca2b7063bb'
readonly UBUNTU_DIGEST='ubuntu@sha256:3131b4cc82a783df6c9df078f86e01819a13594b865c2cad47bd1bca2b7063bb'

readonly RUN_ID="$(date -u '+%Y%m%dt%H%M%Sz')-$$-${RANDOM}-${RANDOM}"
readonly ALIAS_IMAGE="ia-codyssey-image-tag-reference-${RUN_ID}:mutable"
readonly ORIGINAL_CONTAINER="ia-codyssey-tag-original-${RUN_ID}"
readonly RETAGGED_CONTAINER="ia-codyssey-tag-retagged-${RUN_ID}"
readonly RUN_LABEL_KEY='io.github.vivleon.ia-codyssey.image-tag-reference-run'
readonly ROLE_LABEL_KEY='io.github.vivleon.ia-codyssey.image-tag-reference-role'

NGINX_ID=''
UBUNTU_ID=''
INITIAL_ALIAS_ID=''
CURRENT_ALIAS_ID=''
ORIGINAL_CONTAINER_IMAGE_ID=''
RETAGGED_CONTAINER_IMAGE_ID=''
CAPTURED_OUTPUT=''
CAPTURED_STATUS=0

owns_alias=0
may_own_original_container=0
may_own_retagged_container=0
verification_complete=0

log() {
  printf '[image-tag-reference] %s\n' "$*"
}

fail() {
  log "ERROR: $*" >&2
  exit 1
}

print_command() {
  printf '$'
  printf ' %q' "$@"
  printf '\n'
}

run() {
  print_command "$@"
  "$@"
}

# Run a command once, show its exact combined output, and retain that output
# for assertions without hiding the evidence in command substitution.
capture() {
  local command_status
  local had_errexit=0

  case $- in
    *e*) had_errexit=1 ;;
  esac

  print_command "$@"
  set +e
  CAPTURED_OUTPUT="$("$@" 2>&1)"
  command_status=$?
  CAPTURED_STATUS=${command_status}
  if (( had_errexit )); then
    set -e
  else
    set +e
  fi
  if [[ -n "${CAPTURED_OUTPUT}" ]]; then
    printf '%s\n' "${CAPTURED_OUTPUT}"
  else
    printf '[no output]\n'
  fi
  return "${command_status}"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 \
    || fail "required command not found: $1"
}

assert_equal() {
  local actual=$1
  local expected=$2
  local description=$3

  [[ "${actual}" == "${expected}" ]] \
    || fail "assertion failed (${description}): expected '${expected}', got '${actual}'"
  log "PASS: ${description}: ${actual}"
}

assert_not_equal() {
  local left=$1
  local right=$2
  local description=$3

  [[ "${left}" != "${right}" ]] \
    || fail "assertion failed (${description}): both values are '${left}'"
  log "PASS: ${description}: ${left} != ${right}"
}

assert_contains() {
  local haystack=$1
  local needle=$2
  local description=$3

  [[ "${haystack}" == *"${needle}"* ]] \
    || fail "assertion failed (${description}): '${needle}' was not present"
  log "PASS: ${description}: found ${needle}"
}

assert_image_name_absent() {
  local image_name=$1

  print_command docker image inspect "${image_name}"
  if docker image inspect "${image_name}" >/dev/null 2>&1; then
    fail "refusing collision with existing image name: ${image_name}"
  fi
  log "PASS: image name is unused: ${image_name}"
}

assert_container_name_absent() {
  local container_name=$1

  print_command docker container inspect "${container_name}"
  if docker container inspect "${container_name}" >/dev/null 2>&1; then
    fail "refusing collision with existing container name: ${container_name}"
  fi
  log "PASS: container name is unused: ${container_name}"
}

container_run_label() {
  docker container inspect \
    --format "{{index .Config.Labels \"${RUN_LABEL_KEY}\"}}" "$1" 2>/dev/null
}

cleanup_owned_container() {
  local container_name=$1
  local may_own=$2
  local actual_label

  (( may_own )) || return 0

  if ! docker container inspect "${container_name}" >/dev/null 2>&1; then
    log "cleanup: container already absent: ${container_name}"
    return 0
  fi

  if ! actual_label="$(container_run_label "${container_name}")"; then
    log "cleanup ERROR: could not inspect ownership label: ${container_name}"
    return 1
  fi
  if [[ "${actual_label}" != "${RUN_ID}" ]]; then
    log "cleanup REFUSED: ownership mismatch for ${container_name}; left untouched"
    return 1
  fi

  run docker container rm --force "${container_name}"
}

cleanup_owned_alias() {
  local alias_id

  (( owns_alias )) || return 0

  if ! docker image inspect "${ALIAS_IMAGE}" >/dev/null 2>&1; then
    log "cleanup: image alias already absent: ${ALIAS_IMAGE}"
    return 0
  fi

  if ! capture docker image inspect --format '{{.Id}}' "${ALIAS_IMAGE}"; then
    log "cleanup ERROR: could not inspect alias ownership target"
    return 1
  fi
  alias_id=${CAPTURED_OUTPUT}

  # Image aliases do not carry labels. We only remove the unique name if it
  # still points to one of the two immutable images selected by this run.
  if [[ "${alias_id}" != "${NGINX_ID}" && "${alias_id}" != "${UBUNTU_ID}" ]]; then
    log 'cleanup REFUSED: the unique alias was unexpectedly retargeted; left untouched'
    return 1
  fi

  if ! capture docker image rm "${ALIAS_IMAGE}"; then
    log "cleanup ERROR: failed to remove unique alias: ${ALIAS_IMAGE}"
    return 1
  fi
  if [[ "${CAPTURED_OUTPUT}" == *'Deleted:'* ]]; then
    log 'cleanup ERROR: Docker reported image deletion instead of alias-only removal'
    return 1
  fi
  if docker image inspect "${ALIAS_IMAGE}" >/dev/null 2>&1; then
    log "cleanup ERROR: image alias still exists: ${ALIAS_IMAGE}"
    return 1
  fi

  owns_alias=0
  log "cleanup confirmed unique alias absent: ${ALIAS_IMAGE}"
}

verify_pinned_image_unchanged() {
  local image_ref=$1
  local expected_id=$2
  local description=$3
  local actual_id

  if ! capture docker image inspect --format '{{.Id}}' "${image_ref}"; then
    log "cleanup ERROR: pinned ${description} image is missing: ${image_ref}"
    return 1
  fi
  actual_id=${CAPTURED_OUTPUT}
  if [[ "${actual_id}" != "${expected_id}" ]]; then
    log "cleanup ERROR: pinned ${description} ID changed: ${actual_id}"
    return 1
  fi
  log "cleanup confirmed pinned ${description} image unchanged: ${actual_id}"
}

cleanup() {
  local original_status=$?
  local cleanup_status=0
  local final_status
  local leftover_ids

  trap - EXIT INT TERM
  set +e

  printf '\n=== Cleanup and leftover audit ===\n'
  log "cleanup starting for run ${RUN_ID}"

  # Remove only the tag name while both created containers still protect their
  # underlying image IDs. Never invoke image removal using a base tag, digest,
  # or image ID.
  cleanup_owned_alias || cleanup_status=1
  cleanup_owned_container "${RETAGGED_CONTAINER}" "${may_own_retagged_container}" \
    || cleanup_status=1
  cleanup_owned_container "${ORIGINAL_CONTAINER}" "${may_own_original_container}" \
    || cleanup_status=1

  for container_name in "${ORIGINAL_CONTAINER}" "${RETAGGED_CONTAINER}"; do
    if docker container inspect "${container_name}" >/dev/null 2>&1; then
      log "cleanup ERROR: container still exists: ${container_name}"
      cleanup_status=1
    else
      log "cleanup confirmed container absent: ${container_name}"
    fi
  done

  if docker image inspect "${ALIAS_IMAGE}" >/dev/null 2>&1; then
    log "cleanup ERROR: unique alias still exists: ${ALIAS_IMAGE}"
    cleanup_status=1
  else
    log "cleanup confirmed image alias absent: ${ALIAS_IMAGE}"
  fi

  if capture docker container ls --all --quiet \
    --filter "label=${RUN_LABEL_KEY}=${RUN_ID}"; then
    leftover_ids=${CAPTURED_OUTPUT}
    if [[ -n "${leftover_ids}" ]]; then
      log "cleanup ERROR: labeled containers remain: ${leftover_ids}"
      cleanup_status=1
    else
      log 'cleanup confirmed no run-labeled containers remain'
    fi
  else
    log 'cleanup ERROR: labeled-container audit command failed'
    cleanup_status=1
  fi

  if [[ -n "${NGINX_ID}" ]]; then
    verify_pinned_image_unchanged "${NGINX_IMAGE}" "${NGINX_ID}" nginx \
      || cleanup_status=1
  fi
  if [[ -n "${UBUNTU_ID}" ]]; then
    verify_pinned_image_unchanged "${UBUNTU_IMAGE}" "${UBUNTU_ID}" ubuntu \
      || cleanup_status=1
  fi

  final_status=${original_status}
  if (( verification_complete == 0 )); then
    log 'cleanup ERROR: verification did not reach all assertions'
    final_status=1
  fi
  if (( cleanup_status != 0 )); then
    final_status=1
  fi

  log "main status=${original_status} cleanup status=${cleanup_status} final exit=${final_status}"
  if (( final_status == 0 )); then
    log 'PASS: all tag-mutation assertions and cleanup checks succeeded'
  fi
  exit "${final_status}"
}

for command_name in docker date id sed tee; do
  require_command "${command_name}"
done
[[ -d "${PROJECT_ROOT}/logs" ]] || fail "logs directory not found: ${PROJECT_ROOT}/logs"

# Mask the host login name anywhere it appears in command output before the
# transcript is persisted. POSIX login names do not contain the chosen '|'
# delimiter; BRE metacharacters allowed by common systems are escaped.
HOST_USER="$(id -un)"
MASKED_HOST_USER="$(printf '%s' "${HOST_USER}" | sed 's/[][\\.^$*]/\\&/g')"
if [[ -n "${MASKED_HOST_USER}" ]]; then
  exec > >(sed "s|${MASKED_HOST_USER}|[USER]|g" | tee "${LOG_FILE}") 2>&1
else
  exec > >(tee "${LOG_FILE}") 2>&1
fi

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

printf '=== Docker image tag reference verification ===\n'
log "UTC start: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
log "run id: ${RUN_ID}"
log "unique mutable alias: ${ALIAS_IMAGE}"
log "original container: ${ORIGINAL_CONTAINER}"
log "retagged container: ${RETAGGED_CONTAINER}"
log "pinned nginx input: ${NGINX_IMAGE}"
log "pinned ubuntu input: ${UBUNTU_IMAGE}"

printf '\n=== Docker engine and immutable inputs ===\n'
capture docker version --format 'Client={{.Client.Version}} Server={{.Server.Version}}' \
  || fail 'Docker engine is unavailable'

for base_image in "${NGINX_IMAGE}" "${UBUNTU_IMAGE}"; do
  if docker image inspect "${base_image}" >/dev/null 2>&1; then
    log "base image already local: ${base_image}"
  else
    log "base image is not local; pulling immutable reference: ${base_image}"
    run docker image pull "${base_image}"
  fi
done

capture docker image inspect --format '{{.Id}}' "${NGINX_IMAGE}" \
  || fail 'could not inspect pinned nginx image'
NGINX_ID=${CAPTURED_OUTPUT}
capture docker image inspect --format 'ID={{.Id}} RepoDigests={{json .RepoDigests}}' \
  "${NGINX_IMAGE}" || fail 'could not record pinned nginx digest metadata'
assert_contains "${CAPTURED_OUTPUT}" "${NGINX_DIGEST}" \
  'nginx metadata contains the pinned digest'

capture docker image inspect --format '{{.Id}}' "${UBUNTU_IMAGE}" \
  || fail 'could not inspect pinned Ubuntu image'
UBUNTU_ID=${CAPTURED_OUTPUT}
capture docker image inspect --format 'ID={{.Id}} RepoDigests={{json .RepoDigests}}' \
  "${UBUNTU_IMAGE}" || fail 'could not record pinned Ubuntu digest metadata'
assert_contains "${CAPTURED_OUTPUT}" "${UBUNTU_DIGEST}" \
  'Ubuntu metadata contains the pinned digest'
assert_not_equal "${NGINX_ID}" "${UBUNTU_ID}" 'the two immutable input IDs differ'

printf '\n=== Collision refusal for run-owned names ===\n'
assert_image_name_absent "${ALIAS_IMAGE}"
assert_container_name_absent "${ORIGINAL_CONTAINER}"
assert_container_name_absent "${RETAGGED_CONTAINER}"

printf '\n=== Point the unique alias at pinned nginx ===\n'
run docker image tag "${NGINX_IMAGE}" "${ALIAS_IMAGE}"
owns_alias=1
capture docker image inspect --format '{{.Id}}' "${ALIAS_IMAGE}" \
  || fail 'could not inspect initial alias target'
INITIAL_ALIAS_ID=${CAPTURED_OUTPUT}
CURRENT_ALIAS_ID=${INITIAL_ALIAS_ID}
assert_equal "${INITIAL_ALIAS_ID}" "${NGINX_ID}" \
  'initial alias resolves to the pinned nginx image ID'

printf '\n=== Create a container while the alias means nginx ===\n'
may_own_original_container=1
run docker container create \
  --name "${ORIGINAL_CONTAINER}" \
  --label "${RUN_LABEL_KEY}=${RUN_ID}" \
  --label "${ROLE_LABEL_KEY}=original-nginx" \
  "${ALIAS_IMAGE}"
capture docker container inspect \
  --format "Name={{.Name}} ConfiguredImage={{.Config.Image}} ImageID={{.Image}} RunLabel={{index .Config.Labels \"${RUN_LABEL_KEY}\"}} Role={{index .Config.Labels \"${ROLE_LABEL_KEY}\"}}" \
  "${ORIGINAL_CONTAINER}" || fail 'could not inspect original container'
assert_contains "${CAPTURED_OUTPUT}" "ConfiguredImage=${ALIAS_IMAGE}" \
  'original container records the alias used at creation'
assert_contains "${CAPTURED_OUTPUT}" "RunLabel=${RUN_ID}" \
  'original container carries this run ownership label'

capture docker container inspect --format '{{.Image}}' "${ORIGINAL_CONTAINER}" \
  || fail 'could not record original container image ID'
ORIGINAL_CONTAINER_IMAGE_ID=${CAPTURED_OUTPUT}
assert_equal "${ORIGINAL_CONTAINER_IMAGE_ID}" "${NGINX_ID}" \
  'original container records the nginx image ID'

printf '\n=== Repoint the same alias at pinned Ubuntu ===\n'
run docker image tag "${UBUNTU_IMAGE}" "${ALIAS_IMAGE}"
capture docker image inspect --format '{{.Id}}' "${ALIAS_IMAGE}" \
  || fail 'could not inspect repointed alias target'
CURRENT_ALIAS_ID=${CAPTURED_OUTPUT}
assert_equal "${CURRENT_ALIAS_ID}" "${UBUNTU_ID}" \
  'repointed alias resolves to the pinned Ubuntu image ID'
assert_not_equal "${CURRENT_ALIAS_ID}" "${INITIAL_ALIAS_ID}" \
  'the same tag name now resolves to a different image ID'

printf '\n=== Prove the existing container did not follow the mutable alias ===\n'
capture docker container inspect \
  --format 'ConfiguredImage={{.Config.Image}} StableImageID={{.Image}}' \
  "${ORIGINAL_CONTAINER}" || fail 'could not reinspect original container'
assert_contains "${CAPTURED_OUTPUT}" "StableImageID=${NGINX_ID}" \
  'existing container still records the original nginx image ID'

capture docker container inspect --format '{{.Image}}' "${ORIGINAL_CONTAINER}" \
  || fail 'could not verify original container image ID after retagging'
assert_equal "${CAPTURED_OUTPUT}" "${ORIGINAL_CONTAINER_IMAGE_ID}" \
  'original container image ID is unchanged after retagging'
assert_not_equal "${CAPTURED_OUTPUT}" "${CURRENT_ALIAS_ID}" \
  'original container image ID differs from the alias current target'

capture docker image inspect \
  --format 'OriginalImageID={{.Id}} RepoDigests={{json .RepoDigests}}' \
  "${ORIGINAL_CONTAINER_IMAGE_ID}" \
  || fail 'could not inspect original container image metadata by stable ID'
assert_contains "${CAPTURED_OUTPUT}" "${NGINX_DIGEST}" \
  'original container image ID still maps to the pinned nginx digest'

printf '\n=== Create a second container from the retagged alias ===\n'
may_own_retagged_container=1
run docker container create \
  --name "${RETAGGED_CONTAINER}" \
  --label "${RUN_LABEL_KEY}=${RUN_ID}" \
  --label "${ROLE_LABEL_KEY}=retagged-ubuntu" \
  "${ALIAS_IMAGE}"
capture docker container inspect \
  --format "Name={{.Name}} ConfiguredImage={{.Config.Image}} ImageID={{.Image}} RunLabel={{index .Config.Labels \"${RUN_LABEL_KEY}\"}} Role={{index .Config.Labels \"${ROLE_LABEL_KEY}\"}}" \
  "${RETAGGED_CONTAINER}" || fail 'could not inspect retagged container'
assert_contains "${CAPTURED_OUTPUT}" "RunLabel=${RUN_ID}" \
  'retagged container carries this run ownership label'

capture docker container inspect --format '{{.Image}}' "${RETAGGED_CONTAINER}" \
  || fail 'could not record retagged container image ID'
RETAGGED_CONTAINER_IMAGE_ID=${CAPTURED_OUTPUT}
assert_equal "${RETAGGED_CONTAINER_IMAGE_ID}" "${UBUNTU_ID}" \
  'new container records the Ubuntu image ID behind the retagged alias'
assert_not_equal "${RETAGGED_CONTAINER_IMAGE_ID}" "${ORIGINAL_CONTAINER_IMAGE_ID}" \
  'containers created before and after retagging record different image IDs'

printf '\n=== Demonstration result ===\n'
log "same mutable name: ${ALIAS_IMAGE}"
log "alias before retag: ${INITIAL_ALIAS_ID}"
log "alias after retag:  ${CURRENT_ALIAS_ID}"
log "original container remains: ${ORIGINAL_CONTAINER_IMAGE_ID} (${NGINX_DIGEST})"
log "retagged container records: ${RETAGGED_CONTAINER_IMAGE_ID} (${UBUNTU_DIGEST})"
log 'PASS: a tag changed targets; the immutable digest/ID and existing container did not'

verification_complete=1
exit 0
