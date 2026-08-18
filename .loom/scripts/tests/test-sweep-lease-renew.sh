#!/usr/bin/env bash
# test-sweep-lease-renew.sh - Unit tests for sweep-lease-renew.sh (#6180).
#
# Black-box tests: sweep-lease-renew.sh is a full CLI script (no functions to
# source), so `gh` is stubbed on PATH (real `jq` is used unstubbed — its
# logic is exactly what's under test) and the real script is invoked as a
# subprocess, asserting on stdout/stderr/exit code. Mirrors the stubbing
# pattern in test-judge-fallback-cap.sh.
#
# Covers:
#   (a) renew-once finds the newest lease-marker comment and PATCHes it,
#       preserving the first-line marker byte-for-byte
#   (b) renew-once is idempotent: a second call replaces (not accumulates)
#       the `loom:lease-renewed` trailer line
#   (c) renew-once ignores a comment whose body merely CONTAINS the marker
#       text without it being the first line (startswith, not substring)
#   (d) renew-once with no matching lease comment -> exit 2 (best-effort
#       no-op, not a hard failure)
#   (e) renew-once --host/--sweep-id requires an EXACT marker match, both
#       the miss and the hit cases
#   (f) renew-once --host without --sweep-id (and vice versa) -> usage error
#   (g) start spawns a background loop that self-terminates once its
#       watched PID dies (never renews after that point) — verifies the
#       "sweep exits -> renewal naturally stops" contract, entirely via a
#       real background process against the real script (no `gh` needed
#       for the termination half; the PATCH stub records call count too)
#   (h) stop kills a given PID
#
# Usage:
#   ./.loom/scripts/tests/test-sweep-lease-renew.sh

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/.." && pwd)"
SCRIPT="$SCRIPTS_DIR/sweep-lease-renew.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

assert_eq() {
    local expected="$1" actual="$2" msg="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$expected" == "$actual" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}PASS${NC}: $msg"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}FAIL${NC}: $msg"
        echo "    Expected: '$expected'"
        echo "    Actual:   '$actual'"
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" msg="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}PASS${NC}: $msg"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}FAIL${NC}: $msg"
        echo "    Expected substring: '$needle'"
        echo "    In: '$haystack'"
    fi
}

assert_true() {
    local cond="$1" msg="$2"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$cond" == "true" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}PASS${NC}: $msg"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}FAIL${NC}: $msg"
    fi
}

if [[ ! -x "$SCRIPT" ]]; then
    echo -e "${RED}FATAL${NC}: $SCRIPT not found or not executable" >&2
    exit 2
fi

STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR" 2>/dev/null || true' EXIT

