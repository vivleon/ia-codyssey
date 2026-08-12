#!/usr/bin/env bash

# Validate the repository layout without changing repository contents. The only
# file this script writes is logs/project-structure.txt.

set -u
set -o pipefail

readonly SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(CDPATH='' cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly LOG_RELATIVE_PATH='logs/project-structure.txt'
readonly LOG_FILE="${PROJECT_ROOT}/${LOG_RELATIVE_PATH}"
readonly README_FILE="${PROJECT_ROOT}/README.md"
readonly STARTED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
readonly ACCOUNT_NAME="${USER:-${LOGNAME:-}}"

FAILURES=0
REQUIRED_CHECKS=0
LOCAL_LINK_OCCURRENCES=0
UNIQUE_LOCAL_LINKS=0
EXTERNAL_LINKS_IGNORED=0
ANCHOR_LINKS_IGNORED=0
GENERATED_LOG_LINKS_SKIPPED=0
# Bash 3.2 treats an empty-array expansion as unset under `set -u`. A harmless
# sentinel keeps the array safe while real targets are counted separately.
SEEN_LINK_TARGETS=('')

mask_text() {
  local value=$1

  # Output is designed to contain only repository-relative paths. These
  # substitutions are a final safeguard if an account name reaches a message.
  if [[ -n "${HOME:-}" ]]; then
    value=${value//"${HOME}"/'[HOME]'}
  fi
  if [[ -n "${ACCOUNT_NAME}" ]]; then
    value=${value//"${ACCOUNT_NAME}"/'[USER]'}
  fi

  printf '%s' "${value}"
}

emit() {
  local safe_line

  safe_line="$(mask_text "$*")"
  printf '%s\n' "${safe_line}"
  printf '%s\n' "${safe_line}" >> "${LOG_FILE}"
}

print_unlogged_boundary() {
  local label=$1
  local timestamp=$2

  printf '[project-structure] %s UTC: %s\n' "${label}" "${timestamp}"
}

# Refuse redirections that could make the one permitted write affect a path
# outside the repository.
if [[ ! -d "${PROJECT_ROOT}/logs" || -L "${PROJECT_ROOT}/logs" ]]; then
  print_unlogged_boundary 'START' "${STARTED_AT}"
  printf '[project-structure] FAIL required directory missing or unsafe: logs/\n'
  print_unlogged_boundary 'END' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  exit 1
fi

if [[ -L "${LOG_FILE}" || ( -e "${LOG_FILE}" && ! -f "${LOG_FILE}" ) ]]; then
  print_unlogged_boundary 'START' "${STARTED_AT}"
  printf '[project-structure] FAIL generated log target is not a regular file: %s\n' \
    "${LOG_RELATIVE_PATH}"
  print_unlogged_boundary 'END' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  exit 1
fi

: > "${LOG_FILE}" || {
  print_unlogged_boundary 'START' "${STARTED_AT}"
  printf '[project-structure] FAIL cannot write generated log: %s\n' \
    "${LOG_RELATIVE_PATH}"
  print_unlogged_boundary 'END' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  exit 1
}

emit "[project-structure] START UTC: ${STARTED_AT}"
emit '[project-structure] INFO validation is read-only except for its generated log'
emit "[project-structure] INFO generated log excluded from validation: ${LOG_RELATIVE_PATH}"

check_directory() {
  local relative_path=$1

  REQUIRED_CHECKS=$((REQUIRED_CHECKS + 1))
  if [[ -d "${PROJECT_ROOT}/${relative_path}" && ! -L "${PROJECT_ROOT}/${relative_path}" ]]; then
    emit "[project-structure] PASS directory: ${relative_path}/"
  else
    emit "[project-structure] FAIL required directory missing or unsafe: ${relative_path}/"
    FAILURES=$((FAILURES + 1))
  fi
}

check_file() {
  local relative_path=$1

  REQUIRED_CHECKS=$((REQUIRED_CHECKS + 1))
  if [[ -f "${PROJECT_ROOT}/${relative_path}" && ! -L "${PROJECT_ROOT}/${relative_path}" ]]; then
    emit "[project-structure] PASS file: ${relative_path}"
  else
    emit "[project-structure] FAIL required file missing or unsafe: ${relative_path}"
    FAILURES=$((FAILURES + 1))
  fi
}

for required_directory in app bind-app logs screenshots scripts; do
  check_directory "${required_directory}"
done

for required_file in Dockerfile README.md app/index.html bind-app/index.html; do
  check_file "${required_file}"
done

# Extract inline Markdown destinations, image destinations, and reference
# definitions. Fenced and inline code are removed first so examples are not
# mistaken for links. The scanner accepts balanced parentheses in destinations.
extract_markdown_destinations() {
  perl -0777 -e '
    use strict;
    use warnings;

    my $text = do { local $/; <STDIN> };
    my @clean_lines;
    my $in_fence = 0;
    my $fence_character = q{};
    my $fence_length = 0;

    for my $line (split /(?<=\n)/, $text) {
      if (!$in_fence && $line =~ /^ {0,3}(`{3,}|~{3,})/) {
        my $marker = $1;
        $fence_character = substr $marker, 0, 1;
        $fence_length = length $marker;
        $in_fence = 1;
        next;
      }

      if ($in_fence) {
        if ($line =~ /^ {0,3}([`~]{3,})[ \t]*(?:\n|\z)/) {
          my $marker = $1;
          if (substr($marker, 0, 1) eq $fence_character
              && length($marker) >= $fence_length) {
            $in_fence = 0;
          }
        }
        next;
      }

      $line =~ s/(`+).*?\1//g;
      push @clean_lines, $line;
    }

    my $clean = join q{}, @clean_lines;

    # Reference-style definitions: [name]: destination
    for my $line (split /\n/, $clean) {
      if ($line =~ /^ {0,3}\[[^]]+\]:[ \t]*(?:<([^>]+)>|([^ \t]+))/) {
        print((defined $1 ? $1 : $2), "\n");
      }
    }

    sub is_escaped {
      my ($source, $index) = @_;
      my $slashes = 0;
      for (my $cursor = $index - 1;
           $cursor >= 0 && substr($source, $cursor, 1) eq q{\\};
           $cursor--) {
        $slashes++;
      }
      return $slashes % 2;
    }

    my $search_from = 0;
    while (1) {
      my $close_bracket = index $clean, q{](}, $search_from;
      last if $close_bracket < 0;
      $search_from = $close_bracket + 2;
      next if is_escaped($clean, $close_bracket);

      my $open_bracket = rindex substr($clean, 0, $close_bracket), q{[};
      next if $open_bracket < 0 || is_escaped($clean, $open_bracket);

      my $cursor = $close_bracket + 2;
      my $length = length $clean;
      $cursor++ while $cursor < $length
        && substr($clean, $cursor, 1) =~ /[ \t\r\n]/;

      my $destination = q{};
      if ($cursor < $length && substr($clean, $cursor, 1) eq q{<}) {
        $cursor++;
        while ($cursor < $length) {
          my $character = substr $clean, $cursor, 1;
          last if $character eq q{>} && !is_escaped($clean, $cursor);
          if ($character eq q{\\} && $cursor + 1 < $length) {
            $cursor++;
            $character = substr $clean, $cursor, 1;
          }
          $destination .= $character;
          $cursor++;
        }
      } else {
        my $parenthesis_depth = 0;
        while ($cursor < $length) {
          my $character = substr $clean, $cursor, 1;
          if ($character eq q{\\} && $cursor + 1 < $length) {
            $cursor++;
            $destination .= substr($clean, $cursor, 1);
            $cursor++;
            next;
          }
          if ($character eq q{(}) {
            $parenthesis_depth++;
          } elsif ($character eq q{)}) {
            last if $parenthesis_depth == 0;
            $parenthesis_depth--;
          } elsif ($character =~ /[ \t\r\n]/ && $parenthesis_depth == 0) {
            last;
          }
          $destination .= $character;
          $cursor++;
        }
      }

      print $destination, "\n" if length $destination;
    }
  '
}

is_external_url() {
  local destination=$1

  case "${destination}" in
    //*) return 0 ;;
  esac

  LC_ALL=C grep -Eq '^[A-Za-z][A-Za-z0-9+.-]*:' <<EOF
${destination}
EOF
}

decode_url_path() {
  perl -pe 's/%([0-9A-Fa-f]{2})/chr hex $1/ge'
}

normalize_relative_path() {
  local input_path=$1
  local component
  local index
  local normalized=''
  local old_ifs=${IFS}
  local -a components=()
  local -a path_stack=()

  [[ -n "${input_path}" && "${input_path}" != /* ]] || return 1

  IFS='/' read -r -a components <<< "${input_path}"
  IFS=${old_ifs}

  for component in "${components[@]}"; do
    case "${component}" in
      ''|.)
        ;;
      ..)
        if (( ${#path_stack[@]} == 0 )); then
          return 1
        fi
        unset "path_stack[$((${#path_stack[@]} - 1))]"
        ;;
      *)
        path_stack[${#path_stack[@]}]=${component}
        ;;
    esac
  done

  (( ${#path_stack[@]} > 0 )) || return 1
  for ((index = 0; index < ${#path_stack[@]}; index++)); do
    if [[ -n "${normalized}" ]]; then
      normalized="${normalized}/"
    fi
    normalized="${normalized}${path_stack[index]}"
  done

  printf '%s\n' "${normalized}"
}

link_was_seen() {
  local candidate=$1
  local seen

  for seen in "${SEEN_LINK_TARGETS[@]}"; do
    [[ "${seen}" == "${candidate}" ]] && return 0
  done
  return 1
}

if [[ -f "${README_FILE}" ]]; then
  if ! command -v perl >/dev/null 2>&1 || ! command -v grep >/dev/null 2>&1; then
    emit '[project-structure] FAIL Markdown link validation requires standard perl and grep commands'
    FAILURES=$((FAILURES + 1))
  else
    MARKDOWN_DESTINATIONS="$(extract_markdown_destinations < "${README_FILE}" 2>/dev/null)"
    PARSER_STATUS=$?

    if (( PARSER_STATUS != 0 )); then
      emit '[project-structure] FAIL could not parse Markdown links in README.md'
      FAILURES=$((FAILURES + 1))
    else
      while IFS= read -r raw_destination; do
        [[ -n "${raw_destination}" ]] || continue

        if [[ "${raw_destination}" == \#* ]]; then
          ANCHOR_LINKS_IGNORED=$((ANCHOR_LINKS_IGNORED + 1))
          continue
        fi
        if is_external_url "${raw_destination}"; then
          EXTERNAL_LINKS_IGNORED=$((EXTERNAL_LINKS_IGNORED + 1))
          continue
        fi

        LOCAL_LINK_OCCURRENCES=$((LOCAL_LINK_OCCURRENCES + 1))
        link_path=${raw_destination%%\#*}
        link_path=${link_path%%\?*}

        if [[ -z "${link_path}" ]]; then
          ANCHOR_LINKS_IGNORED=$((ANCHOR_LINKS_IGNORED + 1))
          continue
        fi
        if LC_ALL=C grep -Eiq '%00' <<EOF
${link_path}
EOF
        then
          emit '[project-structure] FAIL README.md contains an invalid local link target'
          FAILURES=$((FAILURES + 1))
          continue
        fi

        decoded_path="$(printf '%s' "${link_path}" | decode_url_path 2>/dev/null)"
        if ! normalized_path="$(normalize_relative_path "${decoded_path}")"; then
          emit '[project-structure] FAIL README.md local link is not repository-relative'
          FAILURES=$((FAILURES + 1))
          continue
        fi

        if [[ "${normalized_path}" == "${LOG_RELATIVE_PATH}" ]]; then
          GENERATED_LOG_LINKS_SKIPPED=$((GENERATED_LOG_LINKS_SKIPPED + 1))
          continue
        fi
        if link_was_seen "${normalized_path}"; then
          continue
        fi

        SEEN_LINK_TARGETS[${#SEEN_LINK_TARGETS[@]}]=${normalized_path}
        UNIQUE_LOCAL_LINKS=$((UNIQUE_LOCAL_LINKS + 1))
        if [[ -e "${PROJECT_ROOT}/${normalized_path}" ]]; then
          emit "[project-structure] PASS README link: ${normalized_path}"
        else
          emit "[project-structure] FAIL README link target missing: ${normalized_path}"
          FAILURES=$((FAILURES + 1))
        fi
      done <<EOF
${MARKDOWN_DESTINATIONS}
EOF
    fi
  fi
else
  emit '[project-structure] INFO README link validation skipped because README.md is missing'
fi

emit "[project-structure] SUMMARY required=${REQUIRED_CHECKS} local-link-occurrences=${LOCAL_LINK_OCCURRENCES} unique-local-targets=${UNIQUE_LOCAL_LINKS} external-ignored=${EXTERNAL_LINKS_IGNORED} anchors-ignored=${ANCHOR_LINKS_IGNORED} generated-log-links-skipped=${GENERATED_LOG_LINKS_SKIPPED} failures=${FAILURES}"

if (( FAILURES == 0 )); then
  emit '[project-structure] RESULT PASS'
  FINAL_STATUS=0
else
  emit '[project-structure] RESULT FAIL'
  FINAL_STATUS=1
fi

emit "[project-structure] END UTC: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
exit "${FINAL_STATUS}"
