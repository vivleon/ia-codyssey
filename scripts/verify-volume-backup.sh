#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(CDPATH='' cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly LOG_FILE="${PROJECT_ROOT}/logs/volume-backup-restore.txt"
readonly IMAGE="ubuntu@sha256:3131b4cc82a783df6c9df078f86e01819a13594b865c2cad47bd1bca2b7063bb"
readonly RESOURCE_LABEL="io.github.vivleon.ia-codyssey.volume-backup-run"

TEMP_ROOT=''
RUN_ID=''
SOURCE_VOLUME=''
RESTORE_VOLUME=''
WRITER_CONTAINER=''
BACKUP_CONTAINER=''
RESTORE_CONTAINER=''
READER_CONTAINER=''

owns_temp_root=0
owns_source_volume=0
owns_restore_volume=0
owns_writer_container=0
owns_backup_container=0
owns_restore_container=0
owns_reader_container=0

log() {
  printf '[volume-backup] %s\n' "$*"
}

fail() {
  printf '[volume-backup] ERROR: %s\n' "$*" >&2
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

CAPTURED_OUTPUT=''
capture() {
  local command_status

  print_command "$@"
  set +e
  CAPTURED_OUTPUT="$("$@" 2>&1)"
  command_status=$?
  set -e
  printf '%s\n' "${CAPTURED_OUTPUT}"
  return "${command_status}"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

assert_absent() {
  local resource_type=$1
  local resource_name=$2

  if docker "${resource_type}" inspect "${resource_name}" >/dev/null 2>&1; then
    fail "refusing to reuse existing Docker ${resource_type}: ${resource_name}"
  fi
  log "name is unused: ${resource_type} ${resource_name}"
}

container_owner_label() {
  docker container inspect \
    --format "{{index .Config.Labels \"${RESOURCE_LABEL}\"}}" "$1" 2>/dev/null
}

volume_owner_label() {
  docker volume inspect \
    --format "{{index .Labels \"${RESOURCE_LABEL}\"}}" "$1" 2>/dev/null
}

remove_owned_container_now() {
  local container_name=$1
  local remove_mode=${2:-normal}
  local actual_label

  actual_label="$(container_owner_label "${container_name}")" \
    || fail "expected owned container is missing: ${container_name}"
  [[ "${actual_label}" == "${RUN_ID}" ]] \
    || fail "ownership label mismatch; refusing to remove container: ${container_name}"

  if [[ "${remove_mode}" == 'force' ]]; then
    run docker container rm --force "${container_name}"
  else
    run docker container rm "${container_name}"
  fi
}

remove_owned_volume_now() {
  local volume_name=$1
  local actual_label

  actual_label="$(volume_owner_label "${volume_name}")" \
    || fail "expected owned volume is missing: ${volume_name}"
  [[ "${actual_label}" == "${RUN_ID}" ]] \
    || fail "ownership label mismatch; refusing to remove volume: ${volume_name}"
  run docker volume rm "${volume_name}"
}

cleanup_owned_container() {
  local container_name=$1
  local should_own=$2
  local actual_label

  (( should_own )) || return 0

  if ! actual_label="$(container_owner_label "${container_name}")"; then
    log "cleanup: container already absent: ${container_name}"
    return 0
  fi
  if [[ "${actual_label}" != "${RUN_ID}" ]]; then
    log "cleanup ERROR: ownership mismatch; left container untouched: ${container_name}"
    return 1
  fi

  print_command docker container rm --force "${container_name}"
  docker container rm --force "${container_name}"
}

cleanup_owned_volume() {
  local volume_name=$1
  local should_own=$2
  local actual_label

  (( should_own )) || return 0

  if ! actual_label="$(volume_owner_label "${volume_name}")"; then
    log "cleanup: volume already absent: ${volume_name}"
    return 0
  fi
  if [[ "${actual_label}" != "${RUN_ID}" ]]; then
    log "cleanup ERROR: ownership mismatch; left volume untouched: ${volume_name}"
    return 1
  fi

  print_command docker volume rm "${volume_name}"
  docker volume rm "${volume_name}"
}

cleanup() {
  local original_status=$?
  local cleanup_status=0
  local resource_name

  trap - EXIT INT TERM
  set +e

  log "cleanup starting for run ${RUN_ID:-not-initialized}"

  cleanup_owned_container "${READER_CONTAINER}" "${owns_reader_container}" \
    || cleanup_status=1
  cleanup_owned_container "${RESTORE_CONTAINER}" "${owns_restore_container}" \
    || cleanup_status=1
  cleanup_owned_container "${BACKUP_CONTAINER}" "${owns_backup_container}" \
    || cleanup_status=1
  cleanup_owned_container "${WRITER_CONTAINER}" "${owns_writer_container}" \
    || cleanup_status=1

  cleanup_owned_volume "${RESTORE_VOLUME}" "${owns_restore_volume}" \
    || cleanup_status=1
  cleanup_owned_volume "${SOURCE_VOLUME}" "${owns_source_volume}" \
    || cleanup_status=1

  for resource_name in \
    "${WRITER_CONTAINER}" \
    "${BACKUP_CONTAINER}" \
    "${RESTORE_CONTAINER}" \
    "${READER_CONTAINER}"; do
    [[ -n "${resource_name}" ]] || continue
    if docker container inspect "${resource_name}" >/dev/null 2>&1; then
      log "cleanup ERROR: container still exists: ${resource_name}"
      cleanup_status=1
    else
      log "cleanup confirmed container absent: ${resource_name}"
    fi
  done

  for resource_name in "${SOURCE_VOLUME}" "${RESTORE_VOLUME}"; do
    [[ -n "${resource_name}" ]] || continue
    if docker volume inspect "${resource_name}" >/dev/null 2>&1; then
      log "cleanup ERROR: volume still exists: ${resource_name}"
      cleanup_status=1
    else
      log "cleanup confirmed volume absent: ${resource_name}"
    fi
  done

  if (( owns_temp_root )) && [[ -n "${TEMP_ROOT}" ]]; then
    print_command rm -rf -- "${TEMP_ROOT}"
    rm -rf -- "${TEMP_ROOT}" || cleanup_status=1
    if [[ -e "${TEMP_ROOT}" ]]; then
      log "cleanup ERROR: temporary backup directory still exists: ${TEMP_ROOT}"
      cleanup_status=1
    else
      log "cleanup confirmed temporary backup directory absent: ${TEMP_ROOT}"
    fi
  fi

  if (( original_status == 0 && cleanup_status != 0 )); then
    original_status=1
  fi

  if (( original_status == 0 )); then
    log 'cleanup complete; verification exit status=0'
  else
    log "cleanup complete; verification exit status=${original_status}"
  fi
  exit "${original_status}"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for command_name in docker mktemp tee tr date rm; do
  require_command "${command_name}"
done
require_command sed
[[ -d "${PROJECT_ROOT}/logs" ]] || fail "logs directory not found: ${PROJECT_ROOT}/logs"

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ia-codyssey-volume-backup.XXXXXX")"
owns_temp_root=1
case "${TEMP_ROOT}" in
  *',') fail "temporary path cannot be used safely in a Docker --mount specification" ;;
esac

temp_token="$(basename -- "${TEMP_ROOT}" | tr '[:upper:]' '[:lower:]')"
RUN_ID="$(date -u '+%Y%m%dT%H%M%SZ')-$$-${temp_token##*.}"

SOURCE_VOLUME="ia-codyssey-backup-source-${RUN_ID}"
RESTORE_VOLUME="ia-codyssey-backup-restored-${RUN_ID}"
WRITER_CONTAINER="ia-codyssey-backup-writer-${RUN_ID}"
BACKUP_CONTAINER="ia-codyssey-backup-archiver-${RUN_ID}"
RESTORE_CONTAINER="ia-codyssey-backup-restorer-${RUN_ID}"
READER_CONTAINER="ia-codyssey-backup-reader-${RUN_ID}"

readonly BACKUP_FILE="${TEMP_ROOT}/volume-backup.tar"
readonly PAYLOAD="Docker volume backup restored successfully (${RUN_ID})"

if [[ -n "${USER:-}" ]]; then
  exec > >(sed "s/${USER}/[USER]/g" | tee "${LOG_FILE}") 2>&1
else
  exec > >(tee "${LOG_FILE}") 2>&1
fi

log 'Docker named-volume backup and restore verification'
log "UTC start: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
log "run id: ${RUN_ID}"
log "pinned image: ${IMAGE}"
log "temporary host backup directory: ${TEMP_ROOT}"

run docker context show
run docker version --format 'Client={{.Client.Version}} Server={{.Server.Version}}'
run docker info --format 'Engine={{.ServerVersion}} OS={{.OperatingSystem}} Architecture={{.Architecture}}'

if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
  run docker image pull "${IMAGE}"
fi
run docker image inspect "${IMAGE}" \
  --format 'Id={{.Id}} RepoDigests={{json .RepoDigests}} OS={{.Os}} Architecture={{.Architecture}}'

assert_absent volume "${SOURCE_VOLUME}"
assert_absent volume "${RESTORE_VOLUME}"
assert_absent container "${WRITER_CONTAINER}"
assert_absent container "${BACKUP_CONTAINER}"
assert_absent container "${RESTORE_CONTAINER}"
assert_absent container "${READER_CONTAINER}"

log 'creating the source volume and writer container'
owns_source_volume=1
run docker volume create \
  --label "${RESOURCE_LABEL}=${RUN_ID}" \
  "${SOURCE_VOLUME}"
capture volume_owner_label "${SOURCE_VOLUME}"
[[ "${CAPTURED_OUTPUT}" == "${RUN_ID}" ]] \
  || fail "source volume ownership label was not applied"
run docker volume inspect "${SOURCE_VOLUME}"

owns_writer_container=1
run docker container create \
  --name "${WRITER_CONTAINER}" \
  --label "${RESOURCE_LABEL}=${RUN_ID}" \
  --mount "type=volume,source=${SOURCE_VOLUME},target=/source" \
  --entrypoint /usr/bin/sleep \
  "${IMAGE}" infinity
run docker container start "${WRITER_CONTAINER}"
run docker container inspect "${WRITER_CONTAINER}" --format '{{json .Mounts}}'

log 'writing the source payload and reading it back'
run docker container exec "${WRITER_CONTAINER}" /bin/sh -ceu \
  'printf "%s\n" "$1" > /source/evidence.txt' volume-writer "${PAYLOAD}"
capture docker container exec "${WRITER_CONTAINER}" cat /source/evidence.txt
SOURCE_CONTENT="${CAPTURED_OUTPUT}"
[[ "${SOURCE_CONTENT}" == "${PAYLOAD}" ]] \
  || fail "source file content differs from the payload"

capture docker container exec "${WRITER_CONTAINER}" sha256sum /source/evidence.txt
SOURCE_SHA_LINE="${CAPTURED_OUTPUT}"
SOURCE_SHA="${SOURCE_SHA_LINE%% *}"
[[ ${#SOURCE_SHA} -eq 64 && "${SOURCE_SHA}" != *[!0-9a-f]* ]] \
  || fail "invalid source SHA-256 output: ${SOURCE_SHA_LINE}"
log "source content and SHA-256 confirmed: ${SOURCE_SHA}"

log 'creating a tar backup from a read-only source-volume mount'
owns_backup_container=1
run docker container create \
  --name "${BACKUP_CONTAINER}" \
  --label "${RESOURCE_LABEL}=${RUN_ID}" \
  --mount "type=volume,source=${SOURCE_VOLUME},target=/source,readonly" \
  --mount "type=bind,source=${TEMP_ROOT},target=/backup" \
  --entrypoint /bin/sh \
  "${IMAGE}" -ceu \
  'tar -C /source --numeric-owner -cpf /backup/volume-backup.tar .; printf "tar backup created: /backup/volume-backup.tar\n"'
run docker container inspect "${BACKUP_CONTAINER}" --format '{{json .Mounts}}'
capture docker container inspect "${BACKUP_CONTAINER}" \
  --format '{{range .Mounts}}{{if eq .Destination "/source"}}source_mount_rw={{.RW}}{{end}}{{end}}'
[[ "${CAPTURED_OUTPUT}" == 'source_mount_rw=false' ]] \
  || fail "backup source mount is not read-only"
run docker container start --attach "${BACKUP_CONTAINER}"
capture docker container inspect "${BACKUP_CONTAINER}" --format '{{.State.ExitCode}}'
[[ "${CAPTURED_OUTPUT}" == '0' ]] || fail "backup container failed"
[[ -s "${BACKUP_FILE}" ]] || fail "tar backup was not created on the host"
run ls -l "${BACKUP_FILE}"
remove_owned_container_now "${BACKUP_CONTAINER}"
owns_backup_container=0

log 'removing the writer container and original source volume before restore'
remove_owned_container_now "${WRITER_CONTAINER}" force
owns_writer_container=0
remove_owned_volume_now "${SOURCE_VOLUME}"
owns_source_volume=0
if docker container inspect "${WRITER_CONTAINER}" >/dev/null 2>&1; then
  fail "writer container still exists after removal"
fi
if docker volume inspect "${SOURCE_VOLUME}" >/dev/null 2>&1; then
  fail "source volume still exists after removal"
fi
log 'confirmed: writer container and original source volume are absent'

log 'creating a new empty volume and restoring the tar backup'
owns_restore_volume=1
run docker volume create \
  --label "${RESOURCE_LABEL}=${RUN_ID}" \
  "${RESTORE_VOLUME}"
capture volume_owner_label "${RESTORE_VOLUME}"
[[ "${CAPTURED_OUTPUT}" == "${RUN_ID}" ]] \
  || fail "restore volume ownership label was not applied"
run docker volume inspect "${RESTORE_VOLUME}"

owns_restore_container=1
run docker container create \
  --name "${RESTORE_CONTAINER}" \
  --label "${RESOURCE_LABEL}=${RUN_ID}" \
  --mount "type=volume,source=${RESTORE_VOLUME},target=/restore" \
  --mount "type=bind,source=${TEMP_ROOT},target=/backup,readonly" \
  --entrypoint /bin/sh \
  "${IMAGE}" -ceu \
  'test -z "$(ls -A /restore)"; printf "restore target confirmed empty\n"; tar -C /restore --numeric-owner -xpf /backup/volume-backup.tar; printf "tar restore completed\n"'
run docker container inspect "${RESTORE_CONTAINER}" --format '{{json .Mounts}}'
run docker container start --attach "${RESTORE_CONTAINER}"
capture docker container inspect "${RESTORE_CONTAINER}" --format '{{.State.ExitCode}}'
[[ "${CAPTURED_OUTPUT}" == '0' ]] || fail "restore container failed"
remove_owned_container_now "${RESTORE_CONTAINER}"
owns_restore_container=0

log 'using a separate read-only reader container to verify restored data'
owns_reader_container=1
run docker container create \
  --name "${READER_CONTAINER}" \
  --label "${RESOURCE_LABEL}=${RUN_ID}" \
  --mount "type=volume,source=${RESTORE_VOLUME},target=/restored,readonly" \
  --entrypoint /usr/bin/sleep \
  "${IMAGE}" infinity
run docker container start "${READER_CONTAINER}"
run docker container inspect "${READER_CONTAINER}" --format '{{json .Mounts}}'
capture docker container inspect "${READER_CONTAINER}" \
  --format '{{range .Mounts}}{{if eq .Destination "/restored"}}reader_mount_rw={{.RW}}{{end}}{{end}}'
[[ "${CAPTURED_OUTPUT}" == 'reader_mount_rw=false' ]] \
  || fail "reader volume mount is not read-only"

capture docker container exec "${READER_CONTAINER}" cat /restored/evidence.txt
RESTORED_CONTENT="${CAPTURED_OUTPUT}"
[[ "${RESTORED_CONTENT}" == "${SOURCE_CONTENT}" ]] \
  || fail "restored content does not match source content"

capture docker container exec "${READER_CONTAINER}" sha256sum /restored/evidence.txt
RESTORED_SHA_LINE="${CAPTURED_OUTPUT}"
RESTORED_SHA="${RESTORED_SHA_LINE%% *}"
[[ "${RESTORED_SHA}" == "${SOURCE_SHA}" ]] \
  || fail "restored SHA-256 does not match source SHA-256"

log "content match confirmed: ${RESTORED_CONTENT}"
log "SHA-256 match confirmed: source=${SOURCE_SHA} restored=${RESTORED_SHA}"
log 'all backup and restore checks passed; EXIT trap will remove remaining owned resources'
exit 0
