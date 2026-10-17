#!/usr/bin/env bash
# hemma/scripts/run-hooks.sh — execute .hemma-hooks for files changed in a
# system-apply deploy.
#
# Hook line format:  glob[!class]:command
#   glob   shell-style relative path glob (matched against changed files
#          scoped to the hook file's base dir, e.g. etc/.hemma-hooks
#          matches paths under etc/)
#   class  optional, one of: safe | disruptive | risky
#          (untagged = manual, skip-by-default)
#   command  arbitrary shell command, run on the target via ssh
#
# Class semantics (defaults, no flags):
#   !safe        auto-run         idempotent, no service interruption
#   !disruptive  auto-run         brief restart, no state corruption
#   !risky       SKIP             cascading/hard-to-reverse; opt in with --run-risky-hooks
#   untagged     SKIP             pre-classification baseline; opt in with --run-untagged-hooks
#
# Flags:
#   --no-hooks              kill switch — skip all
#   --no-disruptive-hooks   downgrade default; only safe runs
#   --run-risky-hooks       opt into risky class
#   --run-untagged-hooks    opt into untagged
#   --dry-run-hooks         print plan, do not execute
#
# Inputs:
#   --host NAME            host short name (e.g., "server"), used to find overlay
#   --target SSH_ALIAS     ssh destination (e.g., "server" or "server.lan")
#   --sysdir DIR           dotfiles/system dir
#   --role ROLES           comma-separated roles (e.g., "router" or "iot,nas")
#   --changes-file FILE    tmpfile of changed paths (one per line, format: <base>/<relpath>)
#
# Algorithm:
#   1. Collect .hemma-hooks files in role-composition order:
#        common/<base>/ → roles/<role>/<base>/ → <host>/<base>/
#   2. Parse each non-comment, non-blank line into (glob, class, cmd)
#   3. Match each line's glob against changed-file relpaths (scoped to hook file's base)
#   4. Dedupe matched commands across files (same cmd fires once; first class wins)
#   5. Filter by class against opt-in flags
#   6. Execute via ssh, continue on individual failure, report counts at end
#
# Exit code: 0 on success or nothing-to-do; 1 if any executed hook failed; 2 on usage error.

set -uo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
HOST=""
TARGET=""
SYSDIR=""
ROLE=""
CHANGES_FILE=""
NO_HOOKS=false
NO_DISRUPTIVE=false
RUN_RISKY=false
RUN_UNTAGGED=false
DRY_RUN=false

# ── ANSI colors (only if stdout is a tty) ────────────────────────────────────
if [[ -t 1 ]]; then
    GREEN=$'\033[32m'
    RED=$'\033[31m'
    YELLOW=$'\033[33m'
    CYAN=$'\033[36m'
    DIM=$'\033[2m'
    BOLD=$'\033[1m'
    RESET=$'\033[0m'
else
    GREEN=""; RED=""; YELLOW=""; CYAN=""; DIM=""; BOLD=""; RESET=""
fi

# ── Parse args ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)             HOST="${2:-}"; shift 2 ;;
        --target)           TARGET="${2:-}"; shift 2 ;;
        --sysdir)           SYSDIR="${2:-}"; shift 2 ;;
        --role)             ROLE="${2:-}"; shift 2 ;;
        --changes-file)     CHANGES_FILE="${2:-}"; shift 2 ;;
        --no-hooks)         NO_HOOKS=true; shift ;;
        --no-disruptive-hooks) NO_DISRUPTIVE=true; shift ;;
        --run-risky-hooks)  RUN_RISKY=true; shift ;;
        --run-untagged-hooks) RUN_UNTAGGED=true; shift ;;
        --dry-run-hooks)    DRY_RUN=true; shift ;;
        -h|--help)
            sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            printf "%s: unknown flag: %s\n" "$(basename "$0")" "$1" >&2
            exit 2
            ;;
    esac
done

# ── Validate ──────────────────────────────────────────────────────────────────
if [[ -z "$HOST" || -z "$TARGET" || -z "$SYSDIR" || -z "$CHANGES_FILE" ]]; then
    printf "Usage: %s --host NAME --target SSH --sysdir DIR [--role ROLES] --changes-file FILE [flags]\n" \
        "$(basename "$0")" >&2
    exit 2
fi

