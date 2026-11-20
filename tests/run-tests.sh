#!/bin/sh
# tests/run-tests.sh - Comprehensive test suite for fras-check.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CHECK_SCRIPT="$REPO_ROOT/skills/fras-map/scripts/fras-check.sh"
FIXTURES_DIR="$SCRIPT_DIR/fixtures"

PASSED_COUNT=0
FAILED_COUNT=0

log_pass() {
  echo "  [PASS] $1"
  PASSED_COUNT=$((PASSED_COUNT + 1))
}

log_fail() {
  echo "  [FAIL] $1: $2" >&2
  FAILED_COUNT=$((FAILED_COUNT + 1))
}

setup_git_repo() {
  fixture_name="$1"
  target_dir="$2"
  cp -R "$FIXTURES_DIR/$fixture_name/." "$target_dir/"
  (
    cd "$target_dir"
    git init -q
    git config user.name "FRAS Test"
    git config user.email "fras-test@example.com"
    git add -A
    git commit -q -m "initial commit"
  )
}

echo "=== Running FRAS Checker Test Suite ==="

# -------------------------------------------------------------
# 1. Valid fixture & Feature tests
# -------------------------------------------------------------
echo "Testing valid fixture..."
TMP_VALID="$(mktemp -d)"
setup_git_repo "valid" "$TMP_VALID"

# Normal run
if (cd "$TMP_VALID" && sh "$CHECK_SCRIPT" >/dev/null 2>&1); then
  log_pass "valid fixture exited with 0"
else
  log_fail "valid fixture" "expected exit code 0"
fi

# --stale mode on clean repo
if (cd "$TMP_VALID" && sh "$CHECK_SCRIPT" --stale >/dev/null 2>&1); then
  log_pass "valid fixture --stale exited with 0"
else
  log_fail "valid fixture --stale" "expected exit code 0"
fi

# --base mode with untracked FRAS update warning
if (
  cd "$TMP_VALID"
  echo "# modified" >> src/core.py
  git commit -q -am "modify core.py"
  if output=$(sh "$CHECK_SCRIPT" --base HEAD~1 2>&1); then status=0; else status=$?; fi
  if echo "$output" | grep -q "warning file=docs/fras/core.fras"; then
    log_pass "valid fixture --base detected modified source without FRAS update"
    exit 0
  else
    log_fail "valid fixture --base" "warning annotation not found in output"
    exit 1
  fi
); then
  PASSED_COUNT=$((PASSED_COUNT + 1))
else
  FAILED_COUNT=$((FAILED_COUNT + 1))
fi

# --base with non-existent base ref (should warn and exit 0)
if (
  cd "$TMP_VALID"
  if output=$(sh "$CHECK_SCRIPT" --base deadbeef1234567890abcdef1234567890abcdef 2>&1); then
    status=0
  else
    status=$?
  fi
  if [ "$status" -eq 0 ] && echo "$output" | grep -q "::warning::Base ref.*does not exist in repository" && ! echo "$output" | grep -q "warning file=::"; then
    log_pass "valid fixture --base with non-existent ref warned without file= and exited 0"
    exit 0
  else
    log_fail "valid fixture --base with non-existent ref" "expected warning without file= and exit 0. Got: $output"
    exit 1
  fi
); then
  PASSED_COUNT=$((PASSED_COUNT + 1))
else
  FAILED_COUNT=$((FAILED_COUNT + 1))
fi
rm -rf "$TMP_VALID"

# Hostname false positive test: settings.local.json and .env.local must be accepted
echo "Testing benign filenames containing .local (settings.local.json, .env.local)..."
TMP_LOCAL="$(mktemp -d)"
if (
  cd "$TMP_LOCAL"
  git init -q
  git config user.name "FRAS Test"
  git config user.email "fras-test@example.com"
  mkdir -p docs/fras src
  cat << 'EOF' > AGENTS.md
# Project
## Codebase Map (FRAS)
```fras
[core] -> docs/fras/core.fras | F:Core module
```
EOF
  cat << 'EOF' > docs/fras/core.fras
# Config for settings.local.json and .env.local
src/core.py [Core]: F:Core files
EOF
  echo "print(1)" > src/core.py
  git add -A && git commit -q -m "init"
  if output=$(sh "$CHECK_SCRIPT" 2>&1); then status=0; else status=$?; fi
  if [ "$status" -eq 0 ] && ! echo "$output" | grep -q "Private IP or internal hostname"; then
    log_pass "benign filenames (.local.json, .env.local) accepted without false positive"
    exit 0
  else
    log_fail "benign filenames" "unexpected private hostname error on .local filename. Got: $output"
    exit 1
  fi
); then
  PASSED_COUNT=$((PASSED_COUNT + 1))
