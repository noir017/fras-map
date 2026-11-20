#!/bin/sh
# fras-check.sh - FRAS Codebase Map Validator (v1)
# POSIX sh compliant validator for FRAS (Function/Relations/API/Semantics) maps.
# Zero external dependencies (only POSIX sh, git, awk, grep).

set -e

BASE_REF=""
STALE_MODE=0
STALE_THRESHOLD=5

while [ $# -gt 0 ]; do
  case "$1" in
    --base)
      BASE_REF="$2"
      shift 2
      ;;
    --stale)
      STALE_MODE=1
      shift
      ;;
    --stale-threshold)
      STALE_THRESHOLD="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: fras-check.sh [--base <ref>] [--stale] [--stale-threshold <num>]"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$REPO_ROOT" ]; then
  echo "::error::Must be run inside a git repository." >&2
  exit 1
fi
cd "$REPO_ROOT"

EXIT_CODE=0
ERR_FLAG_TMP="$(mktemp 2>/dev/null || mktemp -t fras-err)"
L1_TMP="$(mktemp 2>/dev/null || mktemp -t fras-l1)"
L2_LIST_TMP="$(mktemp 2>/dev/null || mktemp -t fras-l2-list)"
DIFF_FILES_TMP="$(mktemp 2>/dev/null || mktemp -t fras-diff)"
trap 'rm -f "$ERR_FLAG_TMP" "$L1_TMP" "$L2_LIST_TMP" "$DIFF_FILES_TMP"' EXIT

report_error() {
  file="$1"
  line="$2"
  msg="$3"
  EXIT_CODE=1
  echo "1" > "$ERR_FLAG_TMP"
  if [ -n "$line" ] && [ "$line" -gt 0 ] 2>/dev/null; then
    echo "::error file=${file},line=${line}::${msg}" >&2
    echo "[ERROR] ${file}:${line}: ${msg}" >&2
  else
    echo "::error file=${file}::${msg}" >&2
    echo "[ERROR] ${file}: ${msg}" >&2
  fi
}

report_warn() {
  file="$1"
  line="$2"
  msg="$3"
  if [ -n "$line" ] && [ "$line" -gt 0 ] 2>/dev/null; then
    echo "::warning file=${file},line=${line}::${msg}"
    echo "[WARN] ${file}:${line}: ${msg}"
  else
    echo "::warning file=${file}::${msg}"
    echo "[WARN] ${file}: ${msg}"
  fi
}

# -------------------------------------------------------------
# Check 1: Root AGENTS.md and L1 Block
# -------------------------------------------------------------
if [ ! -f "AGENTS.md" ]; then
  report_error "AGENTS.md" 0 "Root AGENTS.md not found."
fi

