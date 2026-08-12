#!/bin/bash

# Generate fresh, timestamped evidence for basic terminal commands without
# creating or changing practice files in the repository. This script targets
# the Bash 3.2 shipped with macOS.

set -u
set -o pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
umask 077

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P) || exit 1
REPOSITORY_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P) || exit 1
LOG_FILE="$REPOSITORY_DIR/logs/terminal-practice-timestamped.txt"

# Use a fixed system temporary parent so an inherited TMPDIR cannot redirect
# practice operations into the repository.
TEMP_PARENT="/tmp"
TEMP_PREFIX="$TEMP_PARENT/ia-codyssey-terminal-practice."
TEMP_TEMPLATE="${TEMP_PREFIX}XXXXXX"

temp_root=""
temp_root_physical=""
host_user=$(id -un 2>/dev/null || printf '%s' "")
host_home=${HOME:-}
cleanup_started=0

utc_now() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

append_line() {
  printf '%s\n' "$1" >> "$LOG_FILE"
}

# Replace literal host-specific values without treating them as regular
# expressions. The evidence remains useful while disclosing neither the user
# account nor the randomly generated absolute directory.
mask_stream() {
  awk \
    -v logical_root="$temp_root" \
    -v physical_root="$temp_root_physical" \
    -v temp_parent="$TEMP_PARENT" \
    -v user_home="$host_home" \
    -v user_name="$host_user" '
    function replace_literal(text, needle, replacement, position, result) {
      if (needle == "") {
        return text
      }
      result = ""
      while ((position = index(text, needle)) != 0) {
        result = result substr(text, 1, position - 1) replacement
        text = substr(text, position + length(needle))
      }
      return result text
    }
    {
      text = $0
      text = replace_literal(text, physical_root, "<TEMP_ROOT>")
      text = replace_literal(text, logical_root, "<TEMP_ROOT>")
      text = replace_literal(text, temp_parent, "<TEMP_PARENT>")
      text = replace_literal(text, user_home, "<USER_HOME>")
      text = replace_literal(text, user_name, "<USER>")
      print text
    }
  '
}

append_masked() {
  printf '%s\n' "$1" | mask_stream >> "$LOG_FILE"
}

record_result() {
  result_output=$1
  result_status=$2
  result_after=$3
  result_name=$4

  if [ -n "$result_output" ]; then
    append_masked "$result_output"
  else
    append_line "(no output)"
  fi
  append_line "[$result_after] AFTER $result_name (exit=$result_status)"
  append_line ""
}

run_logged() {
  command_name=$1
  command_display=$2
  shift 2

  command_before=$(utc_now)
  append_line "[$command_before] BEFORE $command_name"
  append_masked "\$ $command_display"
  command_output=$("$@" 2>&1)
  command_status=$?
  command_after=$(utc_now)
  record_result "$command_output" "$command_status" "$command_after" "$command_name"
  return "$command_status"
}

# A cd must run in the current shell, so it cannot use run_logged's command
# substitution. Successful cd produces no output; failures are reported in a
# sanitized form before the exit trap removes the temporary directory.
run_cd_logged() {
  command_name=$1
  command_display=$2
  command_target=$3

  command_before=$(utc_now)
  append_line "[$command_before] BEFORE $command_name"
  append_masked "\$ $command_display"
  if CDPATH= cd -- "$command_target" 2>/dev/null; then
    command_status=0
    command_output=""
  else
    command_status=$?
    command_output="cd: unable to enter the requested directory"
  fi
  command_after=$(utc_now)
  record_result "$command_output" "$command_status" "$command_after" "$command_name"
  return "$command_status"
}

