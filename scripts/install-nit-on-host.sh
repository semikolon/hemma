#!/usr/bin/env bash
# Install nit on a remote host + pre-create local.toml + run nit bootstrap.
# Extracted from Justfile Step 6 (May 3, 2026) because Just 1.46+ rejects
# the `\"` escape sequences and ALSO interprets heredoc body lines like
# `machine = '...'` as top-level Just assignments — both incompatible with
# inline shell heredocs writing TOML. This script is the clean separation:
# Justfile orchestrates, this script does the shell work.
#
# Usage:
#     install-nit-on-host.sh <remote-ssh-target> <hostname> <dotfiles-ssh-url>
# Example:
#     install-nit-on-host.sh root@192.168.1.50 myrpi git@github.com:you/dotfiles.git

set -euo pipefail

if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <remote-ssh-target> <hostname> <dotfiles-ssh-url>" >&2
    exit 64
fi

REMOTE="$1"
HOSTNAME_ARG="$2"
DOTFILES_SSH="$3"

# ANSI color (best-effort; fallback to plain text)
if [ -t 1 ]; then
    GREEN=$'\e[32m'; YELLOW=$'\e[33m'; RED=$'\e[31m'; CYAN=$'\e[36m'; RESET=$'\e[0m'
else
    GREEN=''; YELLOW=''; RED=''; CYAN=''; RESET=''
fi

# --- Phase 1: GitHub reachability check ---
if ! ssh -o ConnectTimeout=5 "$REMOTE" "ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no git@github.com 2>&1 | grep -q 'successfully authenticated'" 2>/dev/null; then
    printf "%s⚠%s %s cannot reach github.com (no internet?) — skipping nit install\n" "$YELLOW" "$RESET" "$HOSTNAME_ARG"
    printf "  Run when internet is available:\n"
    printf "    ssh %s 'cargo install --git https://github.com/semikolon/nit --root ~/.local && nit bootstrap %s'\n" "$REMOTE" "$DOTFILES_SSH"
    exit 1
fi

printf "%shemma%s: %s can reach GitHub — installing nit\n" "$CYAN" "$RESET" "$HOSTNAME_ARG"

# --- Phase 2: cargo install nit ---
# pipefail required — without it, the cargo exit code is swallowed by the
# successful `tail` and the SSH command returns 0 even when cargo failed.
# This was the original Step-6-in-Justfile bug that hid a host's first
# bootstrap failure (no cargo present → exit 127 only surfaced at next step).
if ! ssh "$REMOTE" 'set -o pipefail; PATH=$HOME/.cargo/bin:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH cargo install --git https://github.com/semikolon/nit --root $HOME/.local 2>&1 | tail -10'; then
    printf "%s  ⚠%s nit install failed (cargo missing or compile error) — run manually:\n" "$YELLOW" "$RESET"
    printf "    ssh %s 'cargo install --git https://github.com/semikolon/nit --root ~/.local'\n" "$REMOTE"
    printf "    If cargo is missing, re-run bootstrap.sh which now installs Rust toolchain at Step 2b.\n"
    exit 1
fi
printf "%s  ✓%s nit installed on %s\n" "$GREEN" "$RESET" "$HOSTNAME_ARG"

# --- Phase 3: Pre-create local.toml ---
# Generate locally + scp (avoids quoting-hell with inline heredoc-via-ssh)
TMP_LOCAL_TOML=$(mktemp)
trap 'rm -f "$TMP_LOCAL_TOML"' EXIT
cat > "$TMP_LOCAL_TOML" <<EOF
machine = "$HOSTNAME_ARG"
identity = "~/.config/nit/age-key.txt"
EOF
ssh "$REMOTE" 'mkdir -p ~/.config/nit'
scp -q "$TMP_LOCAL_TOML" "$REMOTE:.config/nit/local.toml"
printf "%s  ✓%s ~/.config/nit/local.toml on %s\n" "$GREEN" "$RESET" "$HOSTNAME_ARG"

# --- Phase 4: Migrate chezmoi-era age key if present ---
# Old chezmoi placement was ~/.config/chezmoi/key.txt; nit expects ~/.config/nit/age-key.txt
ssh "$REMOTE" 'if [ -f ~/.config/chezmoi/key.txt ] && [ ! -f ~/.config/nit/age-key.txt ]; then cp ~/.config/chezmoi/key.txt ~/.config/nit/age-key.txt && chmod 600 ~/.config/nit/age-key.txt && echo "migrated chezmoi key → nit"; fi'

# --- Phase 5: nit bootstrap ---
if ssh "$REMOTE" "PATH=\$HOME/.local/bin:\$PATH nit bootstrap '$DOTFILES_SSH'"; then
    printf "%s  ✓%s nit bootstrap succeeded on %s\n" "$GREEN" "$RESET" "$HOSTNAME_ARG"
    exit 0
else
    rc=$?
    printf "%s  ⚠%s nit bootstrap failed (exit %s) — run manually:\n" "$YELLOW" "$RESET" "$rc"
    printf "    ssh %s 'nit bootstrap %s'\n" "$REMOTE" "$DOTFILES_SSH"
    exit "$rc"
fi