# ── Early exit: --no-hooks ───────────────────────────────────────────────────
if [[ "$NO_HOOKS" == "true" ]]; then
    printf "%shemma%s: hooks disabled (--no-hooks)\n" "$CYAN" "$RESET"
    exit 0
fi

# ── Early exit: no changes ───────────────────────────────────────────────────
if [[ ! -s "$CHANGES_FILE" ]]; then
    # Empty changes file = nothing to fire hooks for
    exit 0
fi

# ── Collect .hemma-hooks files in role-composition order ─────────────────────
# common/<base>/.hemma-hooks → roles/<role>/<base>/.hemma-hooks → <host>/<base>/.hemma-hooks
HOOK_FILES=()  # entries: "<base>:<full-path-to-hemma-hooks>"
for base in etc opt usr; do
    [[ -f "$SYSDIR/common/$base/.hemma-hooks" ]] && \
        HOOK_FILES+=("$base:$SYSDIR/common/$base/.hemma-hooks")
    if [[ -n "$ROLE" ]]; then
        IFS=',' read -ra ROLES <<< "$ROLE"
        for r in "${ROLES[@]}"; do
            [[ -f "$SYSDIR/roles/$r/$base/.hemma-hooks" ]] && \
                HOOK_FILES+=("$base:$SYSDIR/roles/$r/$base/.hemma-hooks")
        done
    fi
    [[ -f "$SYSDIR/$HOST/$base/.hemma-hooks" ]] && \
        HOOK_FILES+=("$base:$SYSDIR/$HOST/$base/.hemma-hooks")
done

