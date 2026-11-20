#!/bin/sh
# fras-check.sh - FRAS Codebase Map Validator (v1.1)
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

      # Check private address FIRST (including comment lines)
      is_priv=$(awk -v raw="$line_content" '
        BEGIN {
          str = tolower(raw)
          if (str ~ /(^|[^0-9])10\.[0-9]+\.[0-9]+\.[0-9]+([^0-9]|$)/) { print "1"; exit }
          if (str ~ /(^|[^0-9])172\.(1[6-9]|2[0-9]|3[0-1])\.[0-9]+\.[0-9]+([^0-9]|$)/) { print "1"; exit }
          if (str ~ /(^|[^0-9])192\.168\.[0-9]+\.[0-9]+([^0-9]|$)/) { print "1"; exit }
          if (str ~ /(^|[^a-z0-9_-])[a-z0-9_-]+(\.[a-z0-9_-]+)*\.(lan|local|internal)([^a-z0-9_-]|$)/) { print "1"; exit }
          print "0"
        }
      ')
      if [ "$is_priv" = "1" ]; then
        report_error "AGENTS.md" "$line_num" "Private IP or internal hostname detected in L1 line: $line_content"
      fi

      # Skip empty lines or pure comment lines AFTER checking private addresses
      case "$line_content" in
        ""|\#*) continue ;;
      esac

      # Parse fields: [<mod>] -> <l2_file> | F:... [ | R:...][ | A:...][ | S:...]
      parse_res=$(awk -v line="$line_content" '
        BEGIN {
          n = split(line, parts, " \\| ")
          if (n < 2) {
            print "ERR:invalid_format"
            exit
          }
          if (parts[1] !~ /^\[[a-zA-Z0-9_.-]+\] -> [^ ]+$/) {
            print "ERR:invalid_target_format"
            exit
          }
          sub(/^\[[a-zA-Z0-9_.-]+\] -> /, "", parts[1])
          l2_path = parts[1]

          if (parts[2] !~ /^F:[^ ].*$/) {
            print "ERR:invalid_f_field"
            exit
          }

          a_field = ""
          for (i = 3; i <= n; i++) {
            if (parts[i] ~ /^A:[^ ].*$/) {
              a_field = substr(parts[i], 3)
            } else if (parts[i] !~ /^(R|S):[^ ].*$/) {
              print "ERR:invalid_subfield"
              exit
            }
          }
          print "OK\t" l2_path "\t" a_field
        }
      ')

      status=$(echo "$parse_res" | cut -f1)
      if [ "$status" != "OK" ]; then
        report_error "AGENTS.md" "$line_num" "Invalid L1 format in AGENTS.md (check module syntax, F/R/A/S tags, or forbidden ' | '): $line_content"
      else
        l2_file=$(echo "$parse_res" | cut -f2)
        l1_apis=$(echo "$parse_res" | cut -f3)

        if [ ! -f "$l2_file" ]; then
          report_error "AGENTS.md" "$line_num" "L1 target L2 file does not exist: $l2_file"
        else
          echo "$l2_file" >> "$L2_LIST_TMP"

          # Check L1 A: symbols in the files registered in l2_file
          if [ -n "$l1_apis" ]; then
            # Extract target patterns from l2_file
            mod_patterns=$(awk '/^[ \t]*#/ || /^[ \t]*$/ {next} {n=split($0, p, " "); if(n>0) print p[1]}' "$l2_file" 2>/dev/null || true)
            echo "$l1_apis" | tr ',' '\n' | while IFS= read -r api_sym || [ -n "$api_sym" ]; do
              sym_clean=$(echo "$api_sym" | awk '{$1=$1};1')
              [ -z "$sym_clean" ] && continue
              found_sym=0
              for m_pat in $mod_patterns; do
                if git grep -q -w -F -- "$sym_clean" -- "$m_pat" 2>/dev/null; then
                  found_sym=1
                  break
                fi
              done
              if [ "$found_sym" -eq 0 ]; then
                report_error "AGENTS.md" "$line_num" "L1 API symbol '$sym_clean' not found in module files registered in '$l2_file' via 'git grep -w -F'"
              fi
            done
          fi

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
    # Verify base commit exists
    if ! git rev-parse --verify "$BASE_REF^{commit}" >/dev/null 2>&1; then
      report_warn "" 0 "Base ref '$BASE_REF' does not exist in repository. Skipping diff check."
      BASE_REF=""
    else
      git diff --name-only "$BASE_REF" HEAD 2>/dev/null > "$DIFF_FILES_TMP" || \
      git diff --name-only "$BASE_REF" 2>/dev/null > "$DIFF_FILES_TMP" || true
    fi
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

    # Check private address FIRST (including comment lines)
    is_priv=$(awk -v raw="$line" '
      BEGIN {
        str = tolower(raw)
        if (str ~ /(^|[^0-9])10\.[0-9]+\.[0-9]+\.[0-9]+([^0-9]|$)/) { print "1"; exit }
        if (str ~ /(^|[^0-9])172\.(1[6-9]|2[0-9]|3[0-1])\.[0-9]+\.[0-9]+([^0-9]|$)/) { print "1"; exit }
        if (str ~ /(^|[^0-9])192\.168\.[0-9]+\.[0-9]+([^0-9]|$)/) { print "1"; exit }
        if (str ~ /(^|[^a-z0-9_-])[a-z0-9_-]+(\.[a-z0-9_-]+)*\.(lan|local|internal)([^a-z0-9_-]|$)/) { print "1"; exit }
        print "0"
      }
    ')
    if [ "$is_priv" = "1" ]; then
      report_error "$fras_file" "$line_idx" "Private IP or internal hostname detected: $line"
    fi

    # Skip empty lines or pure comment lines AFTER checking private addresses
    [ -z "$line" ] && continue
    case "$line" in
      \#*) continue ;;
    esac

    # Parse L2 line syntax:
    # <path_or_glob> [Core|Infra|Edge]: F:... | R:... | A:... | S:...
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

        first_space = index(parts[1], " ")
        target = substr(parts[1], 1, first_space - 1)
        r_part = ""
        a_part = ""
        s_part = ""

        for (i = 2; i <= n; i++) {
          if (parts[i] ~ /^R:[^ ].*$/) {
            r_part = substr(parts[i], 3)
          } else if (parts[i] ~ /^A:[^ ].*$/) {
            a_part = substr(parts[i], 3)
          } else if (parts[i] ~ /^S:[^ ].*$/) {
            s_part = substr(parts[i], 3)
          } else {
            print "ERR:invalid_field:" parts[i]
            exit
          }
        }
        print "OK\t" target "\t" r_part "\t" a_part "\t" s_part
      }
    ')

    l2_status=$(echo "$parse_l2" | cut -f1)
    if [ "$l2_status" != "OK" ]; then
      report_error "$fras_file" "$line_idx" "Invalid L2 line format (check tier [Core|Infra|Edge], F/R/A/S tags, or forbidden ' | '): $line"
      continue
    fi

    target_pattern=$(echo "$parse_l2" | cut -f2)
    r_paths=$(echo "$parse_l2" | cut -f3)
    a_symbols=$(echo "$parse_l2" | cut -f4)
    s_content=$(echo "$parse_l2" | cut -f5)

    # Check target path / glob matches at least one git-tracked file
    tracked_match=$(git ls-files -- "$target_pattern" 2>/dev/null | head -n 1 || true)
    if [ -z "$tracked_match" ]; then
      report_error "$fras_file" "$line_idx" "L2 path/glob matches no git-tracked files: '$target_pattern'"
    fi

    # Check A: API symbols in matched files via git grep -w -F
    if [ -n "$a_symbols" ] && [ -n "$tracked_match" ]; then
      echo "$a_symbols" | tr ',' '\n' | while IFS= read -r sym || [ -n "$sym" ]; do
        sym_clean=$(echo "$sym" | awk '{$1=$1};1')
        [ -z "$sym_clean" ] && continue
        if ! git grep -q -w -F -- "$sym_clean" -- "$target_pattern" 2>/dev/null; then
          report_error "$fras_file" "$line_idx" "API symbol '$sym_clean' not found in '$target_pattern' via 'git grep -w -F'"
        fi
      done
    fi

    # Check R: target paths (using tr instead of unquoted set --)
    if [ -n "$r_paths" ]; then
      echo "$r_paths" | tr ',' '\n' | while IFS= read -r r_p || [ -n "$r_p" ]; do
        r_clean=$(echo "$r_p" | awk '{$1=$1};1')
        [ -z "$r_clean" ] && continue
        if [ ! -e "$r_clean" ]; then
          report_error "$fras_file" "$line_idx" "L2 R: target path does not exist: '$r_clean'"
        fi
      done
    fi

    # Check [T:<test_name>] in S: (or throughout the entry)
    # Must match test declarations (Go func, JS/TS describe/it/test, Python def) with literal matching
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
      found_test=0
      # Go func test declaration
      if git grep -q -F "func $tname(" -- ':!*.fras' ':!AGENTS.md' 2>/dev/null; then
        found_test=1
      # JS/TS describe/it/test declarations (single & double quotes)
      elif git grep -q -F "describe('$tname'" -- ':!*.fras' ':!AGENTS.md' 2>/dev/null || \
           git grep -q -F "it('$tname'" -- ':!*.fras' ':!AGENTS.md' 2>/dev/null || \
           git grep -q -F "test('$tname'" -- ':!*.fras' ':!AGENTS.md' 2>/dev/null || \
           git grep -q -F "describe(\"$tname\"" -- ':!*.fras' ':!AGENTS.md' 2>/dev/null || \
           git grep -q -F "it(\"$tname\"" -- ':!*.fras' ':!AGENTS.md' 2>/dev/null || \
           git grep -q -F "test(\"$tname\"" -- ':!*.fras' ':!AGENTS.md' 2>/dev/null; then
        found_test=1
      # Python test function declaration
      elif git grep -q -F "def $tname(" -- ':!*.fras' ':!AGENTS.md' 2>/dev/null || \
           git grep -q -F "def $tname " -- ':!*.fras' ':!AGENTS.md' 2>/dev/null; then
        found_test=1
      fi

      if [ "$found_test" -eq 0 ]; then
        report_error "$fras_file" "$line_idx" "Test reference [T:${tname}] does not match test declaration (func/describe/it/test/def) via literal search"
      fi
    done

    # Check --base diff warning:
    if [ -s "$DIFF_FILES_TMP" ] && [ "$fras_in_diff" -eq 0 ] && [ -n "$tracked_match" ]; then
      matched_changed_file=""
      while IFS= read -r changed_f || [ -n "$changed_f" ]; do
        [ -z "$changed_f" ] && continue
        # 1. Exact match
        if [ "$changed_f" = "$target_pattern" ]; then
          matched_changed_file="$changed_f"
          break
        fi
        # 2. Directory prefix match (e.g. skill/ matches skill/SKILL.md)
        case "$target_pattern" in
          */)
            case "$changed_f" in
              "$target_pattern"*)
                matched_changed_file="$changed_f"
                break
                ;;
            esac
            ;;
          *)
            if [ -d "$target_pattern" ]; then
              case "$changed_f" in
                "$target_pattern"/*)
                  matched_changed_file="$changed_f"
                  break
                  ;;
              esac
            fi
            ;;
        esac
        # 3. Glob match
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

    # Check --stale mode (uses full target_pattern pathspec instead of just first match)
    if [ "$STALE_MODE" -eq 1 ] && [ -n "$tracked_match" ]; then
      line_commit=$(git blame -L "${line_idx},${line_idx}" --porcelain "$fras_file" 2>/dev/null | head -n 1 | awk '{print $1}')
      case "$line_commit" in
        ""|0000000000000000000000000000000000000000*)
          ;;
        *)
          # Count commits matching target_pattern pathspec since line_commit
          mod_count=$(git rev-list --count "${line_commit}..HEAD" -- "$target_pattern" 2>/dev/null || echo 0)
          if [ "$mod_count" -ge "$STALE_THRESHOLD" ]; then
            echo "[STALE] ${fras_file}:${line_idx}: '${target_pattern}' modified ${mod_count} times since entry commit ${line_commit} (threshold: ${STALE_THRESHOLD})"
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
