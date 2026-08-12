#!/usr/bin/env bash

# Demonstrate that `docker volume create NAME` reuses an existing named volume.
# Every Docker resource has a unique run-scoped name and ownership label.  The
# EXIT trap removes only resources whose label matches this run.

set -Eeuo pipefail

readonly SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(CDPATH='' cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly LOG_FILE="${PROJECT_ROOT}/logs/volume-name-reuse.txt"
readonly IMAGE="ubuntu@sha256:3131b4cc82a783df6c9df078f86e01819a13594b865c2cad47bd1bca2b7063bb"
readonly RESOURCE_LABEL="io.github.vivleon.ia-codyssey.volume-name-reuse-run"

readonly RUN_ID="$(date -u '+%Y%m%dT%H%M%SZ')-$$-${RANDOM}-${RANDOM}"
readonly REUSED_VOLUME="ia-codyssey-name-reuse-stale-${RUN_ID}"
readonly FRESH_VOLUME="ia-codyssey-name-reuse-fresh-${RUN_ID}"
readonly WRITER_CONTAINER="ia-codyssey-name-reuse-writer-${RUN_ID}"
readonly REUSE_READER_CONTAINER="ia-codyssey-name-reuse-reader-${RUN_ID}"
readonly FRESH_READER_CONTAINER="ia-codyssey-name-reuse-empty-reader-${RUN_ID}"
readonly SENTINEL="stale-volume-sentinel-${RUN_ID}"

# A candidate flag is set immediately before a create command.  Cleanup still
# requires the exact ownership label, so a resource that raced into existence
# under the same name but without our label is never removed.
cleanup_candidate_reused_volume=0
cleanup_candidate_fresh_volume=0
cleanup_candidate_writer=0
cleanup_candidate_reuse_reader=0
cleanup_candidate_fresh_reader=0

CAPTURED_OUTPUT=''
CAPTURED_STATUS=0

log() {
  printf '[volume-name-reuse] %s\n' "$*"
}

fail() {
  printf '[volume-name-reuse] ERROR: %s\n' "$*" >&2
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

# Run a command once, preserving and displaying its combined output and exit
# status.  The function itself succeeds so callers can make explicit assertions.
capture_command() {
  print_command "$@"
  if CAPTURED_OUTPUT="$("$@" 2>&1)"; then
    CAPTURED_STATUS=0
  else
    CAPTURED_STATUS=$?
  fi
  if [[ -n "${CAPTURED_OUTPUT}" ]]; then
    printf '%s\n' "${CAPTURED_OUTPUT}"
  fi
  printf '[command-exit] %d\n' "${CAPTURED_STATUS}"
  return 0
}

require_command() {
  command -v "$1" >/dev/null 2>&1 \
    || fail "required command not found: $1"
}

assert_command_succeeded() {
  local description=$1

  (( CAPTURED_STATUS == 0 )) \
    || fail "${description} (command exit=${CAPTURED_STATUS})"
  log "assertion PASS: ${description}"
}

assert_equals() {
  local actual=$1
  local expected=$2
  local description=$3
  local actual_quoted
  local expected_quoted

  if [[ "${actual}" != "${expected}" ]]; then
    printf -v actual_quoted '%q' "${actual}"
    printf -v expected_quoted '%q' "${expected}"
    fail "${description}; expected=${expected_quoted} actual=${actual_quoted}"
  fi
  log "assertion PASS: ${description}"
}

assert_not_equals() {
  local left=$1
  local right=$2
  local description=$3
  local value_quoted

  if [[ "${left}" == "${right}" ]]; then
    printf -v value_quoted '%q' "${left}"
    fail "${description}; both values were ${value_quoted}"
  fi
  log "assertion PASS: ${description}"
}

assert_nonempty() {
  local value=$1
  local description=$2

  [[ -n "${value}" ]] || fail "${description}; value was empty"
  log "assertion PASS: ${description}"
}

assert_resource_absent() {
  local resource_type=$1
  local resource_name=$2

  case "${resource_type}" in
    container)
      capture_command docker container ls --all \
        --filter "name=^/${resource_name}$" --format '{{.Names}}'
      ;;
    volume)
      capture_command docker volume ls \
        --filter "name=^${resource_name}$" --format '{{.Name}}'
      ;;
    *)
      fail "unsupported resource type for absence check: ${resource_type}"
      ;;
  esac

  assert_command_succeeded \
    "Docker accepted the pre-existing ${resource_type} name check for ${resource_name}"
  [[ -z "${CAPTURED_OUTPUT}" ]] \
    || fail "refusing to touch pre-existing Docker ${resource_type}: ${resource_name}"
  log "assertion PASS: name was unused before creation: ${resource_type} ${resource_name}"
}