else
  FAILED_COUNT=$((FAILED_COUNT + 1))
fi
rm -rf "$TMP_LOCAL"

# Go method receiver & JS advanced test declarations (describe.skip, backticks, it.each)
echo "Testing advanced test declarations (Go method, JS skip/backtick/each)..."
TMP_ADV="$(mktemp -d)"
if (
  cd "$TMP_ADV"
  git init -q
  git config user.name "FRAS Test"
  git config user.email "fras-test@example.com"
  mkdir -p docs/fras src tests
  cat << 'EOF' > AGENTS.md
# Project
## Codebase Map (FRAS)
```fras
[core] -> docs/fras/core.fras | F:Core module
```
EOF
  cat << 'EOF' > docs/fras/core.fras
src/core.go [Core]: F:Go core | S:Invariant [T:TestMethod]
src/core.js [Core]: F:JS core | S:Invariant [T:test-skip] [T:test-backtick] [T:test-each]
EOF
  echo "package src" > src/core.go
  cat << 'EOF' > src/core_test.go
package src
import "testing"
func (s *Suite) TestMethod(t *testing.T) {}
EOF
  echo "const a = 1;" > src/core.js
  cat << 'EOF' > tests/core.test.js
describe.skip('test-skip', () => {});
test(`test-backtick`, () => {});
it.each([[1]])('test-each', () => {});
EOF
  git add -A && git commit -q -m "init"
  if output=$(sh "$CHECK_SCRIPT" 2>&1); then status=0; else status=$?; fi
  if [ "$status" -eq 0 ]; then
    log_pass "advanced test declarations (Go method, JS skip/backtick/each) accepted"
    exit 0
  else
    log_fail "advanced test declarations" "expected exit code 0. Got: $output"
    exit 1
  fi
); then
  PASSED_COUNT=$((PASSED_COUNT + 1))
else
  FAILED_COUNT=$((FAILED_COUNT + 1))
fi
rm -rf "$TMP_ADV"

# report_error line variable isolation test (line must not become row number)
echo "Testing report_error does not smash line variable..."
TMP_SMASH="$(mktemp -d)"
if (
  cd "$TMP_SMASH"
  git init -q
  git config user.name "FRAS Test"
  git config user.email "fras-test@example.com"
  mkdir -p docs/fras src
  cat << 'EOF' > AGENTS.md
# Project
## Codebase Map (FRAS)
```fras
[core] -> docs/fras/core.fras | F:Core module
```
EOF
  cat << 'EOF' > docs/fras/core.fras
# Comment with 192.168.1.1
src/core.py [Core]: F:Core files | A:run_core
EOF
  echo "def run_core(): pass" > src/core.py
  git add -A && git commit -q -m "init"
  output=$(sh "$CHECK_SCRIPT" 2>&1 || true)
  if echo "$output" | grep -q "Private IP or internal hostname" && ! echo "$output" | grep -q "Invalid L2 line format"; then
    log_pass "report_error does not smash line variable into format error"
    exit 0
  else
    log_fail "line variable smash" "spurious Invalid L2 line format emitted when reporting private IP. Got: $output"
    exit 1
  fi
); then
  PASSED_COUNT=$((PASSED_COUNT + 1))
else
  FAILED_COUNT=$((FAILED_COUNT + 1))
fi
rm -rf "$TMP_SMASH"

# Directory entry match under --base
echo "Testing directory entry warning under --base..."
TMP_DIR_REPO="$(mktemp -d)"
if (
  cd "$TMP_DIR_REPO"
  git init -q
  git config user.name "FRAS Test"
  git config user.email "fras-test@example.com"
  mkdir -p docs/fras skill
  cat << 'EOF' > AGENTS.md
# Project
## Codebase Map (FRAS)
```fras
[skill] -> docs/fras/skill.fras | F:Skill docs
```
EOF
  cat << 'EOF' > docs/fras/skill.fras
skill/ [Core]: F:Bundled skill directory
EOF
  echo "initial" > skill/SKILL.md
  git add -A && git commit -q -m "init"
  echo "modified skill" >> skill/SKILL.md
  git commit -q -am "update skill"
  if output=$(sh "$CHECK_SCRIPT" --base HEAD~1 2>&1); then status=0; else status=$?; fi
  if echo "$output" | grep -q "warning file=docs/fras/skill.fras"; then
    log_pass "directory entry matched file change under --base"
    exit 0
  else
    log_fail "directory entry match" "expected warning on directory entry. Got: $output"
    exit 1
  fi
); then
  PASSED_COUNT=$((PASSED_COUNT + 1))
