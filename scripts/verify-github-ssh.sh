#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(CDPATH='' cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly LOG_FILE="${PROJECT_ROOT}/logs/github-ssh-verification.txt"
readonly KEY_FILE="${HOME}/.ssh/id_ed25519_github_codyssey"
readonly PUBLIC_KEY_FILE="${KEY_FILE}.pub"

log() {
  printf '%s\n' "$*" | tee -a "${LOG_FILE}"
}

run() {
  log "$ $*"
  "$@" 2>&1 | tee -a "${LOG_FILE}"
}

cd "${PROJECT_ROOT}"
: > "${LOG_FILE}"

log "[github-ssh] START UTC: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

if [[ ! -f "${KEY_FILE}" || ! -f "${PUBLIC_KEY_FILE}" ]]; then
  log "[github-ssh] FAIL dedicated key pair is missing"
  exit 1
fi

log '$ ssh-keygen -lf ~/.ssh/id_ed25519_github_codyssey.pub'
ssh-keygen -lf "${PUBLIC_KEY_FILE}" | tee -a "${LOG_FILE}"

log '$ stat permissions for the dedicated private/public key'
stat -f 'private=%OLp public=%N' "${KEY_FILE}" \
  | sed 's#public=.*#public-key-file#' \
  | tee -a "${LOG_FILE}"
stat -f 'public=%OLp' "${PUBLIC_KEY_FILE}" | tee -a "${LOG_FILE}"

log '$ ssh -T git@github.com'
set +e
ssh_output="$(ssh -T -o BatchMode=yes -o IdentitiesOnly=yes -i "${KEY_FILE}" git@github.com 2>&1)"
ssh_status=$?
set -e
printf '%s\n' "${ssh_output}" | tee -a "${LOG_FILE}"

if [[ ${ssh_status} -ne 1 || "${ssh_output}" != *"successfully authenticated"* ]]; then
  log "[github-ssh] FAIL GitHub authentication response was unexpected (exit=${ssh_status})"
  exit 1
fi
log "[github-ssh] PASS GitHub SSH authentication (GitHub success response uses exit 1)"

run git remote -v
run git ls-remote origin refs/heads/main
run git push --dry-run origin main

log "[github-ssh] PASS SSH remote read and push permission checks"
log "[github-ssh] END UTC: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