verify_volume_owner() {
  local volume_name=$1

  capture_command docker volume inspect --format \
    "{{ index .Labels \"${RESOURCE_LABEL}\" }}" "${volume_name}"
  assert_command_succeeded "owned volume exists: ${volume_name}"
  assert_equals "${CAPTURED_OUTPUT}" "${RUN_ID}" \
    "volume ownership label matches this run: ${volume_name}"
}

verify_container_owner() {
  local container_name=$1

  capture_command docker container inspect --format \
    "{{ index .Config.Labels \"${RESOURCE_LABEL}\" }}" "${container_name}"
  assert_command_succeeded "owned container exists: ${container_name}"
  assert_equals "${CAPTURED_OUTPUT}" "${RUN_ID}" \
    "container ownership label matches this run: ${container_name}"
}

verify_container_exit_zero() {
  local container_name=$1

  capture_command docker container inspect --format '{{.State.ExitCode}}' \
    "${container_name}"
  assert_command_succeeded "container exit code was inspectable: ${container_name}"
  assert_equals "${CAPTURED_OUTPUT}" '0' \
    "container completed successfully: ${container_name}"
}

cleanup_owned_container() {
  local container_name=$1
  local is_candidate=$2
  local actual_label

  (( is_candidate )) || return 0

  capture_command docker container inspect --format \
    "{{ index .Config.Labels \"${RESOURCE_LABEL}\" }}" "${container_name}"
  if (( CAPTURED_STATUS != 0 )); then
    log "cleanup: container already absent: ${container_name}"
    return 0
  fi

  actual_label=${CAPTURED_OUTPUT}
  if [[ "${actual_label}" != "${RUN_ID}" ]]; then
    log "cleanup ERROR: ownership mismatch; left container untouched: ${container_name}"
    return 1
  fi

  print_command docker container rm --force "${container_name}"
  docker container rm --force "${container_name}"
}

cleanup_owned_volume() {
  local volume_name=$1
  local is_candidate=$2
  local actual_label

  (( is_candidate )) || return 0

  capture_command docker volume inspect --format \
    "{{ index .Labels \"${RESOURCE_LABEL}\" }}" "${volume_name}"
  if (( CAPTURED_STATUS != 0 )); then
    log "cleanup: volume already absent: ${volume_name}"
    return 0
  fi

  actual_label=${CAPTURED_OUTPUT}
  if [[ "${actual_label}" != "${RUN_ID}" ]]; then
    log "cleanup ERROR: ownership mismatch; left volume untouched: ${volume_name}"
    return 1
  fi

  print_command docker volume rm "${volume_name}"
  docker volume rm "${volume_name}"
}

confirm_container_absent_after_cleanup() {
  local container_name=$1

  capture_command docker container inspect --format '{{.Name}}' "${container_name}"
  if (( CAPTURED_STATUS == 0 )); then
    log "cleanup ERROR: container still exists: ${container_name}"
    return 1
  fi
  log "cleanup confirmed container absent: ${container_name}"
}

confirm_volume_absent_after_cleanup() {
  local volume_name=$1

  capture_command docker volume inspect --format '{{.Name}}' "${volume_name}"
  if (( CAPTURED_STATUS == 0 )); then
    log "cleanup ERROR: volume still exists: ${volume_name}"
    return 1
  fi
  log "cleanup confirmed volume absent: ${volume_name}"
}

