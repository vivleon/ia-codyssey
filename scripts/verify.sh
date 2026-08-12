#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(CDPATH='' cd -- "${SCRIPT_DIR}/.." && pwd)"

log() {
  printf '[verify] %s\n' "$*"
}

fail() {
  printf '[verify] ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

for command_name in docker curl grep mktemp; do
  require_command "${command_name}"
done

[[ -f "${PROJECT_ROOT}/Dockerfile" ]] || fail "Dockerfile not found in ${PROJECT_ROOT}"
[[ -f "${PROJECT_ROOT}/app/index.html" ]] || fail "app/index.html not found in ${PROJECT_ROOT}"

readonly TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ia-codyssey-verify.XXXXXX")"
readonly BIND_DIR="${TEMP_ROOT}/bind-app"
readonly HTTP_BODY="${TEMP_ROOT}/http-body.txt"
readonly BIND_BODY="${TEMP_ROOT}/bind-body.txt"
readonly TEMP_TOKEN="$(basename -- "${TEMP_ROOT}" | tr '[:upper:]' '[:lower:]')"
readonly RUN_ID="$(date -u '+%Y%m%d%H%M%S')-$$-${TEMP_TOKEN##*.}"

readonly IMAGE_NAME="ia-codyssey-verify:${RUN_ID}"
readonly WEB_CONTAINER="ia-codyssey-verify-web-${RUN_ID}"
readonly BIND_CONTAINER="ia-codyssey-verify-bind-${RUN_ID}"
readonly VOLUME_WRITER="ia-codyssey-verify-volume-writer-${RUN_ID}"
readonly VOLUME_READER="ia-codyssey-verify-volume-reader-${RUN_ID}"
readonly VOLUME_NAME="ia-codyssey-verify-data-${RUN_ID}"
readonly RESOURCE_LABEL="io.github.vivleon.ia-codyssey.verify-run"

owns_image=0
owns_web_container=0
owns_bind_container=0
owns_volume_writer=0
owns_volume_reader=0
owns_volume=0
IMAGE_ID=''

remove_owned_container() {
  local container_name=$1
  local actual_label=''

  if ! docker container inspect "${container_name}" >/dev/null 2>&1; then
    log "cleanup: container already absent: ${container_name}"
    return 0
  fi

  actual_label="$(docker container inspect \
    --format "{{index .Config.Labels \"${RESOURCE_LABEL}\"}}" \
    "${container_name}" 2>/dev/null || true)"
  if [[ "${actual_label}" != "${RUN_ID}" ]]; then
    log "cleanup REFUSED: container ownership mismatch: ${container_name}"
    return 1
  fi

  docker container rm --force "${container_name}" >/dev/null
}

remove_owned_volume() {
  local volume_name=$1
  local actual_label=''

  if ! docker volume inspect "${volume_name}" >/dev/null 2>&1; then
    log "cleanup: volume already absent: ${volume_name}"
    return 0
  fi

  actual_label="$(docker volume inspect \
    --format "{{index .Labels \"${RESOURCE_LABEL}\"}}" \
    "${volume_name}" 2>/dev/null || true)"
  if [[ "${actual_label}" != "${RUN_ID}" ]]; then
    log "cleanup REFUSED: volume ownership mismatch: ${volume_name}"
    return 1
  fi

  docker volume rm "${volume_name}" >/dev/null
}

remove_owned_image() {
  local image_name=$1
  local current_id=''
  local actual_label=''

  if ! docker image inspect "${image_name}" >/dev/null 2>&1; then
    log "cleanup: image tag already absent: ${image_name}"
    return 0
  fi

  current_id="$(docker image inspect --format '{{.Id}}' "${image_name}" 2>/dev/null || true)"
  actual_label="$(docker image inspect \
    --format "{{index .Config.Labels \"${RESOURCE_LABEL}\"}}" \
    "${image_name}" 2>/dev/null || true)"
  if [[ -z "${IMAGE_ID}" || "${current_id}" != "${IMAGE_ID}" || "${actual_label}" != "${RUN_ID}" ]]; then
    log "cleanup REFUSED: image tag ownership or ID mismatch: ${image_name}"
    return 1
  fi

  docker image rm "${image_name}" >/dev/null
}

cleanup() {
  local original_status=$?
  local cleanup_status=0

  trap - EXIT INT TERM
  set +e

  log "cleaning up resources for ${RUN_ID}"

  if (( owns_web_container )); then
    remove_owned_container "${WEB_CONTAINER}" || cleanup_status=1
  fi
  if (( owns_bind_container )); then
    remove_owned_container "${BIND_CONTAINER}" || cleanup_status=1
  fi
  if (( owns_volume_writer )); then
    remove_owned_container "${VOLUME_WRITER}" || cleanup_status=1
  fi
  if (( owns_volume_reader )); then
    remove_owned_container "${VOLUME_READER}" || cleanup_status=1
  fi
  if (( owns_volume )); then
    remove_owned_volume "${VOLUME_NAME}" || cleanup_status=1
  fi
  if (( owns_image )); then
    remove_owned_image "${IMAGE_NAME}" || cleanup_status=1
  fi

  rm -f -- "${HTTP_BODY}" "${BIND_BODY}" "${BIND_DIR}/index.html"
  rmdir -- "${BIND_DIR}" "${TEMP_ROOT}" >/dev/null 2>&1 || cleanup_status=1

  if (( original_status == 0 && cleanup_status != 0 )); then
    printf '[verify] ERROR: verification passed, but cleanup was incomplete\n' >&2
    exit 1
  fi

  exit "${original_status}"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'printf "[verify] ERROR: command failed at line %s\n" "${LINENO}" >&2' ERR

assert_resource_absent() {
  local resource_type=$1
  local resource_name=$2

  if docker "${resource_type}" inspect "${resource_name}" >/dev/null 2>&1; then
    fail "refusing to overwrite existing Docker ${resource_type}: ${resource_name}"
  fi
}

container_port() {
  local container_name=$1
  local binding
  local port

  binding="$(docker container port "${container_name}" 80/tcp | sed -n '1p')"
  case "${binding}" in
    127.0.0.1:*) ;;
    *) fail "unexpected port binding for ${container_name}: ${binding:-none}" ;;
  esac

  port="${binding##*:}"
  case "${port}" in
    ''|*[!0-9]*) fail "invalid host port for ${container_name}: ${port:-none}" ;;
  esac

  printf '%s\n' "${port}"
}

wait_for_http_200() {
  local container_name=$1
  local url=$2
  local body_file=$3
  local status='000'
  local attempt

  for (( attempt = 1; attempt <= 45; attempt++ )); do
    if status="$(curl --silent --show-error --max-time 3 \
      --output "${body_file}" --write-out '%{http_code}' "${url}" 2>/dev/null)" \
      && [[ "${status}" == '200' ]]; then
      log "HTTP 200 confirmed at ${url}"
      return 0
    fi

    if [[ "$(docker container inspect --format '{{.State.Running}}' "${container_name}")" != 'true' ]]; then
      docker container logs "${container_name}" >&2 || true
      fail "container stopped before serving HTTP: ${container_name}"
    fi
    sleep 1
  done

  docker container logs "${container_name}" >&2 || true
  fail "timed out waiting for HTTP 200 at ${url}; last status=${status}"
}

wait_for_healthy() {
  local container_name=$1
  local health_status
  local attempt

  for (( attempt = 1; attempt <= 45; attempt++ )); do
    health_status="$(docker container inspect \
      --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' \
      "${container_name}")"

    case "${health_status}" in
      healthy)
        log "health status confirmed: healthy"
        return 0
        ;;
      starting)
        sleep 1
        ;;
      *)
        docker container inspect --format '{{json .State.Health}}' "${container_name}" >&2 || true
        fail "unexpected health status for ${container_name}: ${health_status}"
        ;;
    esac
  done

  docker container inspect --format '{{json .State.Health}}' "${container_name}" >&2 || true
  fail "timed out waiting for healthy status: ${container_name}"
}

