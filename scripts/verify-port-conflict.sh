#!/usr/bin/env bash

# Reproduce a Docker host-port collision without touching pre-existing resources.
# The first nginx container remains running while the failed container is
# recreated on a different loopback-only port.

set -Eeuo pipefail

readonly SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(CDPATH='' cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly LOG_FILE="${PROJECT_ROOT}/logs/port-conflict.txt"
readonly BASE_IMAGE="${BASE_IMAGE:-nginx:alpine@sha256:4a73073bd557c65b759505da037898b61f1be6cbcc3c2c3aeac22d2a470c1752}"
readonly RUN_ID="$(date +%s)-$$-${RANDOM}"
readonly RESOURCE_LABEL="io.codyssey.port-conflict.run"
readonly OWNER_NAME="ia-port-owner-${RUN_ID}"
readonly RETRY_NAME="ia-port-retry-${RUN_ID}"
readonly DEMO_IMAGE="ia-port-conflict-demo:${RUN_ID}"

DEMO_IMAGE_ID=""
TEMP_DIR=""
HOST_PORT=""
ALTERNATE_PORT=""

log_command() {
  printf '$'
  printf ' %q' "$@"
  printf '\n'
}

container_exists() {
  docker container inspect "$1" >/dev/null 2>&1
}

remove_owned_container() {
  local name="$1"
  local force="${2:-false}"
  local actual_label=""

  if ! container_exists "$name"; then
    printf '[cleanup] container already absent: %s\n' "$name"
    return 0
  fi

  actual_label="$(docker container inspect \
    --format '{{ index .Config.Labels "io.codyssey.port-conflict.run" }}' \
    "$name" 2>/dev/null || true)"

  if [[ "$actual_label" != "$RUN_ID" ]]; then
    printf '[cleanup] REFUSED: %s is not owned by run %s (label=%s)\n' \
      "$name" "$RUN_ID" "${actual_label:-missing}"
    return 1
  fi

  if [[ "$force" == "true" ]]; then
    log_command docker rm -f "$name"
    docker rm -f "$name"
  else
    log_command docker rm "$name"
    docker rm "$name"
  fi
}

cleanup() {
  local main_status=$?
  local cleanup_status=0
  local final_status="$main_status"
  local current_image_id=""

  trap - EXIT INT TERM
  set +e

  printf '\n=== Cleanup (owned resources only) ===\n'
  remove_owned_container "$RETRY_NAME" true || cleanup_status=1
  remove_owned_container "$OWNER_NAME" true || cleanup_status=1

  if [[ -n "$DEMO_IMAGE_ID" ]] && docker image inspect "$DEMO_IMAGE" >/dev/null 2>&1; then
    current_image_id="$(docker image inspect --format '{{.Id}}' "$DEMO_IMAGE" 2>/dev/null)"
    if [[ "$current_image_id" == "$DEMO_IMAGE_ID" ]]; then
      log_command docker image rm "$DEMO_IMAGE"
      docker image rm "$DEMO_IMAGE" || cleanup_status=1
    else
      printf '[cleanup] REFUSED: image tag %s no longer points to the image created by this run\n' \
        "$DEMO_IMAGE"
      cleanup_status=1
    fi
  else
    printf '[cleanup] image tag already absent: %s\n' "$DEMO_IMAGE"
  fi

  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    rm -rf -- "$TEMP_DIR"
  fi

  if (( main_status == 0 && cleanup_status != 0 )); then
    final_status=1
  fi

  printf '[cleanup] main status=%d cleanup status=%d final exit=%d\n' \
    "$main_status" "$cleanup_status" "$final_status"
  exit "$final_status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'ERROR: required command is unavailable: %s\n' "$1" >&2
    exit 1
  fi
}

choose_free_loopback_port() {
  python3 - <<'PY'
import socket

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
}

check_loopback_port_available() {
  local port="$1"

  python3 - "$port" <<'PY'
import socket
import sys

port = int(sys.argv[1])
with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.bind(("127.0.0.1", port))
    except OSError as exc:
        print(f"UNAVAILABLE: 127.0.0.1:{port}: {exc}")
        raise SystemExit(1)
print(f"AVAILABLE: 127.0.0.1:{port} accepted a test bind")
PY
}

wait_for_http_200() {
  local port="$1"
  local attempt=""
  local code=""

  for attempt in {1..15}; do
    code="$(curl --silent --show-error --output /dev/null \
      --write-out '%{http_code}' --max-time 2 \
      "http://127.0.0.1:${port}/" 2>/dev/null || true)"
    if [[ "$code" == "200" ]]; then
      printf 'HTTP status from http://127.0.0.1:%s/ = %s (attempt %s)\n' \
        "$port" "$code" "$attempt"
      return 0
    fi
    sleep 1
  done

  printf 'ERROR: expected HTTP 200 from 127.0.0.1:%s; last status=%s\n' \
    "$port" "${code:-curl-failed}" >&2
  return 1
}

require_command docker
require_command python3
require_command curl
require_command tee
require_command date
[[ -d "${PROJECT_ROOT}/logs" ]] || {
  printf 'ERROR: logs directory is unavailable: %s\n' "${PROJECT_ROOT}/logs" >&2
  exit 1
}

exec > >(tee "$LOG_FILE") 2>&1

printf '=== Safe Docker port-conflict diagnostic ===\n'
printf 'UTC start: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
printf 'run id: %s\n' "$RUN_ID"
printf 'owner container: %s\n' "$OWNER_NAME"
printf 'retry container: %s\n' "$RETRY_NAME"
printf 'run-owned image tag: %s\n' "$DEMO_IMAGE"
printf 'pinned base image: %s\n' "$BASE_IMAGE"

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ia-port-conflict.XXXXXX")"

printf '\n=== Docker engine check ===\n'
log_command docker version --format 'Client={{.Client.Version}} Server={{.Server.Version}}'
docker version --format 'Client={{.Client.Version}} Server={{.Server.Version}}'
log_command docker info --format 'Engine={{.ServerVersion}} OS={{.OperatingSystem}}'
docker info --format 'Engine={{.ServerVersion}} OS={{.OperatingSystem}}'

if ! docker image inspect "$BASE_IMAGE" >/dev/null 2>&1; then
  printf '[setup] base image is not local; pulling %s\n' "$BASE_IMAGE"
  log_command docker pull "$BASE_IMAGE"
  docker pull "$BASE_IMAGE"
else
  printf '[setup] base image already local: %s\n' "$BASE_IMAGE"
fi

if docker image inspect "$DEMO_IMAGE" >/dev/null 2>&1; then
  printf 'ERROR: supposedly unique image tag already exists: %s\n' "$DEMO_IMAGE" >&2
  exit 1
fi

log_command docker image tag "$BASE_IMAGE" "$DEMO_IMAGE"
docker image tag "$BASE_IMAGE" "$DEMO_IMAGE"
DEMO_IMAGE_ID="$(docker image inspect --format '{{.Id}}' "$DEMO_IMAGE")"
printf '[setup] tagged shared base as run-owned alias: %s -> %s\n' \
  "$DEMO_IMAGE" "$DEMO_IMAGE_ID"

HOST_PORT="$(choose_free_loopback_port)"
printf '\n=== Preflight: primary loopback port ===\n'
printf 'selected host port: %s\n' "$HOST_PORT"
check_loopback_port_available "$HOST_PORT"

printf '\n=== Start the port owner ===\n'
log_command docker run -d --name "$OWNER_NAME" \
  --label "${RESOURCE_LABEL}=${RUN_ID}" \
  -p "127.0.0.1:${HOST_PORT}:80" "$DEMO_IMAGE"
docker run -d --name "$OWNER_NAME" \
  --label "${RESOURCE_LABEL}=${RUN_ID}" \
  -p "127.0.0.1:${HOST_PORT}:80" "$DEMO_IMAGE"

log_command docker ps --filter "name=^/${OWNER_NAME}$" \
  --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
docker ps --filter "name=^/${OWNER_NAME}$" \
  --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

log_command docker port "$OWNER_NAME" 80/tcp
docker port "$OWNER_NAME" 80/tcp

printf '\n=== Identify the listener ===\n'
if command -v lsof >/dev/null 2>&1; then
  log_command lsof -nP -iTCP:"$HOST_PORT" -sTCP:LISTEN
  set +e
  LSOF_OUTPUT="$(lsof -nP -iTCP:"$HOST_PORT" -sTCP:LISTEN 2>&1)"
  LSOF_STATUS=$?
  set -e
  if [[ -n "$LSOF_OUTPUT" ]]; then
    if [[ -n "${USER:-}" ]]; then
      LSOF_OUTPUT="${LSOF_OUTPUT//"$USER"/[USER]}"
    fi
    printf '%s\n' "$LSOF_OUTPUT"
  else
    printf '[inspect] lsof returned no visible host process (common with VM-backed Docker networking)\n'
  fi
  printf '[inspect] lsof exit code: %d\n' "$LSOF_STATUS"
else
  printf '[inspect] lsof unavailable; docker ps and docker port are authoritative below\n'
fi

log_command docker ps --filter "publish=${HOST_PORT}" \
  --format 'table {{.Names}}\t{{.Image}}\t{{.Ports}}'
docker ps --filter "publish=${HOST_PORT}" \
  --format 'table {{.Names}}\t{{.Image}}\t{{.Ports}}'
log_command docker port "$OWNER_NAME"
docker port "$OWNER_NAME"

printf '\n=== Reproduce the collision on the same port ===\n'
log_command docker run -d --name "$RETRY_NAME" \
  --label "${RESOURCE_LABEL}=${RUN_ID}" \
  -p "127.0.0.1:${HOST_PORT}:80" "$DEMO_IMAGE"
set +e
CONFLICT_OUTPUT="$(docker run -d --name "$RETRY_NAME" \
  --label "${RESOURCE_LABEL}=${RUN_ID}" \
  -p "127.0.0.1:${HOST_PORT}:80" "$DEMO_IMAGE" 2>&1)"
CONFLICT_STATUS=$?
set -e
printf '%s\n' "$CONFLICT_OUTPUT"
printf '[expected failure] docker run exit code: %d\n' "$CONFLICT_STATUS"

if (( CONFLICT_STATUS == 0 )); then
  printf 'ERROR: the duplicate host-port publication unexpectedly succeeded\n' >&2
  exit 1
fi

log_command docker ps -a --filter "name=^/${RETRY_NAME}$" \
  --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
docker ps -a --filter "name=^/${RETRY_NAME}$" \
  --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

printf '\n=== Resolve by changing the retry port (owner stays running) ===\n'
OWNER_RUNNING="$(docker container inspect --format '{{.State.Running}}' "$OWNER_NAME")"
printf 'original owner running before retry: %s\n' "$OWNER_RUNNING"
if [[ "$OWNER_RUNNING" != "true" ]]; then
  printf 'ERROR: original port owner is no longer running\n' >&2
  exit 1
fi

# A failed docker run can leave a Created container. Remove only that run-owned
# failed attempt so the same logical retry can be recreated with a new port.
remove_owned_container "$RETRY_NAME" false

ALTERNATE_PORT="$(choose_free_loopback_port)"
while [[ "$ALTERNATE_PORT" == "$HOST_PORT" ]]; do
  ALTERNATE_PORT="$(choose_free_loopback_port)"
done
printf 'selected alternate host port: %s (primary remains %s)\n' \
  "$ALTERNATE_PORT" "$HOST_PORT"
check_loopback_port_available "$ALTERNATE_PORT"

log_command docker run -d --name "$RETRY_NAME" \
  --label "${RESOURCE_LABEL}=${RUN_ID}" \
  -p "127.0.0.1:${ALTERNATE_PORT}:80" "$DEMO_IMAGE"
docker run -d --name "$RETRY_NAME" \
  --label "${RESOURCE_LABEL}=${RUN_ID}" \
  -p "127.0.0.1:${ALTERNATE_PORT}:80" "$DEMO_IMAGE"

log_command docker ps --filter "label=${RESOURCE_LABEL}=${RUN_ID}" \
  --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
docker ps --filter "label=${RESOURCE_LABEL}=${RUN_ID}" \
  --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
log_command docker port "$RETRY_NAME" 80/tcp
docker port "$RETRY_NAME" 80/tcp

printf '\n=== HTTP verification while both containers run ===\n'
log_command curl --silent --output /dev/null --write-out '%{http_code}' \
  "http://127.0.0.1:${HOST_PORT}/"
wait_for_http_200 "$HOST_PORT"
log_command curl --silent --output /dev/null --write-out '%{http_code}' \
  "http://127.0.0.1:${ALTERNATE_PORT}/"
wait_for_http_200 "$ALTERNATE_PORT"

printf '\nRESULT: PASS - collision reproduced; alternate loopback port returned HTTP 200.\n'
printf 'The original owner was not stopped to resolve the conflict.\n'
exit 0