cleanup() {
  local main_status=$?
  local cleanup_status=0
  local final_status

  trap - EXIT INT TERM
  set +e

  log "cleanup starting for run ${RUN_ID}"

  cleanup_owned_container "${FRESH_READER_CONTAINER}" \
    "${cleanup_candidate_fresh_reader}" || cleanup_status=1
  cleanup_owned_container "${REUSE_READER_CONTAINER}" \
    "${cleanup_candidate_reuse_reader}" || cleanup_status=1
  cleanup_owned_container "${WRITER_CONTAINER}" \
    "${cleanup_candidate_writer}" || cleanup_status=1

  cleanup_owned_volume "${FRESH_VOLUME}" \
    "${cleanup_candidate_fresh_volume}" || cleanup_status=1
  cleanup_owned_volume "${REUSED_VOLUME}" \
    "${cleanup_candidate_reused_volume}" || cleanup_status=1

  confirm_container_absent_after_cleanup "${WRITER_CONTAINER}" \
    || cleanup_status=1
  confirm_container_absent_after_cleanup "${REUSE_READER_CONTAINER}" \
    || cleanup_status=1
  confirm_container_absent_after_cleanup "${FRESH_READER_CONTAINER}" \
    || cleanup_status=1
  confirm_volume_absent_after_cleanup "${REUSED_VOLUME}" \
    || cleanup_status=1
  confirm_volume_absent_after_cleanup "${FRESH_VOLUME}" \
    || cleanup_status=1

  capture_command docker container ls --all \
    --filter "label=${RESOURCE_LABEL}=${RUN_ID}" --format '{{.Names}}'
  if (( CAPTURED_STATUS != 0 )) || [[ -n "${CAPTURED_OUTPUT}" ]]; then
    log 'cleanup ERROR: run-labeled containers remain or could not be queried'
    cleanup_status=1
  else
    log 'cleanup confirmed no run-labeled containers remain'
  fi

  capture_command docker volume ls \
    --filter "label=${RESOURCE_LABEL}=${RUN_ID}" --format '{{.Name}}'
  if (( CAPTURED_STATUS != 0 )) || [[ -n "${CAPTURED_OUTPUT}" ]]; then
    log 'cleanup ERROR: run-labeled volumes remain or could not be queried'
    cleanup_status=1
  else
    log 'cleanup confirmed no run-labeled volumes remain'
  fi

  final_status=${main_status}
  if (( final_status == 0 && cleanup_status != 0 )); then
    final_status=1
  fi

  log "cleanup summary: main_status=${main_status} cleanup_status=${cleanup_status} final_status=${final_status}"
  if (( final_status == 0 )); then
    log 'verification PASS: assertions and cleanup all succeeded'
  else
    log 'verification FAIL'
  fi
  exit "${final_status}"
}

redact_stream() {
  awk -v first_secret="${HOST_USERNAME}" -v second_secret="${HOME_USERNAME}" '
    function redact(value, secret, position, result) {
      if (secret == "") {
        return value
      }
      result = ""
      while ((position = index(value, secret)) != 0) {
        result = result substr(value, 1, position - 1) "[USER]"
        value = substr(value, position + length(secret))
      }
      return result value
    }
    {
      line = redact($0, first_secret)
      if (second_secret != first_secret) {
        line = redact(line, second_secret)
      }
      print line
      fflush()
    }
  '
}

for command_name in awk basename date docker tee; do
  require_command "${command_name}"
done
[[ -d "${PROJECT_ROOT}/logs" ]] \
  || fail "logs directory not found: ${PROJECT_ROOT}/logs"

HOST_USERNAME=${USER:-}
if [[ -z "${HOST_USERNAME}" ]]; then
  HOST_USERNAME=$(id -un 2>/dev/null || true)
fi
HOME_USERNAME=''
if [[ -n "${HOME:-}" ]]; then
  HOME_USERNAME=$(basename -- "${HOME}")
fi
if [[ "${HOME_USERNAME}" == '/' ]]; then
  HOME_USERNAME=''
fi
readonly HOST_USERNAME HOME_USERNAME

# From this point onward, every command and output line is copied to the owned
# evidence log, with literal host usernames replaced before either destination.
exec > >(redact_stream | tee "${LOG_FILE}") 2>&1

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