# --- Stub gh on PATH ---------------------------------------------------
#   gh api [-R repo] repos/{owner}/{repo}/issues/<N>/comments --paginate
#       -> cat $STUB_DIR/comments.json (or "[]"; fails if comments-fail exists)
#   gh api [-R repo] --method PATCH repos/{owner}/{repo}/issues/comments/<id> -F body=@-
#       -> reads stdin into $STUB_DIR/patch-<id>-N.body, appends "<id>" to
#          $STUB_DIR/patch-calls.log, prints "{}" (fails if patch-fail exists)
#
#   The stub deliberately distinguishes `-f`/`--raw-field` (real `gh api`
#   semantics: the value is a LITERAL string -- `@-`/`@path` is NOT expanded,
#   stdin is never read) from `-F`/`--field` (real `gh api` semantics: a
#   `@-`/`@path` value IS expanded, reading from stdin/file respectively).
#   This is what catches the `-f body=@-` regression (#6357): with `-f`, the
#   stub records the literal two-character string `@-` as the PATCHed body
#   instead of the piped renewed content -- exactly like the real `gh` CLI --
#   so a script that (incorrectly) uses `-f body=@-` fails test (a) below.
cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
D="${LOOM_TEST_STUB_DIR:?stub gh: LOOM_TEST_STUB_DIR not set}"
if [[ "$1" == "api" ]]; then
  shift
  method="GET"
  path=""
  field_flag=""
  field_kv=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --method) method="$2"; shift 2 ;;
      -R) shift 2 ;;
      --paginate) shift ;;
      -f|--raw-field) field_flag="-f"; field_kv="$2"; shift 2 ;;
      -F|--field) field_flag="-F"; field_kv="$2"; shift 2 ;;
      *)
        if [[ -z "$path" ]]; then path="$1"; fi
        shift
        ;;
    esac
  done
  if [[ "$method" == "GET" && "$path" == repos/*/issues/*/comments ]]; then
    if [[ -f "$D/comments-fail" ]]; then
      echo "stub gh: comments fetch failed" >&2
      exit 1
    fi
    canned="$D/comments.json"
    if [[ -f "$canned" ]]; then cat "$canned"; else echo "[]"; fi
    exit 0
  fi
  if [[ "$method" == "PATCH" && "$path" == repos/*/issues/comments/* ]]; then
    if [[ -f "$D/patch-fail" ]]; then
      echo "stub gh: patch failed" >&2
      exit 1
    fi
    id="${path##*/}"
    n=$(( $(cat "$D/patch-count-$id" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$D/patch-count-$id"
    val="${field_kv#*=}"
    if [[ "$field_flag" == "-F" && "$val" == "@-" ]]; then
      # -F/--field DOES expand "@-": read the real value from stdin.
      cat > "$D/patch-$id-$n.body"
    elif [[ "$field_flag" == "-F" && "$val" == @* ]]; then
      # -F/--field DOES expand "@<path>": read the real value from the file.
      cat "${val#@}" > "$D/patch-$id-$n.body" 2>/dev/null || true
    else
      # -f/--raw-field does NOT expand "@..." -- it's posted as the literal
      # string (this is the real gh CLI behavior the #6357 bug exploited).
      printf '%s' "$val" > "$D/patch-$id-$n.body"
    fi
    echo "$id" >> "$D/patch-calls.log"
    echo '{}'
    exit 0
  fi
  echo "stub gh: unhandled api args: method=$method path=$path" >&2
  exit 3
fi
echo "stub gh: unhandled args: $*" >&2
exit 3
STUB
chmod +x "$STUB_DIR/gh"

export LOOM_TEST_STUB_DIR="$STUB_DIR"
export PATH="$STUB_DIR:$PATH"

reset_state() {
    rm -f "$STUB_DIR"/comments.json "$STUB_DIR"/comments-fail "$STUB_DIR"/patch-fail
    rm -f "$STUB_DIR"/patch-*.body "$STUB_DIR"/patch-count-* "$STUB_DIR"/patch-calls.log
}

run_script() {
    OUT="$("$SCRIPT" "$@" 2>"$STUB_DIR/stderr.log")"
    RC=$?
    ERR="$(cat "$STUB_DIR/stderr.log" 2>/dev/null || true)"
}

echo "Testing sweep-lease-renew.sh..."

# --- (a) finds newest lease-marker comment, PATCHes it, preserves marker ---
reset_state
cat > "$STUB_DIR/comments.json" <<'JSON'
[
  {"id": 1, "body": "unrelated comment, no marker here"},
  {"id": 42, "body": "<!-- loom:lease host=studio-host sweep=sweep-issue-6180-1000 -->\nLease acquired for this claim."}
]
JSON
run_script renew-once 6180
assert_eq "0" "$RC" "(a) renew-once exits 0 when a lease comment exists"
assert_eq "" "$OUT" "(a) renew-once prints nothing to stdout (all diagnostics go to stderr)"
BODY_A="$(cat "$STUB_DIR/patch-42-1.body" 2>/dev/null || echo MISSING)"
assert_true "$([[ "$BODY_A" != "@-" ]] && echo true || echo false)" "(a) PATCH body is the real renewed content, not the literal string '@-' (#6357: requires -F, not -f)"
assert_contains "$BODY_A" "<!-- loom:lease host=studio-host sweep=sweep-issue-6180-1000 -->" "(a) PATCH body preserves the first-line marker byte-for-byte"
assert_contains "$BODY_A" "Lease acquired for this claim." "(a) PATCH body preserves the original free-form prose"
assert_contains "$BODY_A" "<!-- loom:lease-renewed " "(a) PATCH body appends a loom:lease-renewed trailer"
FIRST_LINE_A="$(head -n1 "$STUB_DIR/patch-42-1.body")"
assert_eq "<!-- loom:lease host=studio-host sweep=sweep-issue-6180-1000 -->" "$FIRST_LINE_A" "(a) the marker is still the LITERAL first line"

# --- (b) idempotent: second renewal REPLACES, not accumulates, the trailer -
reset_state
cat > "$STUB_DIR/comments.json" <<'JSON'
[
  {"id": 42, "body": "<!-- loom:lease host=studio-host sweep=sweep-issue-6180-1000 -->\nLease acquired."}
]
JSON
run_script renew-once 6180
sleep 1.1
# Feed the just-patched body back in as if the forge now holds it (jq --
# already a hard dependency of the script under test -- rather than adding a
# python3 dependency just for this one test-fixture mutation).
jq --rawfile body "$STUB_DIR/patch-42-1.body" \
    '(.[] | select(.id == 42) | .body) = $body' \
    "$STUB_DIR/comments.json" > "$STUB_DIR/comments.json.tmp"
mv "$STUB_DIR/comments.json.tmp" "$STUB_DIR/comments.json"
run_script renew-once 6180
assert_eq "0" "$RC" "(b) second renew-once also exits 0"
TRAILER_COUNT="$(grep -c "loom:lease-renewed" "$STUB_DIR/patch-42-2.body" 2>/dev/null || echo 0)"
assert_eq "1" "$TRAILER_COUNT" "(b) exactly ONE loom:lease-renewed trailer line after two renewals (no accumulation)"
BODY_B1="$(cat "$STUB_DIR/patch-42-1.body")"
BODY_B2="$(cat "$STUB_DIR/patch-42-2.body")"
assert_true "$([[ "$BODY_B1" != "$BODY_B2" ]] && echo true || echo false)" "(b) the two renewal PATCHes carry different content (updated_at will genuinely advance)"

# --- (c) startswith, not substring: a mid-body mention of the marker text
#     must NOT be treated as a lease comment -------------------------------
reset_state
cat > "$STUB_DIR/comments.json" <<'JSON'
[
  {"id": 7, "body": "Discussing the format: `<!-- loom:lease host=x sweep=y -->` is the marker, but this is prose, not a lease record."}
]
JSON
run_script renew-once 6180
assert_eq "2" "$RC" "(c) a comment merely mentioning the marker (not as its first line) is NOT treated as a lease"

# --- (d) no matching lease comment -> exit 2, not a hard failure ----------
reset_state
cat > "$STUB_DIR/comments.json" <<'JSON'
[{"id": 1, "body": "nothing to see here"}]
JSON
run_script renew-once 6180
assert_eq "2" "$RC" "(d) no lease comment -> exit 2 (best-effort no-op)"
assert_contains "$ERR" "nothing to renew" "(d) exit-2 message explains why"

# --- (e) --host/--sweep-id exact-match filter -----------------------------
reset_state
cat > "$STUB_DIR/comments.json" <<'JSON'
[
  {"id": 42, "body": "<!-- loom:lease host=studio-host sweep=sweep-issue-6180-1000 -->\nLease acquired."}
]
JSON
run_script renew-once 6180 --host wrong-host --sweep-id sweep-issue-6180-1000
assert_eq "2" "$RC" "(e) exact host/sweep-id filter: mismatched host -> exit 2"
run_script renew-once 6180 --host studio-host --sweep-id sweep-issue-6180-1000
assert_eq "0" "$RC" "(e) exact host/sweep-id filter: matching pair -> exit 0"

# --- (f) --host without --sweep-id (and vice versa) -> usage error --------
reset_state
cat > "$STUB_DIR/comments.json" <<'JSON'
[{"id": 42, "body": "<!-- loom:lease host=studio-host sweep=sweep-issue-6180-1000 -->\nLease acquired."}]
JSON
run_script renew-once 6180 --host studio-host
assert_eq "1" "$RC" "(f) --host without --sweep-id is a usage error"
run_script renew-once 6180 --sweep-id sweep-issue-6180-1000
assert_eq "1" "$RC" "(f) --sweep-id without --host is a usage error"

# --- (g) start's background loop self-terminates when its watched PID dies,
#     and never renews again after that point ------------------------------
reset_state
cat > "$STUB_DIR/comments.json" <<'JSON'
[
  {"id": 42, "body": "<!-- loom:lease host=studio-host sweep=sweep-issue-6180-1000 -->\nLease acquired."}
]
JSON
sleep 6 &
WATCH_PID=$!
LOOP_PID="$("$SCRIPT" start 6180 --interval 1 --watch-pid "$WATCH_PID" 2>"$STUB_DIR/start-stderr.log")"
sleep 2.5
kill "$WATCH_PID" 2>/dev/null || true
wait "$WATCH_PID" 2>/dev/null || true
sleep 1.5
LOOP_ALIVE="false"
kill -0 "$LOOP_PID" 2>/dev/null && LOOP_ALIVE="true"
assert_true "$([[ "$LOOP_ALIVE" == "false" ]] && echo true || echo false)" "(g) renewal loop self-terminates after its watched PID dies"
COUNT_BEFORE_DEATH="$(wc -l < "$STUB_DIR/patch-calls.log" 2>/dev/null | tr -d ' ')"
COUNT_BEFORE_DEATH="${COUNT_BEFORE_DEATH:-0}"
sleep 2
COUNT_AFTER_WAIT="$(wc -l < "$STUB_DIR/patch-calls.log" 2>/dev/null | tr -d ' ')"
COUNT_AFTER_WAIT="${COUNT_AFTER_WAIT:-0}"
assert_eq "$COUNT_BEFORE_DEATH" "$COUNT_AFTER_WAIT" "(g) no further renewals happen once the watched PID is dead"
TESTS_RUN=$((TESTS_RUN + 1))
if ((COUNT_BEFORE_DEATH >= 1)); then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "  ${GREEN}PASS${NC}: (g) at least one renewal happened while the watched PID was alive"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "  ${RED}FAIL${NC}: (g) expected at least one renewal before the watched PID died (got $COUNT_BEFORE_DEATH)"
fi
# Defensive cleanup in case the assertion above failed the self-termination.
kill "$LOOP_PID" 2>/dev/null || true

# --- (h) stop kills a given PID -------------------------------------------
sleep 30 &
BG_PID=$!
"$SCRIPT" stop "$BG_PID" > /dev/null 2>&1
sleep 0.3
STILL_ALIVE="false"
kill -0 "$BG_PID" 2>/dev/null && STILL_ALIVE="true"
assert_true "$([[ "$STILL_ALIVE" == "false" ]] && echo true || echo false)" "(h) stop kills the given PID"
kill "$BG_PID" 2>/dev/null || true

# --- Contract checks (mirrors test-check-quarantine-stashes.sh's style) ---
"$SCRIPT" --help > "$STUB_DIR/help.out" 2>&1
HELP_RC=$?
assert_true "$([[ -s "$STUB_DIR/help.out" ]] && echo true || echo false)" "--help prints usage text"
assert_eq "1" "$HELP_RC" "--help exits 1 (usage-exit convention, matches sweep-run-registry.sh)"
"$SCRIPT" bogus-command > /dev/null 2>&1
BOGUS_RC=$?
assert_true "$([[ "$BOGUS_RC" -ne 0 ]] && echo true || echo false)" "an unknown command exits non-zero"

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
if ((TESTS_FAILED > 0)); then
    echo -e "${RED}FAILED${NC}: $TESTS_FAILED test(s) failed"
    exit 1
fi
echo -e "${GREEN}ALL PASSED${NC}"
exit 0