if [[ ${#HOOK_FILES[@]} -eq 0 ]]; then
    # No hooks defined for this host across any layer
    exit 0
fi

# ── Read changed files into array ────────────────────────────────────────────
CHANGED=()
while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    CHANGED+=("$path")
done < "$CHANGES_FILE"

if [[ ${#CHANGED[@]} -eq 0 ]]; then
    exit 0
fi

# ── Parse hooks + match globs against changed files ──────────────────────────
declare -A QUEUED_CLASS    # cmd → class (first wins; common → role → host)
declare -A QUEUED_SOURCE   # cmd → source file (debug aid)
QUEUED_ORDER=()            # preserves insertion order for stable output

for entry in "${HOOK_FILES[@]}"; do
    hook_base="${entry%%:*}"
    hook_file="${entry#*:}"

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip blank lines + comments
        [[ -z "${line// }" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        # Split on FIRST colon (commands may contain colons, e.g., --to-destination IP:53)
        if [[ "$line" != *:* ]]; then
            printf "%sWarning%s: malformed hook line in %s: %s\n" \
                "$YELLOW" "$RESET" "$hook_file" "$line" >&2
            continue
        fi
        lhs="${line%%:*}"
        cmd="${line#*:}"

        # Extract optional !class suffix
        class="untagged"
        glob="$lhs"
        if [[ "$lhs" =~ ^(.*)!(safe|disruptive|risky)$ ]]; then
            glob="${BASH_REMATCH[1]}"
            class="${BASH_REMATCH[2]}"
        fi

        # Match glob against changed files scoped to this hook's base dir
        matched=false
        for changed in "${CHANGED[@]}"; do
            changed_base="${changed%%/*}"
            changed_rel="${changed#*/}"
            [[ "$changed_base" == "$hook_base" ]] || continue
            # Unquoted $glob = bash pattern expansion in case statement
            # In a case pattern bash * DOES span / (tested 2026-10-17:
            # systemd/system/*.service matches systemd/system/a/b.service), so
            # cron.d/* would also match a nested path; no overlay has one.
            case "$changed_rel" in
                $glob) matched=true; break ;;
            esac
        done

        if [[ "$matched" == "true" ]]; then
            # First class wins — common is processed first, then roles, then host.
            # In practice no two hook files share an identical command with different
            # classes, but if they ever do, the more-general (common) wins, which
            # is the conservative default.
            if [[ -z "${QUEUED_CLASS[$cmd]:-}" ]]; then
                QUEUED_CLASS[$cmd]="$class"
                QUEUED_SOURCE[$cmd]="$hook_file"
                QUEUED_ORDER+=("$cmd")
            fi
        fi
    done < "$hook_file"
done

if [[ ${#QUEUED_ORDER[@]} -eq 0 ]]; then
    # No hook globs matched any changed file
    exit 0
fi

# ── Filter by class against opt-in flags ─────────────────────────────────────
TO_RUN=()    # entries: "<class>|<cmd>"
TO_SKIP=()   # entries: "<class>|<cmd>|<reason>"

for cmd in "${QUEUED_ORDER[@]}"; do
    class="${QUEUED_CLASS[$cmd]}"
    decision="run"
    reason=""

    case "$class" in
        safe)
            ;;
        disruptive)
            if [[ "$NO_DISRUPTIVE" == "true" ]]; then
                decision="skip"; reason="--no-disruptive-hooks"
            fi
            ;;
        risky)
            if [[ "$RUN_RISKY" != "true" ]]; then
                decision="skip"; reason="!risky (opt in: --run-risky-hooks)"
            fi
            ;;
        untagged)
            if [[ "$RUN_UNTAGGED" != "true" ]]; then
                decision="skip"; reason="untagged (opt in: --run-untagged-hooks)"
            fi
            ;;
    esac

    if [[ "$decision" == "run" ]]; then
        TO_RUN+=("$class|$cmd")
    else
        TO_SKIP+=("$class|$cmd|$reason")
    fi
done

# ── Report execution plan ────────────────────────────────────────────────────
printf "\n%s%shemma%s: hook execution plan for %s\n" "$BOLD" "$CYAN" "$RESET" "$HOST"

if [[ ${#TO_RUN[@]} -gt 0 ]]; then
    printf "  %sWill run%s (%d):\n" "$GREEN" "$RESET" "${#TO_RUN[@]}"
    for entry in "${TO_RUN[@]}"; do
        cls="${entry%%|*}"
        cmd="${entry#*|}"
        printf "    [%s%s%s] %s\n" "$CYAN" "$cls" "$RESET" "$cmd"
    done
fi

if [[ ${#TO_SKIP[@]} -gt 0 ]]; then
    printf "  %sWill skip%s (%d):\n" "$DIM" "$RESET" "${#TO_SKIP[@]}"
    for entry in "${TO_SKIP[@]}"; do
        cls="${entry%%|*}"
        rest="${entry#*|}"
        cmd="${rest%|*}"
        reason="${rest##*|}"
        printf "    [%s%s%s] %s  %s(%s)%s\n" \
            "$DIM" "$cls" "$RESET" "$cmd" "$DIM" "$reason" "$RESET"
    done
fi

# ── Dry-run exit ─────────────────────────────────────────────────────────────
if [[ "$DRY_RUN" == "true" ]]; then
    printf "\n%shemma%s: --dry-run-hooks set, exiting without executing\n" "$YELLOW" "$RESET"
    exit 0
fi

if [[ ${#TO_RUN[@]} -eq 0 ]]; then
    printf "\n%shemma%s: nothing to run\n" "$CYAN" "$RESET"
    exit 0
fi

# ── Execute ──────────────────────────────────────────────────────────────────
printf "\n%shemma%s: executing %d hook(s) on %s...\n" \
    "$CYAN" "$RESET" "${#TO_RUN[@]}" "$HOST"
failed=0
ok=0
for entry in "${TO_RUN[@]}"; do
    cls="${entry%%|*}"
    cmd="${entry#*|}"
    printf "  ▸ [%s%s%s] %s ... " "$CYAN" "$cls" "$RESET" "$cmd"
    output=$(ssh -o ConnectTimeout=10 "$TARGET" "$cmd" 2>&1) && rc=0 || rc=$?
    if [[ $rc -eq 0 ]]; then
        printf "%sOK%s\n" "$GREEN" "$RESET"
        ok=$((ok + 1))
    else
        printf "%sFAILED%s (exit %d)\n" "$RED" "$RESET" "$rc"
        if [[ -n "$output" ]]; then
            printf "%s\n" "$output" | sed "s/^/      /"
        fi
        failed=$((failed + 1))
    fi
done

# ── Summary + exit ───────────────────────────────────────────────────────────
if [[ $failed -gt 0 ]]; then
    printf "\n%shemma%s: %d ok, %s%d failed%s\n" \
        "$YELLOW" "$RESET" "$ok" "$RED" "$failed" "$RESET" >&2
    exit 1
fi

printf "\n%shemma%s: all %d hook(s) completed successfully\n" "$GREEN" "$RESET" "$ok"
exit 0