write_bind_page() {
  local marker=$1

  printf '%s\n' \
    '<!doctype html>' \
    '<html lang="en">' \
    '<head><meta charset="utf-8"><title>Bind verification</title></head>' \
    "<body><p>${marker}</p></body>" \
    '</html>' > "${BIND_DIR}/index.html"
}

log "checking Docker engine"
docker info >/dev/null

assert_resource_absent image "${IMAGE_NAME}"
assert_resource_absent container "${WEB_CONTAINER}"
assert_resource_absent container "${BIND_CONTAINER}"
assert_resource_absent container "${VOLUME_WRITER}"
assert_resource_absent container "${VOLUME_READER}"
assert_resource_absent volume "${VOLUME_NAME}"

log "building ${IMAGE_NAME} from the minimized context"
docker build --progress=plain \
  --label "${RESOURCE_LABEL}=${RUN_ID}" \
  --tag "${IMAGE_NAME}" \
  "${PROJECT_ROOT}"
owns_image=1
IMAGE_ID="$(docker image inspect --format '{{.Id}}' "${IMAGE_NAME}")"

image_label="$(docker image inspect --format "{{index .Config.Labels \"${RESOURCE_LABEL}\"}}" "${IMAGE_NAME}")"
[[ "${image_label}" == "${RUN_ID}" ]] || fail "built image does not have the expected ownership label"

log "creating isolated web container"
docker container create \
  --name "${WEB_CONTAINER}" \
  --label "${RESOURCE_LABEL}=${RUN_ID}" \
  --publish '127.0.0.1::80' \
  --health-interval 1s \
  --health-timeout 3s \
  --health-start-period 1s \
  --health-retries 10 \
  "${IMAGE_NAME}" >/dev/null
owns_web_container=1
docker container start "${WEB_CONTAINER}" >/dev/null

web_port="$(container_port "${WEB_CONTAINER}")"
web_url="http://127.0.0.1:${web_port}/"
wait_for_http_200 "${WEB_CONTAINER}" "${web_url}" "${HTTP_BODY}"
grep --fixed-strings --quiet 'IA Codyssey Development Workstation' "${HTTP_BODY}" \
  || fail "the built image did not serve the expected application page"
wait_for_healthy "${WEB_CONTAINER}"

log "verifying live bind-mount updates"
mkdir -- "${BIND_DIR}"
readonly BIND_BEFORE="bind-before-${RUN_ID}"
readonly BIND_AFTER="bind-after-${RUN_ID}"
write_bind_page "${BIND_BEFORE}"

docker container create \
  --name "${BIND_CONTAINER}" \
  --label "${RESOURCE_LABEL}=${RUN_ID}" \
  --publish '127.0.0.1::80' \
  --mount "type=bind,source=${BIND_DIR},target=/usr/share/nginx/html,readonly" \
  "${IMAGE_NAME}" >/dev/null
owns_bind_container=1
docker container start "${BIND_CONTAINER}" >/dev/null

bind_port="$(container_port "${BIND_CONTAINER}")"
bind_url="http://127.0.0.1:${bind_port}/"
wait_for_http_200 "${BIND_CONTAINER}" "${bind_url}" "${BIND_BODY}"
grep --fixed-strings --quiet "${BIND_BEFORE}" "${BIND_BODY}" \
  || fail "bind mount did not serve the initial host content"

write_bind_page "${BIND_AFTER}"
wait_for_http_200 "${BIND_CONTAINER}" "${bind_url}?run=${RUN_ID}" "${BIND_BODY}"
grep --fixed-strings --quiet "${BIND_AFTER}" "${BIND_BODY}" \
  || fail "bind mount did not reflect the host file update"
log "bind-mount update confirmed"

log "verifying named-volume persistence across containers"
docker volume create \
  --label "${RESOURCE_LABEL}=${RUN_ID}" \
  "${VOLUME_NAME}" >/dev/null
owns_volume=1

volume_label="$(docker volume inspect --format "{{index .Labels \"${RESOURCE_LABEL}\"}}" "${VOLUME_NAME}")"
[[ "${volume_label}" == "${RUN_ID}" ]] || fail "volume does not have the expected ownership label"

readonly VOLUME_PAYLOAD="persistent-data-${RUN_ID}"
docker container create \
  --name "${VOLUME_WRITER}" \
  --label "${RESOURCE_LABEL}=${RUN_ID}" \
  --mount "type=volume,source=${VOLUME_NAME},target=/data" \
  --entrypoint /bin/sh \
  "${IMAGE_NAME}" \
  -c 'printf "%s\n" "$1" > /data/result.txt' verify "${VOLUME_PAYLOAD}" >/dev/null
owns_volume_writer=1
docker container start --attach "${VOLUME_WRITER}" >/dev/null
[[ "$(docker container inspect --format '{{.State.ExitCode}}' "${VOLUME_WRITER}")" == '0' ]] \
  || fail "volume writer container failed"
docker container rm "${VOLUME_WRITER}" >/dev/null
owns_volume_writer=0

docker container create \
  --name "${VOLUME_READER}" \
  --label "${RESOURCE_LABEL}=${RUN_ID}" \
  --mount "type=volume,source=${VOLUME_NAME},target=/data,readonly" \
  --entrypoint /bin/sh \
  "${IMAGE_NAME}" \
  -c 'cat /data/result.txt' >/dev/null
owns_volume_reader=1
persisted_value="$(docker container start --attach "${VOLUME_READER}")"
[[ "${persisted_value}" == "${VOLUME_PAYLOAD}" ]] \
  || fail "named volume data did not persist across containers"
log "named-volume persistence confirmed"

log "all checks passed; exiting with status 0"
exit 0