if [ -f "AGENTS.md" ]; then
  # Extract lines inside ```fras ... ``` under "## Codebase Map (FRAS)"
  awk '
    BEGIN { in_section=0; in_block=0; block_found=0 }
    /^## Codebase Map \(FRAS\)/ { in_section=1; next }
    in_section && /^## / { in_section=0 }
    in_section && /^```fras[ \t]*$/ { in_block=1; block_found=1; next }
    in_block && /^```[ \t]*$/ { in_block=0; in_section=0; next }
    in_block { print NR "\t" $0 }
    END {
      if (!block_found) exit 2
    }
  ' AGENTS.md > "$L1_TMP" 2>/dev/null || AWK_STAT=$?

  if [ "${AWK_STAT:-0}" -eq 2 ]; then
    report_error "AGENTS.md" 0 "Missing '## Codebase Map (FRAS)' section or code block in AGENTS.md."
  else
    L1_COUNT=$(wc -l < "$L1_TMP" | tr -d ' ')
    if [ "$L1_COUNT" -gt 50 ]; then
      report_error "AGENTS.md" 0 "L1 block exceeds 50 lines (got ${L1_COUNT} lines, max allowed is 50)."
    fi

    # Parse and validate each line of L1
    while IFS= read -r raw_line || [ -n "$raw_line" ]; do
      [ -z "$raw_line" ] && continue
      line_num=$(echo "$raw_line" | cut -f1)
      line_content=$(echo "$raw_line" | cut -f2-)
      # Skip empty lines or pure comment lines
      case "$line_content" in
        ""|\#*) continue ;;
      esac

      # Check private address
      is_priv=$(awk -v str="$line_content" '
        BEGIN {
          if (str ~ /(^|[^0-9])10\.[0-9]+\.[0-9]+\.[0-9]+([^0-9]|$)/) { print "1"; exit }
          if (str ~ /(^|[^0-9])172\.(1[6-9]|2[0-9]|3[0-1])\.[0-9]+\.[0-9]+([^0-9]|$)/) { print "1"; exit }
          if (str ~ /(^|[^0-9])192\.168\.[0-9]+\.[0-9]+([^0-9]|$)/) { print "1"; exit }
          if (str ~ /(^|[^a-zA-Z0-9.-])[a-zA-Z0-9_-]+\.(lan|local|internal)([^a-zA-Z0-9.-]|$)/) { print "1"; exit }
          print "0"
        }
      ')
      if [ "$is_priv" = "1" ]; then
        report_error "AGENTS.md" "$line_num" "Private IP or internal hostname detected in L1 line: $line_content"
      fi

      # Parse fields: [<mod>] -> <l2_file> | F:... [ | R:...][ | A:...][ | S:...]
      parse_res=$(awk -v line="$line_content" '
        BEGIN {
          n = split(line, parts, " \\| ")
          if (n < 2) {
            print "ERR:invalid_format"
            exit
          }
          # parts[1] must match ^\[[a-zA-Z0-9_-]+\] -> [^ ]+$
          if (parts[1] !~ /^\[[a-zA-Z0-9_.-]+\] -> [^ ]+$/) {
            print "ERR:invalid_target_format"
            exit
          }
          # extract l2 file path
          sub(/^\[[a-zA-Z0-9_.-]+\] -> /, "", parts[1])
          l2_path = parts[1]

          # parts[2] must be F:...
          if (parts[2] !~ /^F:[^ ].*$/) {
            print "ERR:invalid_f_field"
            exit
          }

          # remaining fields must be R:..., A:..., S:...
          for (i = 3; i <= n; i++) {
            if (parts[i] !~ /^(R|A|S):[^ ].*$/) {
              print "ERR:invalid_subfield"
              exit
            }
          }
          print "OK\t" l2_path
        }
      ')

      status=$(echo "$parse_res" | cut -f1)
      if [ "$status" != "OK" ]; then
        report_error "AGENTS.md" "$line_num" "Invalid L1 format in AGENTS.md (check module syntax, F/R/A/S tags, or forbidden ' | '): $line_content"
      else
        l2_file=$(echo "$parse_res" | cut -f2)
        if [ ! -f "$l2_file" ]; then
          report_error "AGENTS.md" "$line_num" "L1 target L2 file does not exist: $l2_file"
        else
          echo "$l2_file" >> "$L2_LIST_TMP"
        fi
      fi
    done < "$L1_TMP"
  fi
fi

# -------------------------------------------------------------
# Collect all L2 (*.fras) files
# -------------------------------------------------------------
git ls-files '*.fras' '**/*.fras' 2>/dev/null >> "$L2_LIST_TMP" || true
if [ -s "$L2_LIST_TMP" ]; then
  sort -u "$L2_LIST_TMP" -o "$L2_LIST_TMP"
fi

if [ ! -s "$L2_LIST_TMP" ]; then
  report_error "AGENTS.md" 0 "No L2 (*.fras) files found or referenced."
fi

# -------------------------------------------------------------
# Prepare --base diff files if requested
# -------------------------------------------------------------
if [ -n "$BASE_REF" ]; then
  # Check if BASE_REF is all zeros
  case "$BASE_REF" in
    0000000000000000000000000000000000000000*)
      if git rev-parse --verify HEAD~1 >/dev/null 2>&1; then
        BASE_REF="HEAD~1"
      else
        BASE_REF=""
      fi
      ;;
  esac

  if [ -n "$BASE_REF" ]; then
    git diff --name-only "$BASE_REF" HEAD 2>/dev/null > "$DIFF_FILES_TMP" || \
    git diff --name-only "$BASE_REF" 2>/dev/null > "$DIFF_FILES_TMP" || true
  fi
fi

# -------------------------------------------------------------
# Check 2: Validate each L2 file
# -------------------------------------------------------------
while IFS= read -r fras_file || [ -n "$fras_file" ]; do
  [ -z "$fras_file" ] && continue
  if [ ! -f "$fras_file" ]; then
    report_error "$fras_file" 0 "L2 file not found: $fras_file"
    continue
  fi

  # Check line count <= 80
  file_lines=$(wc -l < "$fras_file" | tr -d ' ')
  if [ "$file_lines" -gt 80 ]; then
    report_error "$fras_file" 0 "L2 file exceeds 80 lines (got ${file_lines} lines, max allowed is 80)."
  fi

  # Check if this fras file was modified in diff
  fras_in_diff=0
  if [ -s "$DIFF_FILES_TMP" ]; then
    if grep -Fxq "$fras_file" "$DIFF_FILES_TMP" 2>/dev/null; then
      fras_in_diff=1
    fi
  fi

  line_idx=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_idx=$((line_idx + 1))
    [ -z "$line" ] && continue
    case "$line" in
      \#*) continue ;;
    esac

    # Check private address
    is_priv=$(awk -v str="$line" '
      BEGIN {
        if (str ~ /(^|[^0-9])10\.[0-9]+\.[0-9]+\.[0-9]+([^0-9]|$)/) { print "1"; exit }
        if (str ~ /(^|[^0-9])172\.(1[6-9]|2[0-9]|3[0-1])\.[0-9]+\.[0-9]+([^0-9]|$)/) { print "1"; exit }
        if (str ~ /(^|[^0-9])192\.168\.[0-9]+\.[0-9]+([^0-9]|$)/) { print "1"; exit }
        if (str ~ /(^|[^a-zA-Z0-9.-])[a-zA-Z0-9_-]+\.(lan|local|internal)([^a-zA-Z0-9.-]|$)/) { print "1"; exit }
        print "0"
      }
    ')
    if [ "$is_priv" = "1" ]; then
      report_error "$fras_file" "$line_idx" "Private IP or internal hostname detected: $line"
    fi

    # Parse L2 line syntax:
    # <path_or_glob> [Core|Infra|Edge]: F:... | R:... | A:... | S:...
    # fields separated by " | "
    # Note: no " | " allowed inside field content
    parse_l2=$(awk -v line="$line" '
      BEGIN {
        n = split(line, parts, " \\| ")
        if (n < 1) {
          print "ERR:empty"
          exit
        }

        # parts[1] must match: ^([^ ]+) \[(Core|Infra|Edge)\]: F:(.+)$
        head_match = match(parts[1], /^([^ ]+) \[(Core|Infra|Edge)\]: F:(.+)$/)
        if (!head_match) {
          print "ERR:invalid_head"
          exit
        }

        # extract path/glob, tier, and F
        first_space = index(parts[1], " ")
        target = substr(parts[1], 1, first_space - 1)
        r_part = ""
        s_part = ""

        # check subsequent fields
        for (i = 2; i <= n; i++) {
          if (parts[i] ~ /^R:[^ ].*$/) {
            r_part = substr(parts[i], 3)
          } else if (parts[i] ~ /^A:[^ ].*$/) {
            # valid A: field
          } else if (parts[i] ~ /^S:[^ ].*$/) {
            s_part = substr(parts[i], 3)
          } else {
            print "ERR:invalid_field:" parts[i]
            exit
          }
        }
        print "OK\t" target "\t" r_part "\t" s_part
      }
    ')

    l2_status=$(echo "$parse_l2" | cut -f1)
    if [ "$l2_status" != "OK" ]; then
      report_error "$fras_file" "$line_idx" "Invalid L2 line format (check tier [Core|Infra|Edge], F/R/A/S tags, or forbidden ' | '): $line"
      continue
    fi

    target_pattern=$(echo "$parse_l2" | cut -f2)
    r_paths=$(echo "$parse_l2" | cut -f3)
    s_content=$(echo "$parse_l2" | cut -f4)

    # Check target path / glob matches at least one git-tracked file
    # Use git ls-files -- "$target_pattern"
    tracked_match=$(git ls-files -- "$target_pattern" 2>/dev/null | head -n 1 || true)
    if [ -z "$tracked_match" ]; then
      report_error "$fras_file" "$line_idx" "L2 path/glob matches no git-tracked files: '$target_pattern'"
    fi

    # Check R: target paths
    if [ -n "$r_paths" ]; then
      # Split r_paths by comma
      old_ifs="$IFS"
      IFS=','
      set -- $r_paths
      IFS="$old_ifs"
      for r_p in "$@"; do
        # Trim leading and trailing spaces
        r_clean=$(echo "$r_p" | awk '{$1=$1};1')
        [ -z "$r_clean" ] && continue
        if [ ! -e "$r_clean" ]; then
          report_error "$fras_file" "$line_idx" "L2 R: target path does not exist: '$r_clean'"
        fi
      done
    fi

    # Check [T:<test_name>] in S: (or throughout the entry)
    # Extract test references
    awk -v str="$line" '
      BEGIN {
        s = str
        while (match(s, /\[T:[^\]]+\]/)) {
          t = substr(s, RSTART + 3, RLENGTH - 4)
          print t
          s = substr(s, RSTART + RLENGTH)
        }
      }
    ' | while IFS= read -r tname || [ -n "$tname" ]; do
      [ -z "$tname" ] && continue
      # Use git grep -w to find test name, excluding .fras and AGENTS.md
      if ! git grep -q -w -- "$tname" -- ':!*.fras' ':!AGENTS.md' 2>/dev/null; then
        report_error "$fras_file" "$line_idx" "Test reference [T:${tname}] not found in repo via 'git grep -w'"
      fi
    done

    # Check --base diff warning:
    # If a registered file was modified in diff, but fras_file was NOT modified in diff
    if [ -s "$DIFF_FILES_TMP" ] && [ "$fras_in_diff" -eq 0 ] && [ -n "$tracked_match" ]; then
      # Check if any changed file matches target_pattern
      matched_changed_file=""
      while IFS= read -r changed_f || [ -n "$changed_f" ]; do
        [ -z "$changed_f" ] && continue
        case "$changed_f" in
          $target_pattern)
            matched_changed_file="$changed_f"
            break
            ;;
        esac
      done < "$DIFF_FILES_TMP"

      if [ -n "$matched_changed_file" ]; then
        report_warn "$fras_file" "$line_idx" "File '$matched_changed_file' was modified in diff, but $fras_file was not updated. Entry: $line"
      fi
    fi

    # Check --stale mode
    if [ "$STALE_MODE" -eq 1 ] && [ -n "$tracked_match" ]; then
      # Find commit of this line in fras_file
      line_commit=$(git blame -L "${line_idx},${line_idx}" --porcelain "$fras_file" 2>/dev/null | head -n 1 | awk '{print $1}')
      case "$line_commit" in
        ""|0000000000000000000000000000000000000000*)
          # uncommitted changes, skip
          ;;
        *)
          # Count commits to tracked_match since line_commit
          mod_count=$(git rev-list --count "${line_commit}..HEAD" -- "$tracked_match" 2>/dev/null || echo 0)
          if [ "$mod_count" -ge "$STALE_THRESHOLD" ]; then
            echo "[STALE] ${fras_file}:${line_idx}: '${tracked_match}' modified ${mod_count} times since entry commit ${line_commit} (threshold: ${STALE_THRESHOLD})"
            echo "        ${line}"
          fi
          ;;
      esac
    fi

  done < "$fras_file"

done < "$L2_LIST_TMP"

if [ -s "$ERR_FLAG_TMP" ]; then
  EXIT_CODE=1
fi

if [ "$EXIT_CODE" -eq 0 ]; then
  echo "[OK] FRAS check passed with zero errors."
else
  echo "[FAIL] FRAS check failed with errors." >&2
fi

exit "$EXIT_CODE"
