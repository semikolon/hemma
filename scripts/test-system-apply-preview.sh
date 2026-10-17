#!/usr/bin/env bash
# Regression harness for the `system-apply` recipe's changes-file capture
# pipeline (hemma/Justfile).
#
# BUG (found 2026-05-17 by the first real-host hemma hook-test): the per-base
# capture statement
#     echo "$raw" | grep -E '^[<>]f...(\+\+\+\+|[cs])' | awk ... >> "$changes_file"
# had NO `|| true` (unlike its sibling count-greps `n_new`/`n_chg` two lines
# above, which DO). The `system-apply` recipe runs `set -euo pipefail`
# (recipe-body line, NOT `set shell` — it's a shebang recipe). Whenever a
# deploy-base's preview rsync yields output with zero content-change lines
# (the COMMON case — e.g. a host's byte-identical `usr` base) OR an rsync
# error string, the `grep` matches nothing → exits 1 → pipefail → `set -e`
# aborts `system-apply` exit 1, AFTER the preview header printed, BEFORE the
# confirm / deploy / hooks. Latent since the May-13 commit that added the line.
#
# This test EXTRACTS the real capture statement from the Justfile (so it can
# never drift from the source it guards) and exercises it directly under
# `bash -euo pipefail` with crafted `raw`. No `just`, no ssh/rsync mocks, no
# interactive read — deterministic, portable (CI, a laptop), pins exactly the bug.
#
# Run:  bash scripts/test-system-apply-preview.sh   (from the hemma repo)
# Exit: 0 if all tests pass, 1 on any failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
JUSTFILE="$SCRIPT_DIR/../Justfile"

if [[ ! -f "$JUSTFILE" ]]; then
    printf "FAIL: Justfile not found at %s\n" "$JUSTFILE" >&2
    exit 1
fi

# ── Extract the real capture statement ───────────────────────────────────────
# Join backslash-continuations into single logical lines, then pick the one
# logical line that pipes grep into the changes_file append. Ties the test to
# the actual source: if the statement is restructured, extraction still finds
# it by its stable landmarks (grep -E … >> "$changes_file").
CAPTURE_STMT=$(
    awk '{
        line=$0
        while (line ~ /\\[[:space:]]*$/) {
            sub(/\\[[:space:]]*$/, "", line)
            if ((getline nxt) <= 0) break
            line = line nxt
        }
        print line
    }' "$JUSTFILE" \
    | grep -F 'grep -E' \
    | grep -F '>> "$changes_file"' \
    | head -1 \
    | sed 's/^[[:space:]]*//'
)

if [[ -z "$CAPTURE_STMT" ]]; then
    printf "FAIL: could not locate the changes-file capture statement in %s\n" "$JUSTFILE" >&2
    printf "      (recipe structure changed — update this test's extraction landmarks)\n" >&2
    exit 1
fi

printf "Extracted capture statement under test:\n  %s\n\n" "$CAPTURE_STMT"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