log 'Docker named-volume reuse verification'
log "UTC start: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
log "run id: ${RUN_ID}"
log "pinned image: ${IMAGE}"
log "ownership label: ${RESOURCE_LABEL}=${RUN_ID}"
log "same-name volume: ${REUSED_VOLUME}"
log "different fresh volume: ${FRESH_VOLUME}"

run docker context show
run docker version --format 'Client={{.Client.Version}} Server={{.Server.Version}}'

capture_command docker image inspect "${IMAGE}" --format \
  'Id={{.Id}} RepoDigests={{json .RepoDigests}} OS={{.Os}} Architecture={{.Architecture}}'
if (( CAPTURED_STATUS != 0 )); then
  log 'pinned image is not local; pulling the exact digest'
  run docker image pull "${IMAGE}"
  capture_command docker image inspect "${IMAGE}" --format \
    'Id={{.Id}} RepoDigests={{json .RepoDigests}} OS={{.Os}} Architecture={{.Architecture}}'
fi
assert_command_succeeded 'pinned Ubuntu image is available and inspectable'

log 'preflight: every planned resource name must be unused'
assert_resource_absent volume "${REUSED_VOLUME}"
assert_resource_absent volume "${FRESH_VOLUME}"
assert_resource_absent container "${WRITER_CONTAINER}"
assert_resource_absent container "${REUSE_READER_CONTAINER}"
assert_resource_absent container "${FRESH_READER_CONTAINER}"

log 'phase 1: create one volume and write a sentinel into it'
cleanup_candidate_reused_volume=1
capture_command docker volume create \
  --label "${RESOURCE_LABEL}=${RUN_ID}" "${REUSED_VOLUME}"
assert_command_succeeded 'initial volume creation succeeded'
assert_equals "${CAPTURED_OUTPUT}" "${REUSED_VOLUME}" \
  'initial create returned the requested volume name'
verify_volume_owner "${REUSED_VOLUME}"

capture_command docker volume inspect --format \
  'CreatedAt={{.CreatedAt}}|Mountpoint={{.Mountpoint}}|Driver={{.Driver}}' \
  "${REUSED_VOLUME}"
assert_command_succeeded 'initial volume identity was inspectable'
readonly BEFORE_RECREATE_IDENTITY="${CAPTURED_OUTPUT}"
assert_nonempty "${BEFORE_RECREATE_IDENTITY}" 'initial volume identity was nonempty'

cleanup_candidate_writer=1
capture_command docker container create \
  --name "${WRITER_CONTAINER}" \
  --label "${RESOURCE_LABEL}=${RUN_ID}" \
  --mount "type=volume,source=${REUSED_VOLUME},target=/evidence" \
  --entrypoint /bin/sh \
  "${IMAGE}" -ceu \
  'printf "%s\n" "$1" > /evidence/sentinel.txt; printf "sentinel-written=%s\n" "$1"' \
  volume-writer "${SENTINEL}"
assert_command_succeeded 'sentinel writer container creation succeeded'
assert_nonempty "${CAPTURED_OUTPUT}" 'sentinel writer container ID was returned'
verify_container_owner "${WRITER_CONTAINER}"

capture_command docker container start --attach "${WRITER_CONTAINER}"
assert_command_succeeded 'sentinel writer ran successfully'
assert_equals "${CAPTURED_OUTPUT}" "sentinel-written=${SENTINEL}" \
  'writer reported the exact run-scoped sentinel'
verify_container_exit_zero "${WRITER_CONTAINER}"

log 'phase 2: call docker volume create again with the exact SAME name'
capture_command docker volume create \
  --label "${RESOURCE_LABEL}=${RUN_ID}" "${REUSED_VOLUME}"
assert_command_succeeded 'same-name docker volume create call succeeded'
assert_equals "${CAPTURED_OUTPUT}" "${REUSED_VOLUME}" \
  'same-name create returned the already-existing volume name'
verify_volume_owner "${REUSED_VOLUME}"

capture_command docker volume inspect --format \
  'CreatedAt={{.CreatedAt}}|Mountpoint={{.Mountpoint}}|Driver={{.Driver}}' \
  "${REUSED_VOLUME}"
