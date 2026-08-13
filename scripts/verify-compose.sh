#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(CDPATH='' cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly LOG_FILE="${PROJECT_ROOT}/logs/compose-verification.txt"
readonly SINGLE_FILE="compose.single.yml"
readonly MULTI_FILE="docker-compose.yml"
readonly SINGLE_PROJECT="ia-codyssey-single-check"
readonly MULTI_PROJECT="ia-codyssey-multi-check"
readonly SINGLE_HOST_PORT="18090"
readonly MULTI_HOST_PORT="18091"
readonly INTERNAL_PORT="8181"
readonly TEST_MODE="bonus-verified"

log() {
  printf '%s\n' "$*" | tee -a "${LOG_FILE}"
}

run() {
  log "$ $*"
  "$@" 2>&1 | tee -a "${LOG_FILE}"
}

cleanup() {
  docker compose -p "${SINGLE_PROJECT}" -f "${SINGLE_FILE}" down --remove-orphans >/dev/null 2>&1 || true
  COMPOSE_HOST_PORT="${MULTI_HOST_PORT}" SERVER_PORT="${INTERNAL_PORT}" APP_MODE="${TEST_MODE}" \
    docker compose -p "${MULTI_PROJECT}" -f "${MULTI_FILE}" down --remove-orphans >/dev/null 2>&1 || true
}

wait_for_http() {
  local url=$1
  local attempts=30

  until curl --fail --silent --show-error "${url}" >/dev/null; do
    attempts=$((attempts - 1))
    if (( attempts == 0 )); then
      return 1
    fi
    sleep 1
  done
}

trap cleanup EXIT INT TERM
cd "${PROJECT_ROOT}"
: > "${LOG_FILE}"

log "[compose] START UTC: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
run docker compose version

log ""
log "## 1. Single-service Compose"
export COMPOSE_HOST_PORT="${SINGLE_HOST_PORT}"
export SERVER_PORT="8080"
export APP_MODE="single-verified"
run docker compose -p "${SINGLE_PROJECT}" -f "${SINGLE_FILE}" config --services
run docker compose -p "${SINGLE_PROJECT}" -f "${SINGLE_FILE}" up -d --build
wait_for_http "http://127.0.0.1:${SINGLE_HOST_PORT}/"
run docker compose -p "${SINGLE_PROJECT}" -f "${SINGLE_FILE}" ps
run curl --fail --silent --show-error --include "http://127.0.0.1:${SINGLE_HOST_PORT}/"
run docker compose -p "${SINGLE_PROJECT}" -f "${SINGLE_FILE}" logs --no-color --tail=20 web
run docker compose -p "${SINGLE_PROJECT}" -f "${SINGLE_FILE}" down --remove-orphans

log ""
log "## 2. Multi-service Compose and environment injection"
export COMPOSE_HOST_PORT="${MULTI_HOST_PORT}"
export SERVER_PORT="${INTERNAL_PORT}"
export APP_MODE="${TEST_MODE}"
run docker compose -p "${MULTI_PROJECT}" -f "${MULTI_FILE}" config --services
log "$ compose environment (selected non-secret values)"
log "APP_MODE=${APP_MODE}"
log "SERVER_PORT=${SERVER_PORT}"
log "COMPOSE_HOST_PORT=${COMPOSE_HOST_PORT}"
run docker compose -p "${MULTI_PROJECT}" -f "${MULTI_FILE}" up -d --build
wait_for_http "http://127.0.0.1:${MULTI_HOST_PORT}/"

probe_reachable=0
for _ in $(seq 1 30); do
  if docker compose -p "${MULTI_PROJECT}" -f "${MULTI_FILE}" logs --no-color probe 2>&1 \
      | grep -q "web:${INTERNAL_PORT} reachable"; then
    probe_reachable=1
    break
  fi
  sleep 1
done

if (( probe_reachable == 0 )); then
  log "[compose] FAIL probe could not reach web by service name"
  exit 1
fi

run docker compose -p "${MULTI_PROJECT}" -f "${MULTI_FILE}" ps
run curl --fail --silent --show-error --include "http://127.0.0.1:${MULTI_HOST_PORT}/"
run docker compose -p "${MULTI_PROJECT}" -f "${MULTI_FILE}" exec -T probe \
  wget -qO- "http://web:${INTERNAL_PORT}/"
run docker compose -p "${MULTI_PROJECT}" -f "${MULTI_FILE}" logs --no-color --tail=30
run docker compose -p "${MULTI_PROJECT}" -f "${MULTI_FILE}" down --remove-orphans

log ""
log "[compose] PASS single service, multi service, service discovery, operations, and environment injection"
log "[compose] END UTC: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