TESTS_RUN=0
TESTS_FAILED=0
pass() { printf "  PASS  %s\n" "$1"; }
fail() {
    printf "  FAIL  %s\n" "$1"
    printf "         %s\n" "$2"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

# Run the extracted statement exactly as the recipe would: in a subshell with
# `set -euo pipefail`, with raw/base/changes_file bound. Returns the subshell
# rc (non-zero = the recipe would have aborted here).
run_capture() {
    # Names MUST match what the extracted statement references ($raw/$base/
    # $changes_file) — the subshell inherits these locals for the eval.
    local raw="$1" base="$2" changes_file="$3"
    (
        set -euo pipefail
        # shellcheck disable=SC2034  # used by the eval'd statement
        eval "$CAPTURE_STMT"
    ) 2>/dev/null
}

printf "Running capture-pipeline regression tests\n\n"

# ── Test 1 (THE regression, RED→GREEN): a base whose preview output has NO
#    content-change line must NOT abort the recipe. Pre-fix: pipefail abort
#    (rc≠0) → RED. Post-fix (`|| true`): rc 0, changes_file empty → GREEN.
echo "[1] no-content-change preview output does not abort the capture pipeline"
TESTS_RUN=$((TESTS_RUN + 1))
CF1="$WORK/cf1"; : > "$CF1"
raw=$'>f..t...... aaa.aaa'   # timestamp-only itemize — zero content-change flag
run_capture "$raw" "etc" "$CF1"; rc=$?
if [[ $rc -eq 0 && ! -s "$CF1" ]]; then
    pass "timestamp-only raw → rc 0, changes_file empty (bug fixed)"
else
    fail "no-content-change base aborted the capture pipeline (the line-974 pipefail bug)" \
         "expected rc=0 + empty changes_file — got rc=$rc, changes_file $( [[ -s "$CF1" ]] && echo non-empty || echo empty )"
fi
echo

# ── Test 2 (the same bug's broader face): an rsync ERROR string as raw (any
#    base whose preview rsync failed) must also not abort. Same RED→GREEN.
echo "[2] rsync-error raw does not abort the capture pipeline"
TESTS_RUN=$((TESTS_RUN + 1))
CF2="$WORK/cf2"; : > "$CF2"
raw=$'rsync: connection unexpectedly closed (0 bytes received so far) [sender]\nrsync error: error in rsync protocol data stream (code 12)'
run_capture "$raw" "etc" "$CF2"; rc=$?
if [[ $rc -eq 0 && ! -s "$CF2" ]]; then
    pass "rsync-error raw → rc 0, changes_file empty (bug fixed)"
else
    fail "rsync-error base aborted the capture pipeline" \
         "expected rc=0 + empty changes_file — got rc=$rc, changes_file $( [[ -s "$CF2" ]] && echo non-empty || echo empty )"
fi
echo

# ── Test 3 (guard: the fix is a provable no-op on the has-changes path):
#    a real content-change line must still be captured into changes_file as
#    "<base>/<relpath>". Passes pre- and post-fix; catches any regression the
#    `|| true` might introduce to the normal path.
echo "[3] content-change preview output is still captured correctly"
TESTS_RUN=$((TESTS_RUN + 1))
CF3="$WORK/cf3"; : > "$CF3"
raw=$'>fcst...... pstore-archive.service'   # real content change (c+s flags)
run_capture "$raw" "etc/systemd/system" "$CF3"; rc=$?
if [[ $rc -eq 0 ]] && grep -qx 'etc/systemd/system/pstore-archive.service' "$CF3"; then
    pass "content-change raw → captured 'etc/systemd/system/pstore-archive.service' (normal path intact)"
else
    fail "content-change line not captured correctly" \
         "expected rc=0 + changes_file containing the path — got rc=$rc, content: $(cat "$CF3" 2>/dev/null)"
fi
echo

# ── Test 4 (drift-check perf regression, RED→GREEN): the reverse drift-check
#    MUST be manifest-scoped (`--files-from=<managed paths>`) so the remote
#    stats ONLY those ~N files — NEVER walking the entire remote /<base>/ tree.
#    Pre-fix used `--existing` + a wholesale `host:/<base>/` source, so the slow
#    SBC walked all 82,951 /usr files = 3 m 26 s (measured 2026-05-17) vs 2.9 s
#    for /etc. Source-tied structural pin (cannot drift): extract the real
#    drift-check block from the Justfile and assert it is --files-from-scoped.
echo "[4] reverse drift-check is --files-from-scoped (no wholesale remote-tree walk)"
TESTS_RUN=$((TESTS_RUN + 1))
DRIFT_BLOCK=$(sed -n '/Drift check: warn if remote files/,/if \[ -n "$drift_list" \]; then/p' "$JUSTFILE")
if [[ -z "$DRIFT_BLOCK" ]]; then
    fail "could not locate the drift-check block in the Justfile" \
         "recipe restructured — update this test's sed landmarks"
elif printf '%s' "$DRIFT_BLOCK" | grep -q -- '--files-from='; then
    pass "drift-check rsync is --files-from= manifest-scoped (no wholesale remote-tree walk)"
else
    fail "reverse drift-check still does a wholesale host:/<base>/ tree walk (the 3m26s /usr perf bug)" \
         "expected '--files-from=' in the drift-check block — not found"
fi
echo

printf "────────────────────────────────────────────\n"
if [[ $TESTS_FAILED -eq 0 ]]; then
    printf "PASS: %d/%d tests passed\n" "$TESTS_RUN" "$TESTS_RUN"
    exit 0
else
    printf "FAIL: %d/%d tests failed\n" "$TESTS_FAILED" "$TESTS_RUN"
    exit 1
fi