cleanup() {
  incoming_status=$?
  final_status=$incoming_status

  # Prevent a signal received during cleanup from interrupting removal.
  trap - EXIT
  trap '' HUP INT TERM

  if [ "$cleanup_started" -ne 0 ]; then
    exit 1
  fi
  cleanup_started=1

  if [ -n "$temp_root" ]; then
    cleanup_leaf=${temp_root#"$TEMP_PREFIX"}
    case "$temp_root:$cleanup_leaf" in
      "$TEMP_PREFIX"*:?*/*) cleanup_path_is_safe=0 ;;
      "$TEMP_PREFIX"*:?*) cleanup_path_is_safe=1 ;;
      *) cleanup_path_is_safe=0 ;;
    esac

    if [ "$cleanup_path_is_safe" -eq 1 ] && [ "$temp_root" != "/" ]; then
      cleanup_before=$(utc_now)
      append_line "[$cleanup_before] BEFORE leave temporary workspace"
      append_line "\$ cd /"
      if CDPATH= cd -- / 2>/dev/null; then
        cleanup_cd_status=0
        cleanup_cd_output=""
      else
        cleanup_cd_status=$?
        cleanup_cd_output="cd: unable to enter cleanup directory"
      fi
      cleanup_after=$(utc_now)
      record_result "$cleanup_cd_output" "$cleanup_cd_status" "$cleanup_after" "leave temporary workspace"

      remove_before=$(utc_now)
      append_line "[$remove_before] BEFORE remove temporary workspace"
      append_line "\$ rm -rf -- <TEMP_ROOT>"
      remove_output=$(/bin/rm -rf -- "$temp_root" 2>&1)
      remove_status=$?
      remove_after=$(utc_now)
      record_result "$remove_output" "$remove_status" "$remove_after" "remove temporary workspace"

      verify_before=$(utc_now)
      append_line "[$verify_before] BEFORE verify temporary workspace absence"
      append_line "\$ test ! -e <TEMP_ROOT>"
      if [ ! -e "$temp_root" ]; then
        verify_status=0
        verify_summary="PASS: temporary workspace is absent"
      else
        verify_status=1
        verify_summary="FAIL: temporary workspace still exists"
      fi
      verify_after=$(utc_now)
      record_result "" "$verify_status" "$verify_after" "verify temporary workspace absence"
      append_line "$verify_summary"
      append_line ""

      if [ "$cleanup_cd_status" -ne 0 ] || [ "$remove_status" -ne 0 ] || [ "$verify_status" -ne 0 ]; then
        final_status=1
      fi
    else
      unsafe_before=$(utc_now)
      append_line "[$unsafe_before] BEFORE validate cleanup target"
      append_line "\$ validate-generated-temp-path <TEMP_ROOT>"
      unsafe_after=$(utc_now)
      record_result "FAIL: refused an unexpected cleanup target" "1" "$unsafe_after" "validate cleanup target"
      final_status=1
    fi
  else
    no_temp_time=$(utc_now)
    append_line "[$no_temp_time] CLEANUP: no temporary workspace was created"
    append_line ""
  fi

  finish_time=$(utc_now)
  append_line "[$finish_time] FINISH terminal practice verification (exit=$final_status)"
  exit "$final_status"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# The log is the sole repository artifact written by this script.
: > "$LOG_FILE" || exit 1
append_line "# Fresh isolated terminal practice evidence"
append_line "# Timestamps use UTC (Z)."
append_line "# Redactions: <USER>, <USER_HOME>, <TEMP_PARENT>, and <TEMP_ROOT>."
append_line "# All practice files are created under <TEMP_ROOT> and removed on exit."
append_line ""

create_before=$(utc_now)
append_line "[$create_before] BEFORE create temporary workspace"
append_line "\$ mktemp -d <TEMP_PARENT>/ia-codyssey-terminal-practice.XXXXXX"
create_output=$(mktemp -d "$TEMP_TEMPLATE" 2>&1)
create_status=$?
if [ "$create_status" -eq 0 ]; then
  temp_root=$create_output
  temp_root_physical=$(CDPATH= cd -- "$temp_root" && pwd -P) || temp_root_physical=$temp_root
fi
create_after=$(utc_now)
record_result "$create_output" "$create_status" "$create_after" "create temporary workspace"
[ "$create_status" -eq 0 ] || exit 1

run_cd_logged "enter temporary workspace" "cd <TEMP_ROOT>" "$temp_root" || exit 1
run_logged "print temporary working directory" "pwd" pwd || exit 1
run_logged "create practice directory" "mkdir cli-demo" mkdir cli-demo || exit 1
run_cd_logged "enter practice directory" "cd cli-demo" "cli-demo" || exit 1
run_logged "print practice working directory" "pwd" pwd || exit 1

run_logged \
  "write text file" \
  "printf '%s\\n' 'Terminal CLI practice' > original.txt" \
  /bin/bash -c "printf '%s\\n' 'Terminal CLI practice' > original.txt" || exit 1
run_logged "read text file" "cat original.txt" cat original.txt || exit 1
run_logged "create empty file" "touch empty-file.txt" touch empty-file.txt || exit 1
run_logged \
  "create hidden file" \
  "printf '%s\\n' 'Hidden CLI evidence' > .hidden-evidence" \
  /bin/bash -c "printf '%s\\n' 'Hidden CLI evidence' > .hidden-evidence" || exit 1
run_logged "list directory including hidden file" "ls -la" ls -la || exit 1

run_logged "copy file" "cp original.txt copied.txt" cp original.txt copied.txt || exit 1
run_logged "rename copied file" "mv copied.txt renamed.txt" mv copied.txt renamed.txt || exit 1
run_logged "list after rename" "ls -la" ls -la || exit 1
run_logged "remove renamed file" "rm renamed.txt" rm renamed.txt || exit 1
run_logged "verify removed file is absent" "test ! -e renamed.txt" test ! -e renamed.txt || exit 1
run_logged "final directory listing" "ls -la" ls -la || exit 1

exit 0
