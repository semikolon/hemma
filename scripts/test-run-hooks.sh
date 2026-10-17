#!/usr/bin/env bash
# Test harness for run-hooks.sh.
#
# Builds a synthetic sysdir + hooks files + changes file, invokes run-hooks.sh
# in --dry-run-hooks mode, and grep-checks the printed plan. Does NOT touch
# any remote — all assertions are against stdout.
#
# Run: bash scripts/test-run-hooks.sh   (from the hemma repo)
# Exit: 0 if all tests pass, 1 on first failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EXECUTOR="$SCRIPT_DIR/run-hooks.sh"

if [[ ! -x "$EXECUTOR" ]]; then
    printf "FAIL: %s not found or not executable\n" "$EXECUTOR" >&2
    exit 1
fi

# ── Setup synthetic fleet ────────────────────────────────────────────────────
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

SYSDIR="$WORK/system"
mkdir -p "$SYSDIR"/{common/etc,roles/router/etc,roles/router/opt,host1/etc,host1/opt}

# common/etc/.hemma-hooks
cat > "$SYSDIR/common/etc/.hemma-hooks" <<'EOF'
# common hooks
ssh/sshd_config.d/*!disruptive:sudo systemctl restart sshd
EOF

# roles/router/etc/.hemma-hooks
# NB: iptables command contains colons (DNAT --to-destination IP:53 syntax)
# to verify the parser handles colons in commands correctly.
cat > "$SYSDIR/roles/router/etc/.hemma-hooks" <<'EOF'
# router role
systemd/system/*.service!safe:sudo systemctl daemon-reload
iptables/*!disruptive:sudo iptables -t nat -I PREROUTING -j DNAT --to-destination 192.168.1.1:53 && sudo iptables-restore < /etc/iptables/rules.v4
netplan/*!risky:sudo netplan apply
EOF

# host1/etc/.hemma-hooks
cat > "$SYSDIR/host1/etc/.hemma-hooks" <<'EOF'
# host-specific
docker/*!risky:sudo systemctl restart docker
sysctl.d/*!safe:sudo sysctl --system
legacy/*:sudo echo legacy-untagged
EOF

# host1/opt/.hemma-hooks
cat > "$SYSDIR/host1/opt/.hemma-hooks" <<'EOF'
AdGuardHome/AdGuardHome.yaml!safe:bash render-secrets.sh
AdGuardHome/*!disruptive:sudo systemctl restart AdGuardHome
EOF

# ── Test helper ──────────────────────────────────────────────────────────────
TESTS_RUN=0
TESTS_FAILED=0

# Extract just the content of the "Will run" or "Will skip" subsection.
# Awk state machine: enter section on header, stay while indented [...] lines flow.
section_content() {
    local out="$1"
    local section="$2"  # "run" or "skip"
    local header_re
    if [[ "$section" == "run" ]]; then
        header_re='Will run'
    else
        header_re='Will skip'
    fi
    echo "$out" | awk -v hre="$header_re" '
        $0 ~ hre { in_sect=1; next }
        in_sect && /^[[:space:]]+\[/ { print; next }
        in_sect && /^[[:space:]]*$/ { in_sect=0; next }
        /^[[:space:]]+Will/ { in_sect=0 }
    '
}

# Match a pattern within a specific section.
in_section() {
    local out="$1"
    local section="$2"
    local pattern="$3"
    section_content "$out" "$section" | grep -qE "$pattern"
}

# expect: pattern must appear in <section> ("run" | "skip" | "any")
run_test() {
    local name="$1"; shift
    local changes_lines="$1"; shift
    local section="$1"; shift
    local expect_pattern="$1"; shift
    local extra_flags="$*"

    TESTS_RUN=$((TESTS_RUN + 1))

    local changes_file
    changes_file=$(mktemp)
    printf "%b" "$changes_lines" > "$changes_file"

    local out
    out=$("$EXECUTOR" \
        --host host1 \
        --target host1.test \
        --sysdir "$SYSDIR" \
        --role router \
        --changes-file "$changes_file" \
        --dry-run-hooks $extra_flags 2>&1) || true

    rm -f "$changes_file"

    local found=false
    case "$section" in
        run|skip)
            in_section "$out" "$section" "$expect_pattern" && found=true
            ;;
        any)
            echo "$out" | grep -qE "$expect_pattern" && found=true
            ;;
    esac

    if [[ "$found" == "true" ]]; then
        printf "  PASS  %s\n" "$name"
    else
        printf "  FAIL  %s\n" "$name"
        printf "         expected (in section=%s): %s\n" "$section" "$expect_pattern"
        printf "         actual output:\n"
        echo "$out" | sed 's/^/           /'
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# expect: pattern must NOT appear anywhere in the output
run_test_no_match() {
    local name="$1"; shift
    local changes_lines="$1"; shift
    local forbid_pattern="$1"; shift
    local extra_flags="$*"

    TESTS_RUN=$((TESTS_RUN + 1))

    local changes_file
    changes_file=$(mktemp)
    printf "%b" "$changes_lines" > "$changes_file"

    local out
    out=$("$EXECUTOR" \
        --host host1 \
        --target host1.test \
        --sysdir "$SYSDIR" \
        --role router \
        --changes-file "$changes_file" \
        --dry-run-hooks $extra_flags 2>&1) || true

    rm -f "$changes_file"

    if echo "$out" | grep -qE "$forbid_pattern"; then
        printf "  FAIL  %s\n" "$name"
        printf "         forbidden match found: %s\n" "$forbid_pattern"
        printf "         actual output:\n"
        echo "$out" | sed 's/^/           /'
        TESTS_FAILED=$((TESTS_FAILED + 1))
    else
        printf "  PASS  %s\n" "$name"
    fi
}

# ── Tests ────────────────────────────────────────────────────────────────────
printf "Running run-hooks.sh tests against %s\n\n" "$EXECUTOR"

# 1. Empty changes file → no plan output at all
echo "[1] empty changes"
EMPTY_FILE=$(mktemp)
out=$("$EXECUTOR" --host host1 --target h --sysdir "$SYSDIR" --role router \
    --changes-file "$EMPTY_FILE" --dry-run-hooks 2>&1) || true
rm -f "$EMPTY_FILE"
TESTS_RUN=$((TESTS_RUN + 1))
if [[ -z "$out" ]]; then
    echo "  PASS  empty changes → empty output"
else
    echo "  FAIL  empty changes → produced output: $out"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi
echo

# 2. !safe class auto-runs
echo "[2] !safe class"
run_test "daemon-reload (safe) auto-runs on .service change" \
    "etc/systemd/system/foo.service\n" \
    run \
    '\[safe\] sudo systemctl daemon-reload'

# 3. !disruptive class auto-runs by default
echo "[3] !disruptive class default"
run_test "iptables (disruptive) auto-runs on rules.v4" \
    "etc/iptables/rules.v4\n" \
    run \
    '\[disruptive\] sudo iptables -t nat'

# 4. !risky class skips by default
echo "[4] !risky class default"
run_test "docker restart (risky) skipped without --run-risky-hooks" \
    "etc/docker/daemon.json\n" \
    skip \
    '\[risky\] sudo systemctl restart docker'

# 5. !risky class with --run-risky-hooks → runs
echo "[5] !risky with opt-in"
run_test "docker restart runs with --run-risky-hooks" \
    "etc/docker/daemon.json\n" \
    run \
    '\[risky\] sudo systemctl restart docker' \
    --run-risky-hooks

# 6. Untagged class skips by default
echo "[6] untagged skips"
run_test "untagged hook skipped without --run-untagged-hooks" \
    "etc/legacy/foo\n" \
    skip \
    '\[untagged\] sudo echo legacy-untagged'

# 7. Untagged with --run-untagged-hooks → runs
echo "[7] untagged with opt-in"
run_test "untagged runs with --run-untagged-hooks" \
    "etc/legacy/foo\n" \
    run \
    '\[untagged\]' \
    --run-untagged-hooks

# 8. Glob with colon in command (iptables --to-destination IP:53) parses correctly
echo "[8] colon in command"
run_test "command containing colons preserved" \
    "etc/iptables/rules.v4\n" \
    any \
    '192.168.1.1:53'

# 9. Single-level * does NOT cross /
echo "[9] glob scoping"
run_test_no_match "systemd/system/*.service does NOT match nested override.conf" \
    "etc/systemd/system/foo/override.conf\n" \
    '\[safe\] sudo systemctl daemon-reload'

# 10. Exact-match glob (AdGuardHome.yaml) → safe class wins over wildcard disruptive
echo "[10] exact match over wildcard"
run_test "AdGuardHome.yaml → safe (render-secrets), not just disruptive restart" \
    "opt/AdGuardHome/AdGuardHome.yaml\n" \
    run \
    '\[safe\] bash render-secrets.sh'

# 11. Wildcard match for non-yaml AGH file → disruptive
echo "[11] AGH wildcard for non-yaml"
run_test "non-yaml AGH change → disruptive restart" \
    "opt/AdGuardHome/filters.txt\n" \
    run \
    '\[disruptive\] sudo systemctl restart AdGuardHome'

# 12. --no-hooks → no plan output
echo "[12] --no-hooks kill switch"
NO_FILE=$(mktemp)
echo "etc/docker/daemon.json" > "$NO_FILE"
out=$("$EXECUTOR" --host host1 --target h --sysdir "$SYSDIR" --role router \
    --changes-file "$NO_FILE" --no-hooks 2>&1) || true
rm -f "$NO_FILE"
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$out" | grep -q "hooks disabled"; then
    echo "  PASS  --no-hooks → kill switch fires"
else
    echo "  FAIL  --no-hooks → expected 'hooks disabled', got: $out"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi
echo

# 13. --no-disruptive-hooks drops disruptive but keeps safe
echo "[13] --no-disruptive-hooks"
run_test "--no-disruptive-hooks puts iptables in skip" \
    "etc/iptables/rules.v4\netc/systemd/system/foo.service\n" \
    skip \
    '\[disruptive\] sudo iptables -t nat' \
    --no-disruptive-hooks
run_test "--no-disruptive-hooks keeps daemon-reload running" \
    "etc/iptables/rules.v4\netc/systemd/system/foo.service\n" \
    run \
    '\[safe\] sudo systemctl daemon-reload' \
    --no-disruptive-hooks

# 14. Role composition: common + router-role + host all contribute
echo "[14] role composition"
# Trigger one hook from each layer in a single deploy
run_test "all three layers fire when their globs match" \
    "etc/ssh/sshd_config.d/extra.conf\netc/iptables/rules.v4\netc/sysctl.d/99-tune.conf\n" \
    run \
    '\[disruptive\] sudo systemctl restart sshd'

# 15. Dedup: same command from two files fires once
echo "[15] dedup"
# Both common AND host can contain identical commands; verify dedup.
# Add a duplicate to common temporarily.
echo "ssh/sshd_config.d/*!disruptive:sudo systemctl restart sshd" >> "$SYSDIR/host1/etc/.hemma-hooks"
DEDUP_FILE=$(mktemp)
echo "etc/ssh/sshd_config.d/foo.conf" > "$DEDUP_FILE"
out=$("$EXECUTOR" --host host1 --target h --sysdir "$SYSDIR" --role router \
    --changes-file "$DEDUP_FILE" --dry-run-hooks 2>&1) || true
rm -f "$DEDUP_FILE"
TESTS_RUN=$((TESTS_RUN + 1))
restart_count=$(echo "$out" | grep -c "systemctl restart sshd" || true)
if [[ "$restart_count" -eq 1 ]]; then
    echo "  PASS  same command from common + host → queued once"
else
    echo "  FAIL  expected 1 sshd line, got $restart_count"
    echo "$out" | sed 's/^/         /'
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi
# Restore host1 file
sed -i.bak '/^ssh\/sshd_config\.d\/\*!disruptive/d' "$SYSDIR/host1/etc/.hemma-hooks"
rm -f "$SYSDIR/host1/etc/.hemma-hooks.bak"
echo

# 16. Base-scoping: etc hook ignores opt-base changes
echo "[16] base-scoping"
run_test_no_match "etc/.hemma-hooks globs don't match opt/ paths" \
    "opt/some-random-thing\n" \
    'Will run'

# 17. Class-precedence: first wins (common's class beats host's for same cmd)
echo "[17] first-class-wins precedence"
# common says sshd restart is !disruptive; pretend host says !risky.
# Add risky-tagged duplicate to host.
echo "ssh/sshd_config.d/*!risky:sudo systemctl restart sshd" >> "$SYSDIR/host1/etc/.hemma-hooks"
PREC_FILE=$(mktemp)
echo "etc/ssh/sshd_config.d/foo.conf" > "$PREC_FILE"
out=$("$EXECUTOR" --host host1 --target h --sysdir "$SYSDIR" --role router \
    --changes-file "$PREC_FILE" --dry-run-hooks 2>&1) || true
rm -f "$PREC_FILE"
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$out" | grep -q '\[disruptive\] sudo systemctl restart sshd'; then
    echo "  PASS  first class (common's disruptive) wins over host's risky"
else
    echo "  FAIL  expected first-class-wins, got:"
    echo "$out" | sed 's/^/         /'
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi
# Restore
sed -i.bak '/^ssh\/sshd_config\.d\/\*!risky/d' "$SYSDIR/host1/etc/.hemma-hooks"
rm -f "$SYSDIR/host1/etc/.hemma-hooks.bak"
echo

# 18. Localhost execution path — exercises the real ssh dispatch + exit-code +
#     OK/FAILED branching + summary + exit code. Gated: skipped (not failed) if
#     ssh localhost is unavailable, so the suite stays portable (CI, a laptop).
echo "[18] localhost ssh execution path"
if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
        localhost true 2>/dev/null; then
    EXEC_DIR="$WORK/execsys"
    mkdir -p "$EXEC_DIR/host1/etc"
    cat > "$EXEC_DIR/host1/etc/.hemma-hooks" <<'EOF'
probe-ok/*!safe:echo probe-ran
probe-fail/*!safe:sh -c 'exit 3'
EOF
    EXEC_CHANGES=$(mktemp)
    printf "etc/probe-ok/a\netc/probe-fail/b\n" > "$EXEC_CHANGES"
    exec_out=$("$EXECUTOR" \
        --host host1 --target localhost \
        --sysdir "$EXEC_DIR" --role "" \
        --changes-file "$EXEC_CHANGES" 2>&1) && exec_rc=0 || exec_rc=$?
    rm -f "$EXEC_CHANGES"

    TESTS_RUN=$((TESTS_RUN + 1))
    if echo "$exec_out" | grep -qE 'echo probe-ran \.\.\. OK' \
        && echo "$exec_out" | grep -qE "FAILED \(exit 3\)" \
        && echo "$exec_out" | grep -qE '1 ok, .*1 failed' \
        && [[ "$exec_rc" -eq 1 ]]; then
        echo "  PASS  localhost exec: OK path + FAILED path + summary + exit 1"
    else
        echo "  FAIL  localhost execution path (exec_rc=$exec_rc)"
        echo "$exec_out" | sed 's/^/           /'
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo "  SKIP  localhost execution test (ssh localhost unavailable)"
fi
echo

# ── Summary ─────────────────────────────────────────────────────────────────
printf "\n────────────────────────────────────────────\n"
if [[ $TESTS_FAILED -eq 0 ]]; then
    printf "PASS: %d/%d tests passed\n" "$TESTS_RUN" "$TESTS_RUN"
    exit 0
else
    printf "FAIL: %d/%d tests failed\n" "$TESTS_FAILED" "$TESTS_RUN"
    exit 1
fi