else
  FAILED_COUNT=$((FAILED_COUNT + 1))
fi
rm -rf "$TMP_DIR_REPO"

# Glob stale test: modifying non-first file in glob
echo "Testing glob stale check on non-first file..."
TMP_GLOB="$(mktemp -d)"
if (
  cd "$TMP_GLOB"
  git init -q
  git config user.name "FRAS Test"
  git config user.email "fras-test@example.com"
  mkdir -p docs/fras src
  cat << 'EOF' > AGENTS.md
# Project
## Codebase Map (FRAS)
```fras
[core] -> docs/fras/core.fras | F:Core module
```
EOF
  cat << 'EOF' > docs/fras/core.fras
src/*.py [Core]: F:Core files
EOF
  echo "a" > src/a.py
  echo "b" > src/b.py
  git add -A && git commit -q -m "init"

  # Modify b.py (the second file) 5 times
  i=1
  while [ "$i" -le 5 ]; do
    echo "change $i" >> src/b.py
    git commit -q -am "change $i to b"
    i=$((i + 1))
  done

  if output=$(sh "$CHECK_SCRIPT" --stale 2>&1); then status=0; else status=$?; fi
  if echo "$output" | grep -q "\[STALE\].*src/\*\.py.*modified 5 times"; then
    log_pass "glob stale check correctly detected commits on non-first file in glob"
    exit 0
  else
    log_fail "glob stale check" "expected STALE report for src/*.py. Got:\n$output"
    exit 1
  fi
); then
  PASSED_COUNT=$((PASSED_COUNT + 1))
else
  FAILED_COUNT=$((FAILED_COUNT + 1))
fi
rm -rf "$TMP_GLOB"

# -------------------------------------------------------------
# 2. Hard error fixtures
# -------------------------------------------------------------
run_error_test() {
  fixture="$1"
  expected_needle="$2"
  desc="$3"
  echo "Testing $desc ($fixture)..."

  TMP_ERR="$(mktemp -d)"
  setup_git_repo "$fixture" "$TMP_ERR"

  output=""
  exit_code=0
  output=$( (cd "$TMP_ERR" && sh "$CHECK_SCRIPT" 2>&1) ) || exit_code=$?

  if [ "$exit_code" -eq 1 ]; then
    if echo "$output" | grep -qi "$expected_needle"; then
      log_pass "$fixture exited with 1 and matched: '$expected_needle'"
    else
      log_fail "$fixture" "exited with 1 but output did not match '$expected_needle'. Got:\n$output"
    fi
  else
    log_fail "$fixture" "expected exit code 1 but got $exit_code. Output:\n$output"
  fi

  rm -rf "$TMP_ERR"
}

run_error_test "err-format" "Invalid L2 line format" "format error"
run_error_test "err-l1-path-missing" "L1 target L2 file does not exist" "L1 -> path missing"
run_error_test "err-l2-path-not-tracked" "matches no git-tracked files" "L2 path not tracked"
run_error_test "err-l2-r-path-missing" "L2 R: target path does not exist" "L2 R: path missing"
run_error_test "err-l1-too-long" "L1 block exceeds 50 lines" "L1 exceeds 50 lines"
run_error_test "err-l2-too-long" "L2 file exceeds 80 lines" "L2 exceeds 80 lines"
run_error_test "err-test-symbol-missing" "Test reference \[T:" "test symbol missing in git grep"
run_error_test "err-private-address" "Private IP or internal hostname detected" "private address detected"
run_error_test "err-test-in-source" "does not match test declaration" "test name only in source declaration"
run_error_test "err-test-go-in-source" "does not match test declaration" "Go test name only in source"
run_error_test "err-test-py-in-source" "does not match test declaration" "Python test name only in source"
run_error_test "err-test-js-emit" "does not match test declaration" "JS test name inside emit() call"
run_error_test "err-test-dot" "does not match test declaration" "test name with dot not regex matched"
run_error_test "err-priv-comment" "Private IP or internal hostname detected" "private address in comment line"
run_error_test "err-priv-multilevel" "Private IP or internal hostname detected" "multi-level .lan/.internal hostname"
run_error_test "err-api-missing" "API symbol.*not found" "missing A: symbol in target files"

echo "========================================"
echo "Tests passed: $PASSED_COUNT, Tests failed: $FAILED_COUNT"

if [ "$FAILED_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