assert_command_succeeded 'same-name volume identity was inspectable after create'
readonly AFTER_RECREATE_IDENTITY="${CAPTURED_OUTPUT}"
assert_equals "${AFTER_RECREATE_IDENTITY}" "${BEFORE_RECREATE_IDENTITY}" \
  'same-name create preserved CreatedAt, Mountpoint, and Driver (the original volume was reused)'

cleanup_candidate_reuse_reader=1
capture_command docker container create \
  --name "${REUSE_READER_CONTAINER}" \
  --label "${RESOURCE_LABEL}=${RUN_ID}" \
  --mount "type=volume,source=${REUSED_VOLUME},target=/evidence,readonly" \
  --entrypoint /bin/sh \
  "${IMAGE}" -ceu \
  'actual=$(cat /evidence/sentinel.txt); test "$actual" = "$1"; printf "sentinel-present=%s\n" "$actual"' \
  reuse-reader "${SENTINEL}"
assert_command_succeeded 'same-name volume reader container creation succeeded'
assert_nonempty "${CAPTURED_OUTPUT}" 'same-name volume reader container ID was returned'
verify_container_owner "${REUSE_READER_CONTAINER}"

capture_command docker container start --attach "${REUSE_READER_CONTAINER}"
assert_command_succeeded 'same-name volume reader ran successfully'
assert_equals "${CAPTURED_OUTPUT}" "sentinel-present=${SENTINEL}" \
  'stale sentinel remained after same-name docker volume create'
verify_container_exit_zero "${REUSE_READER_CONTAINER}"

log 'phase 3: create a DIFFERENT unique volume and prove it is empty'
assert_not_equals "${FRESH_VOLUME}" "${REUSED_VOLUME}" \
  'fresh volume name differs from the reused volume name'
cleanup_candidate_fresh_volume=1
capture_command docker volume create \
  --label "${RESOURCE_LABEL}=${RUN_ID}" "${FRESH_VOLUME}"
assert_command_succeeded 'different fresh volume creation succeeded'
assert_equals "${CAPTURED_OUTPUT}" "${FRESH_VOLUME}" \
  'fresh create returned the different requested volume name'
verify_volume_owner "${FRESH_VOLUME}"

capture_command docker volume inspect --format '{{.Mountpoint}}' "${REUSED_VOLUME}"
assert_command_succeeded 'reused volume mountpoint was inspectable'
readonly REUSED_MOUNTPOINT="${CAPTURED_OUTPUT}"
capture_command docker volume inspect --format '{{.Mountpoint}}' "${FRESH_VOLUME}"
assert_command_succeeded 'fresh volume mountpoint was inspectable'
readonly FRESH_MOUNTPOINT="${CAPTURED_OUTPUT}"
assert_not_equals "${FRESH_MOUNTPOINT}" "${REUSED_MOUNTPOINT}" \
  'different volume has a different Docker mountpoint'

cleanup_candidate_fresh_reader=1
capture_command docker container create \
  --name "${FRESH_READER_CONTAINER}" \
  --label "${RESOURCE_LABEL}=${RUN_ID}" \
  --mount "type=volume,source=${FRESH_VOLUME},target=/evidence,readonly" \
  --entrypoint /bin/sh \
  "${IMAGE}" -ceu \
  'test ! -e /evidence/sentinel.txt; test -z "$(ls -A /evidence)"; printf "sentinel-absent=/evidence/sentinel.txt\nfresh-volume-empty=yes\n"' \
  fresh-reader
assert_command_succeeded 'fresh-volume reader container creation succeeded'
assert_nonempty "${CAPTURED_OUTPUT}" 'fresh-volume reader container ID was returned'
verify_container_owner "${FRESH_READER_CONTAINER}"

capture_command docker container start --attach "${FRESH_READER_CONTAINER}"
assert_command_succeeded 'fresh-volume emptiness check ran successfully'
readonly EXPECTED_FRESH_OUTPUT=$'sentinel-absent=/evidence/sentinel.txt\nfresh-volume-empty=yes'
assert_equals "${CAPTURED_OUTPUT}" "${EXPECTED_FRESH_OUTPUT}" \
  'different fresh volume contained neither the sentinel nor any other data'
verify_container_exit_zero "${FRESH_READER_CONTAINER}"

log 'all behavioral assertions passed; EXIT trap will verify owned-resource cleanup'
