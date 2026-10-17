# hemma — fleet provisioning orchestrator
# Swedish: "at home" — makes every machine feel like home
#
# Usage:
#   just status                  Show fleet status
#   just apply <host>            Run nit update + system overlay on a host
#   just apply-all               Apply to all non-critical hosts
#   just apply-all --force       Apply to ALL hosts including critical
#   just system-diff <host>      Preview system config changes (dry-run)
#   just system-apply <host>     Deploy system config overlay
#   just system-apply-all        Deploy system configs to all non-critical hosts
#   just system-pull <host>      Pull live /etc back to overlay (reverse sync)
#   just system-pull-all         Pull from all non-critical hosts
#   just bootstrap <host>        Bootstrap a new machine (SSH-reachable)
#   just prepare-sd <bootfs> ... Prepare RPi SD card for headless first boot
#   just update                  Update local machine (nit update, immediate)
#   just run <host> <cmd>        Run arbitrary command on a host
#   just run-all <cmd>           Run command on all non-critical hosts
#   just ssh <host>              Open SSH session to a host
#
# RPi provisioning workflow:
#   1. Flash RPi OS image to SD card (e.g., via dd or RPi Imager)
#   2. just prepare-sd /Volumes/bootfs <hostname> <ssid> <wifi_pw> [user]
#   3. Insert SD card, power on — first boot configures WiFi/SSH/user, reboots
#   4. just bootstrap <hostname> <ip> <user>
#   5. nit triggers install Docker, HA, Node-RED, etc.

set shell := ["bash", "-euo", "pipefail", "-c"]

# Prefer Homebrew rsync (3.x) to avoid protocol mismatch with Linux remotes.
# Apple's rsync 2.6.9 (protocol 29) causes false checksum divergence against 3.2+ (protocol 31).
# /opt/homebrew/bin = Apple Silicon, /usr/local/bin = Intel. Harmless on Linux (dirs don't exist).
export PATH := "/opt/homebrew/bin:/usr/local/bin:" + env_var("PATH")

# Where the fleet's data lives (fleet.toml, system/, bootstrap.sh) and where
# hemma itself lives. The `hemma` wrapper exports both; run through `just`
# directly, the defaults apply.
dotfiles_dir := env("HEMMA_DOTFILES", home_directory() + "/dotfiles")
hemma_dir := env("HEMMA_DIR", justfile_directory())

# Fleet inventory — parsed from fleet.toml (single source of truth)
# Format: name:ssh_host:role:critical
fleet := `python3 "${HEMMA_DIR:-.}/parse-fleet.py"`

# Colors
green := "\\033[32m"
red := "\\033[31m"
yellow := "\\033[33m"
cyan := "\\033[36m"
bold := "\\033[1m"
reset := "\\033[0m"

# System overlay directory, inside the dotfiles repo
system_dir := dotfiles_dir + "/system"

# Default recipe — show help
default:
    @just --list --unsorted

# Update local machine (git pull + nit apply via `nit update`)
update:
    #!/usr/bin/env bash
    set -euo pipefail
    printf "{{bold}}{{cyan}}hemma{{reset}} — updating local machine\n\n"
    nit_bin=$(command -v nit || echo "$HOME/.local/bin/nit")
    if [ ! -x "$nit_bin" ]; then
        nit_bin="$HOME/.cargo/bin/nit"
    fi
    "$nit_bin" update
    printf "\n{{green}}Done{{reset}}: local machine updated.\n"

# Show fleet status (nit sync state, git hash, uptime, system overlay drift)
# Pulls ~/.local/share/nit/last-sync.json from each machine for sync health.
status:
    #!/usr/bin/env bash
    set -euo pipefail
    printf "{{bold}}{{cyan}}hemma{{reset}} — fleet status\n\n"
    printf "%-12s %-10s %-8s %-12s %-20s %-20s %s\n" "MACHINE" "ROLE" "STATUS" "HEAD" "UPTIME" "LAST SYNC" "SYS OVERLAY"

    # Helper: parse nit last-sync.json (remote or local). Emits "<result> <drift_n>".
    # Empty output = no status file (never synced under new scheme).
    read_sync() {
        local json="$1"
        [ -z "$json" ] && { echo ""; return; }
        local result drift_n
        result=$(echo "$json" | python3 -c 'import sys, json; d=json.load(sys.stdin); print(d.get("result","?"))' 2>/dev/null || echo "?")
        drift_n=$(echo "$json" | python3 -c 'import sys, json; d=json.load(sys.stdin); print(len(d.get("drift_files",[])))' 2>/dev/null || echo "0")
        echo "$result $drift_n"
    }

    # Local machine first
    local_hash=$(git --git-dir=$HOME/.local/share/nit/repo.git rev-parse --short HEAD 2>/dev/null || echo "n/a")
    local_uptime=$(uptime | sed 's/.*up //' | sed 's/,.*//')
    local_sync_json=$(cat "$HOME/.local/share/nit/last-sync.json" 2>/dev/null || echo "")
    if [ -z "$local_sync_json" ]; then
        sync_summary="{{yellow}}never synced{{reset}}"
    else
        read result drift_n <<< "$(read_sync "$local_sync_json")"
        case "$result" in
            ok)              sync_summary="{{green}}ok{{reset}}" ;;
            aborted_drift)   sync_summary="{{yellow}}drift:${drift_n}{{reset}}" ;;
            pull_failed)     sync_summary="{{red}}pull-fail{{reset}}" ;;
            triggers_failed) sync_summary="{{yellow}}trigger-fail{{reset}}" ;;
            secrets_drift)   sync_summary="{{yellow}}secrets-drift{{reset}}" ;;
            edit_touched)    sync_summary="{{yellow}}edit-touched{{reset}}" ;;
            *)               sync_summary="?" ;;
        esac
    fi
    printf "%-12s %-10s $(printf '{{green}}')%-8s$(printf '{{reset}}') %-12s %-20s %-20b %s\n" \
        "$(hostname -s | cut -c1-12)" "local" "up" "$local_hash" "$local_uptime" "$sync_summary" "-"

    # Remote machines in parallel
    sysdir_base="{{system_dir}}"
    for entry in {{fleet}}; do
        IFS=: read -r name host role critical <<< "$entry"
        (
            if ssh -o ConnectTimeout=3 -o BatchMode=yes "$host" "true" 2>/dev/null; then
                remote_hash=$(ssh -o ConnectTimeout=5 "$host" "git --git-dir=\$HOME/.local/share/nit/repo.git rev-parse --short HEAD 2>/dev/null || echo 'n/a'")
                remote_uptime=$(ssh -o ConnectTimeout=5 "$host" "uptime" 2>/dev/null | sed 's/.*up //' | sed 's/,.*//')
                remote_sync_json=$(ssh -o ConnectTimeout=5 "$host" "cat ~/.local/share/nit/last-sync.json 2>/dev/null || echo ''" 2>/dev/null)
                if [ -z "$remote_sync_json" ]; then
                    cstatus="never synced"
                else
                    read result drift_n <<< "$(read_sync "$remote_sync_json")"
                    case "$result" in
                        ok)              cstatus="ok" ;;
                        aborted_drift)   cstatus="drift:${drift_n}" ;;
                        pull_failed)     cstatus="pull-fail" ;;
                        triggers_failed) cstatus="trigger-fail" ;;
                        secrets_drift)   cstatus="secrets-drift" ;;
                        edit_touched)    cstatus="edit-touched" ;;
                        *)               cstatus="?" ;;
                    esac
                fi

                # System overlay drift check (OS-aware path mapping)
                sys_drift="-"
                has_overlay=false
                for base in etc opt usr Library; do
                    if [ -d "$sysdir_base/common/$base" ] || [ -d "$sysdir_base/$name/$base" ]; then
                        has_overlay=true
                        break
                    fi
                    IFS=',' read -ra _rl <<< "$role"
                    for _r in "${_rl[@]}"; do
                        if [ -d "$sysdir_base/roles/$_r/$base" ]; then
                            has_overlay=true
                            break 2
                        fi
                    done
                done
                if [ "$has_overlay" = "true" ]; then
                    sys_merge=$(mktemp -d)
                    drift_total=0
                    r_os=$(ssh -o ConnectTimeout=5 "$host" "uname -s" 2>/dev/null || echo "unknown")
                    for base in etc opt usr Library; do
                        [ -d "$sysdir_base/common/$base" ] && rsync -a --exclude='.hemma-perms' "$sysdir_base/common/$base/" "$sys_merge/$base/" 2>/dev/null
                        # Role overlays
                        IFS=',' read -ra _rl <<< "$role"
                        for _r in "${_rl[@]}"; do
                            [ -d "$sysdir_base/roles/$_r/$base" ] && rsync -a --exclude='.hemma-perms' "$sysdir_base/roles/$_r/$base/" "$sys_merge/$base/" 2>/dev/null
                        done
                        [ -d "$sysdir_base/$name/$base" ] && rsync -a --exclude='.hemma-perms' "$sysdir_base/$name/$base/" "$sys_merge/$base/" 2>/dev/null
                    done
                    # Remap Library paths for Linux targets
                    if [ "$r_os" != "Darwin" ] && [ -d "$sys_merge/Library/Fonts" ]; then
                        mkdir -p "$sys_merge/usr/local/share/fonts"
                        rsync -a "$sys_merge/Library/Fonts/" "$sys_merge/usr/local/share/fonts/"
                        rm -rf "$sys_merge/Library"
                    elif [ "$r_os" != "Darwin" ]; then
                        rm -rf "$sys_merge/Library" 2>/dev/null || true
                    fi
                    # Check drift on all remaining base dirs
                    for dir in "$sys_merge"/*/; do
                        [ -d "$dir" ] || continue
                        base=$(basename "$dir")
                        drift_n=$(rsync -e "ssh -o ConnectTimeout=5" --rsync-path="sudo rsync" --dry-run --itemize-changes --checksum -rltD \
                            "$dir" "$host:/$base/" 2>/dev/null | grep -c '^[<>]f' || true)
                        drift_total=$((drift_total + drift_n))
                    done
                    if [ "$drift_total" = "0" ]; then
                        sys_drift="clean"
                    else
                        sys_drift="${drift_total} drifted"
                    fi
                    rm -rf "$sys_merge"
                fi

                crit_marker=""
                if [ "$critical" = "true" ]; then crit_marker=" ⚠"; fi
                printf "%-12s %-10s %-8s %-12s %-20s %-16s %s%s\n" \
                    "$name" "$role" "up" "$remote_hash" "$remote_uptime" "$cstatus" "$sys_drift" "$crit_marker"
            else
                printf "%-12s %-10s %-8s %-12s %-20s %-16s %s\n" \
                    "$name" "$role" "DOWN" "-" "-" "-" "-"
            fi
        ) &
    done
    wait

# Apply nit update on a specific host (nit's abort-on-drift is respected)
apply host:
    #!/usr/bin/env bash
    set -euo pipefail
    target_host=""
    is_critical=false

    # Resolve host to SSH alias
    for entry in {{fleet}}; do
        IFS=: read -r name ssh_host role critical <<< "$entry"
        if [ "$name" = "{{host}}" ] || [ "$ssh_host" = "{{host}}" ]; then
            target_host="$ssh_host"
            is_critical="$critical"
            break
        fi
    done

    if [ -z "$target_host" ]; then
        printf "{{red}}Error{{reset}}: Unknown host '{{host}}'. Known hosts:\n"
        for entry in {{fleet}}; do
            IFS=: read -r name ssh_host role critical <<< "$entry"
            crit=""
            if [ "$critical" = "true" ]; then crit=" (critical)"; fi
            printf "  %s (%s)%s\n" "$name" "$role" "$crit"
        done
        exit 1
    fi

    if [ "$is_critical" = "true" ]; then
        printf "{{yellow}}⚠ WARNING{{reset}}: {{host}} is marked as CRITICAL infrastructure.\n"
        printf "Applying changes may affect network connectivity for all machines.\n"
        printf "Continue? [y/N] "
        read -r confirm
        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
            printf "Aborted.\n"
            exit 0
        fi
    fi

    printf "{{cyan}}hemma{{reset}}: running nit update on {{host}} ($target_host)...\n"
    ssh "$target_host" "nit update 2>&1" || {
        rc=$?
        if [ "$rc" = "1" ]; then
            # nit update exit 1 on abort-on-drift — show the drift details + abort hemma
            printf "{{yellow}}BLOCKED{{reset}}: nit update aborted on {{host}} — drift detected.\n"
            printf "  Check status: ssh $target_host 'cat ~/.local/share/nit/last-sync.json'\n"
            printf "  Or:           ssh $target_host 'nit status' — then resolve drift manually.\n"
            exit 1
        else
            printf "{{red}}Failed{{reset}}: nit update on {{host}} exited with $rc\n"
            exit 1
        fi
    }
    printf "{{green}}Done{{reset}}: {{host}} nit updated.\n"

    # Auto-chain system overlay if host has overlay configs
    resolved_name=""
    for entry in {{fleet}}; do
        IFS=: read -r name ssh_host role critical <<< "$entry"
        if [ "$ssh_host" = "$target_host" ]; then
            resolved_name="$name"
            break
        fi
    done
    has_overlay=false
    resolved_role=""
    for entry in {{fleet}}; do
        IFS=: read -r _n _s _r _c <<< "$entry"
        if [ "$_n" = "$resolved_name" ]; then resolved_role="$_r"; break; fi
    done
    for base in etc opt usr Library; do
        if [ -d "{{system_dir}}/common/$base" ] || [ -d "{{system_dir}}/$resolved_name/$base" ]; then
            has_overlay=true
            break
        fi
        IFS=',' read -ra _rl <<< "$resolved_role"
        for _r in "${_rl[@]}"; do
            if [ -d "{{system_dir}}/roles/$_r/$base" ]; then
                has_overlay=true
                break 2
            fi
        done
    done
    if [ "$has_overlay" = "true" ]; then
        printf "{{cyan}}hemma{{reset}}: system overlay found for {{host}}, applying...\n"
        just system-apply "{{host}}" --yes
    fi

# Apply nit update on all non-critical hosts (parallel)
apply-all *flags:
    #!/usr/bin/env bash
    set -euo pipefail
    include_critical=false
    for flag in {{flags}}; do
        if [ "$flag" = "--force" ]; then include_critical=true; fi
    done

    printf "{{bold}}{{cyan}}hemma{{reset}} — applying to fleet\n"

    pids=()
    hosts=()
    tmpdir=$(mktemp -d)

    for entry in {{fleet}}; do
        IFS=: read -r name ssh_host role critical <<< "$entry"

        if [ "$critical" = "true" ] && [ "$include_critical" = "false" ]; then
            printf "  {{yellow}}skip{{reset}} %s (critical — use --force to include)\n" "$name"
            continue
        fi

        (
            printf "  applying %s..." "$name" > "$tmpdir/$name.status"
            if ssh -o ConnectTimeout=5 -o BatchMode=yes "$ssh_host" "nit update" > "$tmpdir/$name.log" 2>&1; then
                printf "  {{green}}✓{{reset}} %s\n" "$name" > "$tmpdir/$name.status"
            else
                rc=$?
                # Inspect nit exit code via log: "aborted: pre-pull drift" = drift abort, not failure
                if grep -q "aborted: pre-pull drift" "$tmpdir/$name.log" 2>/dev/null; then
                    printf "  {{yellow}}⊘{{reset}} %s (drift — resolve manually, see log)\n" "$name" > "$tmpdir/$name.status"
                else
                    printf "  {{red}}✗{{reset}} %s (exit $rc)\n" "$name" > "$tmpdir/$name.status"
                fi
            fi
        ) &
        pids+=($!)
        hosts+=("$name")
    done

    # Wait and report
    failed=0
    for i in "${!pids[@]}"; do
        wait "${pids[$i]}" || true
        printf "%b" "$(cat "$tmpdir/${hosts[$i]}.status")"
        if grep -q "✗" "$tmpdir/${hosts[$i]}.status" 2>/dev/null; then
            ((++failed))
            printf "    Log: %s\n" "$tmpdir/${hosts[$i]}.log"
        fi
    done

    rm -rf "$tmpdir"
    if [ "$failed" -gt 0 ]; then
        printf "\n{{red}}%d host(s) failed.{{reset}}\n" "$failed"
        exit 1
    fi
    printf "\n{{green}}All hosts updated.{{reset}}\n"

# Bootstrap a new machine
bootstrap host ip user="":
    #!/usr/bin/env bash
    set -euo pipefail
    script="{{dotfiles_dir}}/bootstrap.sh"
    if [ ! -f "$script" ]; then
        printf "{{red}}Error{{reset}}: bootstrap.sh not found in {{dotfiles_dir}}\n"
        exit 1
    fi

    # The dotfiles repo the new machine pulls from. Set both, or let hemma read
    # them from nit's remote.
    dotfiles_ssh="${HEMMA_DOTFILES_SSH:-$(nit remote get-url origin 2>/dev/null || true)}"
    dotfiles_repo="${HEMMA_DOTFILES_REPO:-$(printf '%s' "$dotfiles_ssh" | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')}"
    if [ -z "$dotfiles_ssh" ] || [ -z "$dotfiles_repo" ]; then
        printf "{{red}}Error{{reset}}: set HEMMA_DOTFILES_SSH (git@github.com:you/dotfiles.git) and HEMMA_DOTFILES_REPO (you/dotfiles)\n"
        exit 1
    fi
    

    target_user="{{user}}"
    if [ -z "$target_user" ]; then
        printf "SSH user for {{host}} ({{ip}}): "
        read -r target_user
    fi
    remote="${target_user}@{{ip}}"

    printf "{{cyan}}hemma{{reset}}: bootstrapping {{host}} at {{ip}} as $target_user\n"

    # --- Step 1: Copy and run bootstrap.sh on remote ---
    printf "\n{{bold}}Step 1: Copying bootstrap.sh...{{reset}}\n"
    scp "$script" "${remote}:/tmp/bootstrap.sh"

    printf "\n{{bold}}Step 2: Running bootstrap.sh on {{host}}...{{reset}}\n"
    ssh "$remote" "chmod +x /tmp/bootstrap.sh && /tmp/bootstrap.sh"

    # --- Step 3: Register SSH key on GitHub ---
    printf "\n{{bold}}Step 3: Registering SSH key on GitHub...{{reset}}\n"
    ssh_pubkey=$(ssh "$remote" "cat ~/.ssh/id_ed25519.pub")
    if echo "$ssh_pubkey" | gh ssh-key add --title "{{host}}" 2>&1; then
        printf "{{green}}  ✓{{reset}} SSH key added to GitHub\n"
    else
        printf "{{yellow}}  ⚠{{reset}} SSH key may already exist on GitHub (harmless)\n"
    fi

    # --- Step 4: Register deploy key on GitHub ---
    printf "\n{{bold}}Step 4: Registering deploy key on GitHub...{{reset}}\n"
    deploy_pubkey=$(ssh "$remote" "cat ~/.ssh/deploy_dotfiles.pub")
    if echo "$deploy_pubkey" | gh repo deploy-key add --repo "$dotfiles_repo" --title "{{host}}" - 2>&1; then
        printf "{{green}}  ✓{{reset}} deploy key added to $dotfiles_repo\n"
    else
        printf "{{yellow}}  ⚠{{reset}} deploy key may already exist (harmless)\n"
    fi

    # --- Step 5: Add age recipient to tier-all + nit rekey ---
    # Automated via `nit fleet-add-recipient` (idempotent). Adds to tier-all
    # (always applies — all fleet machines need AI/MCP keys), then re-encrypts
    # .age files. Additional tier memberships are left to the operator — a
    # reminder is printed after tier-all.
    printf "\n{{bold}}Step 5: Adding age recipient to tier-all...{{reset}}\n"
    nit_bin=$(command -v nit || echo "$HOME/.local/bin/nit")
    [ -x "$nit_bin" ] || nit_bin="$HOME/.cargo/bin/nit"
    age_pubkey=$(ssh "$remote" "(cat ~/.config/nit/age-key.txt 2>/dev/null || cat ~/.config/chezmoi/key.txt 2>/dev/null) | grep 'public key:' | cut -d: -f2 | tr -d ' '")
    if [ -z "$age_pubkey" ]; then
        printf "{{red}}  ✗{{reset}} Could not read age pubkey from {{host}}\n"
        printf "    Manual fix: ssh $remote 'cat ~/.config/nit/age-key.txt'\n"
    elif ! [[ "$age_pubkey" =~ ^age1 ]]; then
        printf "{{red}}  ✗{{reset}} Pubkey read from {{host}} is malformed: %s\n" "$age_pubkey"
    else
        printf "{{cyan}}  →{{reset}} pubkey: %s\n" "$age_pubkey"
        if "$nit_bin" fleet-add-recipient tier-all "$age_pubkey" --comment "{{host}}" 2>&1; then
            printf "{{green}}  ✓{{reset}} added to tier-all\n"
            if "$nit_bin" rekey 2>&1 | tail -3; then
                printf "{{green}}  ✓{{reset}} nit rekey succeeded (.age files re-encrypted)\n"
            else
                printf "{{yellow}}  ⚠{{reset}} nit rekey failed — run manually: nit rekey\n"
            fi
        else
            printf "{{yellow}}  ⚠{{reset}} fleet-add-recipient failed\n"
        fi
        printf "\n{{yellow}}  Other tiers to consider for {{host}}:{{reset}}\n"
        printf "    any other secret tier in fleet.toml this host should read\n"
        printf "    Add via: nit fleet-add-recipient <tier> %s --comment {{host}} && nit rekey\n" "$age_pubkey"
    fi

    # --- Step 6: Install nit + bootstrap on remote ---
    # Delegated to scripts/install-nit-on-host.sh (extracted May 3, 2026 because
    # Just 1.46+ rejects `\"` in recipe bodies AND interprets heredoc-body lines
    # like `machine = '{{host}}'` as top-level Just assignments — both
    # incompatible with inline ssh+heredoc TOML writing).
    printf "\n{{bold}}Step 6: Installing nit + bootstrapping on {{host}}...{{reset}}\n"
    deploy_ok=false
    helper="$(dirname "$(realpath "$0")")/scripts/install-nit-on-host.sh"
    if [ ! -x "$helper" ]; then
        helper="{{hemma_dir}}/scripts/install-nit-on-host.sh"
    fi
    if [ -x "$helper" ] && "$helper" "$remote" "{{host}}" "$dotfiles_ssh"; then
        deploy_ok=true
    else
        printf "{{yellow}}  ⚠{{reset}} install-nit-on-host.sh failed (exit $?) — see output above for retry guidance\n"
    fi

    # --- Step 7: Apply system config overlay ---
    sysdir="$(dirname "$(realpath "$0")")/../system"
    if [ -d "$sysdir/common" ] || [ -d "$sysdir/{{host}}" ]; then
        printf "\n{{bold}}Step 7: Applying system config overlay...{{reset}}\n"
        if [ "$deploy_ok" = true ]; then
            justdir="$(dirname "$(realpath "$0")")"
            if just --justfile "$justdir/Justfile" system-apply "{{host}}" --yes 2>&1; then
                printf "{{green}}  ✓{{reset}} system overlay applied to {{host}}\n"
            else
                printf "{{yellow}}  ⚠{{reset}} system-apply failed — run manually:\n"
                printf "    hemma system-apply {{host}}\n"
            fi
        else
            printf "{{yellow}}  ⚠{{reset}} skipping system-apply (nit bootstrap didn't complete yet)\n"
            printf "  After nit bootstrap, run: hemma system-apply {{host}}\n"
        fi
    fi

    # --- Summary ---
    printf "\n{{bold}}{{green}}Bootstrap complete for {{host}}!{{reset}}\n"
    has_manual=false

    if [ "$deploy_ok" = false ]; then
        has_manual=true
        printf "\n{{bold}}{{yellow}}Deferred steps (need internet):{{reset}}\n"
        printf "  1. ssh $remote 'cargo install --git https://github.com/semikolon/nit --root ~/.local && nit bootstrap $dotfiles_ssh'\n"
        if [ -d "$sysdir/common" ] || [ -d "$sysdir/{{host}}" ]; then
            printf "  2. hemma system-apply {{host}}\n"
        fi
    fi

    # Check for remaining manual steps
    manual_items=""
    if ! grep -q "Host {{host}}" "$HOME/.ssh/config" 2>/dev/null; then
        manual_items="${manual_items}\n  • Add SSH config entry: Host {{host}} / HostName {{ip}} / User ${target_user}"
    fi
    if ! grep -q "{{host}}" "{{dotfiles_dir}}/fleet.toml" 2>/dev/null; then
        manual_items="${manual_items}\n  • Add {{host}} to {{dotfiles_dir}}/fleet.toml"
    fi
    if [ -n "$manual_items" ]; then
        has_manual=true
        printf "\n{{bold}}{{yellow}}Manual steps:{{reset}}%b\n" "$manual_items"
    fi

    if [ "$has_manual" = false ]; then
        printf "{{green}}No remaining steps — {{host}} is fully provisioned.{{reset}}\n"
    fi

# Run arbitrary command on a host
run host +cmd:
    #!/usr/bin/env bash
    set -euo pipefail
    target_host=""
    for entry in {{fleet}}; do
        IFS=: read -r name ssh_host role critical <<< "$entry"
        if [ "$name" = "{{host}}" ] || [ "$ssh_host" = "{{host}}" ]; then
            target_host="$ssh_host"
            break
        fi
    done
    if [ -z "$target_host" ]; then
        printf "{{red}}Error{{reset}}: Unknown host '{{host}}'\n"
        exit 1
    fi
    ssh "$target_host" "{{cmd}}"

# Run command on all non-critical hosts (parallel)
run-all +cmd:
    #!/usr/bin/env bash
    set -euo pipefail
    for entry in {{fleet}}; do
        IFS=: read -r name ssh_host role critical <<< "$entry"
        if [ "$critical" = "true" ]; then continue; fi
        printf "{{cyan}}%s{{reset}}:\n" "$name"
        ssh -o ConnectTimeout=5 "$ssh_host" "{{cmd}}" 2>&1 | sed 's/^/  /' || true
        printf "\n"
    done

# Open interactive SSH session
ssh host:
    #!/usr/bin/env bash
    set -euo pipefail
    target_host=""
    for entry in {{fleet}}; do
        IFS=: read -r name ssh_host role critical <<< "$entry"
        if [ "$name" = "{{host}}" ] || [ "$ssh_host" = "{{host}}" ]; then
            target_host="$ssh_host"
            break
        fi
    done
    if [ -z "$target_host" ]; then
        printf "{{red}}Error{{reset}}: Unknown host '{{host}}'\n"
        exit 1
    fi
    exec ssh "$target_host"

# Preview system config changes (dry-run, read-only)
system-diff host:
    #!/usr/bin/env bash
    set -euo pipefail
    target_host=""
    host_name=""
    host_role=""

    # Resolve host to SSH alias and canonical name
    for entry in {{fleet}}; do
        IFS=: read -r name ssh_host role critical <<< "$entry"
        if [ "$name" = "{{host}}" ] || [ "$ssh_host" = "{{host}}" ]; then
            target_host="$ssh_host"
            host_name="$name"
            host_role="$role"
            break
        fi
    done

    if [ -z "$target_host" ]; then
        printf "{{red}}Error{{reset}}: Unknown host '{{host}}'. Known hosts:\n"
        for entry in {{fleet}}; do
            IFS=: read -r name ssh_host role critical <<< "$entry"
            printf "  %s (%s)\n" "$name" "$role"
        done
        exit 1
    fi

    sysdir="{{system_dir}}"
    source_bases="etc opt usr Library"

    # Check overlay exists (any source base in common, roles, or host-specific)
    has_overlay=false
    for base in $source_bases; do
        if [ -d "$sysdir/common/$base" ] || [ -d "$sysdir/$host_name/$base" ]; then
            has_overlay=true
            break
        fi
        # Check role overlays
        IFS=',' read -ra _rl <<< "$host_role"
        for _r in "${_rl[@]}"; do
            if [ -d "$sysdir/roles/$_r/$base" ]; then
                has_overlay=true
                break 2
            fi
        done
    done
    if [ "$has_overlay" = "false" ]; then
        printf "{{yellow}}No system overlay{{reset}} for %s (checked common/, roles/, and %s/)\n" "$host_name" "$host_name"
        exit 0
    fi

    # Merge: common → roles → host-specific (last wins)
    mergedir=$(mktemp -d)
    trap 'rm -rf "$mergedir"' EXIT

    for base in $source_bases; do
        if [ -d "$sysdir/common/$base" ]; then
            rsync -a "$sysdir/common/$base/" "$mergedir/$base/"
        fi
        # Role overlays (merge between common and host)
        IFS=',' read -ra role_list <<< "$host_role"
        for r in "${role_list[@]}"; do
            if [ -d "$sysdir/roles/$r/$base" ]; then
                rsync -a "$sysdir/roles/$r/$base/" "$mergedir/$base/"
            fi
        done
        if [ -d "$sysdir/$host_name/$base" ]; then
            rsync -a "$sysdir/$host_name/$base/" "$mergedir/$base/"
        fi
    done

    # Decrypt secrets if any exist
    for base in $source_bases; do
        if [ -d "$sysdir/secrets/$host_name/$base" ]; then
            age_key="$HOME/.config/nit/age-key.txt"
            if [ ! -f "$age_key" ]; then
                printf "{{red}}Error{{reset}}: age key not found at %s\n" "$age_key"
                exit 1
            fi
            find "$sysdir/secrets/$host_name/$base" -name "*.age" -type f | while read -r agefile; do
                relpath="${agefile#$sysdir/secrets/$host_name/$base/}"
                outpath="$mergedir/$base/${relpath%.age}"
                mkdir -p "$(dirname "$outpath")"
                age -d -i "$age_key" "$agefile" > "$outpath"
            done
        fi
    done

    # Remove .hemma-perms from merge (not deployed to remote)
    find "$mergedir" -name ".hemma-perms" -delete 2>/dev/null || true

    # Remove .hemma-hooks from merge (metadata, not deployed to remote — run by executor)
    find "$mergedir" -name ".hemma-hooks" -delete 2>/dev/null || true

    # Remap macOS paths to Linux equivalents on non-Darwin hosts
    remote_os=$(ssh -o ConnectTimeout=5 "$target_host" "uname -s" 2>/dev/null || echo "unknown")
    if [ "$remote_os" = "Darwin" ]; then
        deploy_bases="etc Library"
    else
        deploy_bases="etc"
        # Add opt and usr if present in merged overlay
        [ -d "$mergedir/opt" ] && deploy_bases="$deploy_bases opt"
        [ -d "$mergedir/usr" ] && deploy_bases="$deploy_bases usr"
        # Library/Fonts → /usr/local/share/fonts (system-wide fonts on Linux)
        if [ -d "$mergedir/Library/Fonts" ]; then
            mkdir -p "$mergedir/usr/local/share/fonts"
            rsync -a "$mergedir/Library/Fonts/" "$mergedir/usr/local/share/fonts/"
            echo "$deploy_bases" | grep -q "usr" || deploy_bases="$deploy_bases usr"
        fi
        # Library/Keyboard Layouts — macOS-only, no Linux equivalent
        rm -rf "$mergedir/Library" 2>/dev/null || true
    fi

    printf "{{bold}}{{cyan}}hemma{{reset}} — system-diff for %s (%s)\n\n" "$host_name" "$target_host"

    # Dry-run rsync per deploy base to show what would change
    total_new=0
    total_changed=0
    for base in $deploy_bases; do
        if [ -d "$mergedir/$base" ]; then
            raw=$(rsync -e "ssh" --rsync-path="sudo rsync" --dry-run --itemize-changes --checksum -rltD \
                "$mergedir/$base/" "$target_host:/$base/" 2>&1) || true
            if [ -n "$raw" ]; then
                echo "$raw" | rsync-humanize "$base"
                # Count NEW files (rsync flag `>f+++++++++` — pluses replace c/s)
                n_new=$(echo "$raw" | grep -cE '^[<>]f[^ ]*\+\+\+\+' || true)
                # Count CHANGED files (`>fc......` or `>f.s....` — content differs)
                # Constrain c/s match to flags only (before space) — filenames
                # like "Cardo" or "CircularStd" contain c/s and would otherwise
                # be mis-counted as CHANGED.
                n_chg=$(echo "$raw" | grep -cE '^[<>]f[^ ]*[cs]' || true)
                total_new=$((total_new + n_new))
                total_changed=$((total_changed + n_chg))
            fi
        fi
    done

    total_active=$((total_new + total_changed))
    if [ "$total_active" -eq 0 ]; then
        printf "{{green}}No content changes needed.{{reset}}\n"
    else
        # Break out NEW vs CHANGED so a stale role merge (today's incident:
        # 25 router-era NEW files silently deployed) becomes visible.
        if [ "$total_new" -gt 0 ] && [ "$total_changed" -gt 0 ]; then
            printf "\n{{bold}}%d NEW + %d CHANGED file(s) — review NEW carefully (esp. for stale role-merge surprises).{{reset}}\n" "$total_new" "$total_changed"
        elif [ "$total_new" -gt 0 ]; then
            printf "\n{{bold}}%d NEW file(s) — review carefully (esp. for stale role-merge surprises).{{reset}}\n" "$total_new"
        else
            printf "\n{{bold}}%d file(s) with content changes.{{reset}}\n" "$total_changed"
        fi
    fi

# Deploy system config overlay to a host
system-apply host *flags:
    #!/usr/bin/env bash
    set -euo pipefail
    target_host=""
    host_name=""
    host_role=""
    is_critical=false
    skip_confirm=false

    hook_flags=()
    for flag in {{flags}}; do
        case "$flag" in
            --yes) skip_confirm=true ;;
            --no-hooks|--no-disruptive-hooks|--run-risky-hooks|--run-untagged-hooks|--dry-run-hooks)
                hook_flags+=("$flag") ;;
        esac
    done

    # Resolve host to SSH alias and canonical name
    for entry in {{fleet}}; do
        IFS=: read -r name ssh_host role critical <<< "$entry"
        if [ "$name" = "{{host}}" ] || [ "$ssh_host" = "{{host}}" ]; then
            target_host="$ssh_host"
            host_name="$name"
            host_role="$role"
            is_critical="$critical"
            break
        fi
    done

    if [ -z "$target_host" ]; then
        printf "{{red}}Error{{reset}}: Unknown host '{{host}}'. Known hosts:\n"
        for entry in {{fleet}}; do
            IFS=: read -r name ssh_host role critical <<< "$entry"
            crit=""
            if [ "$critical" = "true" ]; then crit=" (critical)"; fi
            printf "  %s (%s)%s\n" "$name" "$role" "$crit"
        done
        exit 1
    fi

    sysdir="{{system_dir}}"
    source_bases="etc opt usr Library"

    # Check overlay exists (any source base in common, roles, or host-specific)
    has_overlay=false
    for base in $source_bases; do
        if [ -d "$sysdir/common/$base" ] || [ -d "$sysdir/$host_name/$base" ]; then
            has_overlay=true
            break
        fi
        # Check role overlays
        IFS=',' read -ra _rl <<< "$host_role"
        for _r in "${_rl[@]}"; do
            if [ -d "$sysdir/roles/$_r/$base" ]; then
                has_overlay=true
                break 2
            fi
        done
    done
    if [ "$has_overlay" = "false" ]; then
        printf "{{yellow}}No system overlay{{reset}} for %s\n" "$host_name"
        exit 0
    fi

    # Critical host gate
    if [ "$is_critical" = "true" ] && [ "$skip_confirm" = "false" ]; then
        printf "{{yellow}}⚠ WARNING{{reset}}: %s is marked as CRITICAL infrastructure.\n" "$host_name"
        printf "System config changes may affect network connectivity for all machines.\n"
        printf "Continue? [y/N] "
        read -r confirm
        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
            printf "Aborted.\n"
            exit 0
        fi
    fi

    # Merge: common → roles → host-specific (last wins)
    mergedir=$(mktemp -d)
    changes_file=$(mktemp)
    trap 'rm -rf "$mergedir" "$changes_file"' EXIT

    role_files_list=""
    for base in $source_bases; do
        if [ -d "$sysdir/common/$base" ]; then
            rsync -a "$sysdir/common/$base/" "$mergedir/$base/"
        fi
        # Role overlays (merge between common and host)
        IFS=',' read -ra role_list <<< "$host_role"
        for r in "${role_list[@]}"; do
            if [ -d "$sysdir/roles/$r/$base" ]; then
                # Track role files for conflict reporting
                while IFS= read -r rf; do
                    role_files_list="${role_files_list}$base/${rf}\n"
                done < <(cd "$sysdir/roles/$r/$base" && find . -type f ! -name '.hemma-perms' | sed 's|^\./||')
                rsync -a "$sysdir/roles/$r/$base/" "$mergedir/$base/"
            fi
        done
        if [ -d "$sysdir/$host_name/$base" ]; then
            rsync -a "$sysdir/$host_name/$base/" "$mergedir/$base/"
        fi
    done

    # Report role-vs-host overrides (informational)
    if [ -n "$role_files_list" ]; then
        override_count=0
        override_list=""
        while IFS= read -r rf; do
            [ -z "$rf" ] && continue
            # Check if host overlay has the same file
            base="${rf%%/*}"
            relpath="${rf#*/}"
            if [ -f "$sysdir/$host_name/$base/$relpath" ]; then
                override_count=$((override_count + 1))
                override_list="${override_list}  ${rf} (host overrides role)\n"
            fi
        done < <(printf "%b" "$role_files_list")
        if [ "$override_count" -gt 0 ]; then
            printf "{{cyan}}Role merge{{reset}}: %d role file(s) overridden by %s host overlay:\n" "$override_count" "$host_name"
            printf "%b" "$override_list"
            printf "\n"
        fi
    fi

    # Decrypt secrets if any exist
    for base in $source_bases; do
        if [ -d "$sysdir/secrets/$host_name/$base" ]; then
            age_key="$HOME/.config/nit/age-key.txt"
            if [ ! -f "$age_key" ]; then
                printf "{{red}}Error{{reset}}: age key not found at %s\n" "$age_key"
                exit 1
            fi
            find "$sysdir/secrets/$host_name/$base" -name "*.age" -type f | while read -r agefile; do
                relpath="${agefile#$sysdir/secrets/$host_name/$base/}"
                outpath="$mergedir/$base/${relpath%.age}"
                mkdir -p "$(dirname "$outpath")"
                age -d -i "$age_key" "$agefile" > "$outpath"
            done
        fi
    done

    # Capture perms manifests from original sources (NOT merge dir — it gets cleaned)
    # Order: common → roles → host-specific (last wins for duplicate paths) —
    # mirrors the file-merge + hook-collection order so a role can set the mode of
    # an executable it ships (e.g. roles/boot-splash/usr/local/sbin/boot-splash-apply).
    perms_files=()
    for base in $source_bases; do
        if [ -f "$sysdir/common/$base/.hemma-perms" ]; then
            perms_files+=("$base:$sysdir/common/$base/.hemma-perms")
        fi
        IFS=',' read -ra _perm_roles <<< "$host_role"
        for r in "${_perm_roles[@]}"; do
            if [ -f "$sysdir/roles/$r/$base/.hemma-perms" ]; then
                perms_files+=("$base:$sysdir/roles/$r/$base/.hemma-perms")
            fi
        done
        if [ -f "$sysdir/$host_name/$base/.hemma-perms" ]; then
            perms_files+=("$base:$sysdir/$host_name/$base/.hemma-perms")
        fi
    done

    # Remove .hemma-perms from merge (not deployed to remote)
    find "$mergedir" -name ".hemma-perms" -delete 2>/dev/null || true

    # Remove .hemma-hooks from merge (metadata, not deployed to remote — run by executor)
    find "$mergedir" -name ".hemma-hooks" -delete 2>/dev/null || true

    # Remap macOS paths to Linux equivalents on non-Darwin hosts
    remote_os=$(ssh -o ConnectTimeout=5 "$target_host" "uname -s" 2>/dev/null || echo "unknown")
    if [ "$remote_os" = "Darwin" ]; then
        deploy_bases="etc Library"
    else
        deploy_bases="etc"
        # Add opt and usr if present in merged overlay
        [ -d "$mergedir/opt" ] && deploy_bases="$deploy_bases opt"
        [ -d "$mergedir/usr" ] && deploy_bases="$deploy_bases usr"
        # Library/Fonts → /usr/local/share/fonts (system-wide fonts on Linux)
        if [ -d "$mergedir/Library/Fonts" ]; then
            mkdir -p "$mergedir/usr/local/share/fonts"
            rsync -a "$mergedir/Library/Fonts/" "$mergedir/usr/local/share/fonts/"
            echo "$deploy_bases" | grep -q "usr" || deploy_bases="$deploy_bases usr"
        fi
        # Library/Keyboard Layouts — macOS-only, no Linux equivalent
        rm -rf "$mergedir/Library" 2>/dev/null || true
    fi

    # ── Drift check: warn if remote files were modified outside hemma ──
    # Scope each rsync to a MANIFEST of the managed overlay files so the remote
    # stats ONLY those ~N files — it must NEVER walk the entire remote /<base>/
    # tree. A wholesale `host:/<base>/` source made the slow SBC walk all
    # 82,951 /usr files = 3 m 26 s (measured 2026-05-17) just to filter down to
    # ~3 managed files. `--files-from` is the ONLY rsync mechanism that skips
    # the source-tree walk (`--existing`/`--include`/`--exclude` walk-then-
    # filter). Detection semantics unchanged (reverse, --checksum, content-only
    # c/s grep). Perf rationale: docs/DOTFILES_STRATEGY.md § hemma hooks.
    # Regression: hemma/scripts/test-system-apply-preview.sh test [4].
    drift_list=""
    for base in $deploy_bases; do
        if [ -d "$mergedir/$base" ]; then
            # Manifest = managed overlay files, relative to the base root.
            drift_mf=$(mktemp)
            ( cd "$mergedir/$base" && find . -type f | sed 's|^\./||' ) > "$drift_mf"
            if [ -s "$drift_mf" ]; then
                # Reverse (remote → overlay), dry-run, content-only (c/s).
                # --ignore-missing-args: a managed file not yet on the remote is
                # a NEW deploy, not "drift" — skip it silently (no error).
                base_drift=$(rsync -e "ssh" --rsync-path="sudo rsync" --dry-run \
                    --files-from="$drift_mf" --ignore-missing-args \
                    --itemize-changes --checksum -rltD \
                    "$target_host:/$base/" "$mergedir/$base/" 2>/dev/null \
                    | grep -E '^>f[^ ]*[cs]' || true)
                if [ -n "$base_drift" ]; then
                    while IFS= read -r line; do
                        fname=$(echo "$line" | awk '{print $2}')
                        drift_list="${drift_list}  /$base/$fname\n"
                    done <<< "$base_drift"
                fi
            fi
            rm -f "$drift_mf"
        fi
    done
    if [ -n "$drift_list" ]; then
        drift_count=$(printf "%b" "$drift_list" | grep -c '/' || true)
        printf "{{yellow}}⚠ Remote drift detected{{reset}} — %s file(s) on %s differ from overlay:\n" "$drift_count" "$host_name"
        printf "%b" "$drift_list"
        printf "\nThese remote changes will be OVERWRITTEN.\n"
        if [ "$skip_confirm" = "false" ]; then
            printf "\nAction? [O]verwrite all / [S]kip (abort) / [I]nteractive (per-file): "
            read -r drift_action
            case "$drift_action" in
                s|S)
                    printf "Aborted. Run 'hemma system-pull %s' to review remote changes.\n" "$host_name"
                    exit 0
                    ;;
                i|I)
                    # Per-file interactive conflict resolution
                    skip_files=()
                    while IFS= read -r dfile; do
                        [ -z "$dfile" ] && continue
                        dfile=$(echo "$dfile" | sed 's/^  //')
                        printf "\n{{bold}}%s{{reset}}:\n" "$dfile"
                        # Show diff (remote vs overlay)
                        local_file="$mergedir${dfile}"
                        if [ -f "$local_file" ]; then
                            diff_out=$(ssh "$target_host" "sudo cat '$dfile'" 2>/dev/null | diff --color=always -u - "$local_file" 2>/dev/null | head -30 || true)
                            if [ -n "$diff_out" ]; then
                                printf "%s\n" "$diff_out"
                            fi
                        fi
                        printf "  [O]verwrite / [S]kip / [P]ull (save remote to overlay): "
                        read -r file_action
                        case "$file_action" in
                            s|S)
                                skip_files+=("$dfile")
                                ;;
                            p|P)
                                # Pull remote version into overlay source
                                # Determine which source dir (host > role > common)
                                base=$(echo "$dfile" | cut -d/ -f2)
                                relpath=$(echo "$dfile" | cut -d/ -f3-)
                                dest="$sysdir/$host_name/$base/$relpath"
                                mkdir -p "$(dirname "$dest")"
                                ssh "$target_host" "sudo cat '$dfile'" > "$dest" 2>/dev/null
                                printf "  {{green}}Pulled{{reset}} → system/%s/%s/%s\n" "$host_name" "$base" "$relpath"
                                # Also update the merge dir with pulled version
                                cp "$dest" "$local_file"
                                ;;
                            *) ;; # overwrite (default)
                        esac
                    done < <(printf "%b" "$drift_list")
                    # Remove skipped files from merge dir so rsync doesn't deploy them
                    for sf in "${skip_files[@]}"; do
                        rm -f "$mergedir${sf}" 2>/dev/null
                    done
                    ;;
                *) ;; # overwrite all (default, continue)
            esac
        else
            printf "{{yellow}}Proceeding (--yes flag set){{reset}}\n"
        fi
        printf "\n"
    fi

    # Mandatory dry-run preview
    printf "{{bold}}{{cyan}}hemma{{reset}} — system-apply preview for %s\n\n" "$host_name"

    total_changed=0
    for base in $deploy_bases; do
        if [ -d "$mergedir/$base" ]; then
            raw=$(rsync -e "ssh" --rsync-path="sudo rsync" --dry-run --itemize-changes --checksum -rltD \
                "$mergedir/$base/" "$target_host:/$base/" 2>&1) || true
            if [ -n "$raw" ]; then
                echo "$raw" | rsync-humanize "$base"
                # Mirror the two-regex pattern used in system-diff display
                # (lines ~658+663): count NEW files (`>f++++...`) AND
                # CHANGED files (`>fcs....`). The single-regex form
                # `^[<>][^ ]*[cs]` missed new files entirely → hemma
                # reported "No content changes needed" and exited without
                # rsyncing a single new file. (Caught May 13, 2026 on
                # first attempt to push a watchdog
                # overlay — 5 NEW files, 0 modified, total_changed
                # silently stayed 0.)
                n_new=$(echo "$raw" | grep -cE '^[<>]f[^ ]*\+\+\+\+' || true)
                n_chg=$(echo "$raw" | grep -cE '^[<>]f[^ ]*[cs]' || true)
                total_changed=$((total_changed + n_new + n_chg))
                # Capture content-changed/new file paths for hook matching
                # (union of new+changed filters above). Format: <base>/<relpath>
                # `|| true`: same pipefail guard as the n_new/n_chg greps
                # above. A deploy-base whose preview yields no content-change
                # lines (the common case, e.g. an unchanged usr/ base) OR an
                # rsync error string → no-match grep → exit 1 → set -e aborts
                # system-apply before the confirm/deploy/hooks without this.
                # Regression: scripts/test-system-apply-preview.sh (May 17 2026).
                echo "$raw" | grep -E '^[<>]f[^ ]*(\+\+\+\+|[cs])' \
                    | awk -v b="$base" '{print b "/" $2}' >> "$changes_file" || true
            fi
        fi
    done

    if [ "$total_changed" -eq 0 ]; then
        printf "{{green}}No content changes needed.{{reset}}\n"
        exit 0
    fi

    # Confirm unless --yes
    if [ "$skip_confirm" = "false" ]; then
        printf "Apply these changes? [y/N] "
        read -r confirm
        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
            printf "Aborted.\n"
            exit 0
        fi
    fi

    # Deploy via rsync with sudo on remote per deploy base
    printf "{{cyan}}hemma{{reset}}: deploying system configs to %s...\n" "$host_name"
    for base in $deploy_bases; do
        if [ -d "$mergedir/$base" ]; then
            rsync -e "ssh" --rsync-path="sudo rsync" -rltD \
                "$mergedir/$base/" "$target_host:/$base/"
        fi
    done

    # Rebuild font cache on Linux after deploying fonts
    if [ "$remote_os" != "Darwin" ] && echo "$deploy_bases" | grep -q "usr"; then
        ssh "$target_host" "command -v fc-cache >/dev/null 2>&1 && sudo fc-cache -f /usr/local/share/fonts 2>/dev/null || true"
        printf "{{cyan}}hemma{{reset}}: rebuilt font cache on %s\n" "$host_name"
    fi

    # Apply permission manifests
    for entry in "${perms_files[@]}"; do
        perm_base="${entry%%:*}"
        perm_file="${entry#*:}"
        if [ -f "$perm_file" ]; then
            printf "{{cyan}}hemma{{reset}}: applying /%s/ permissions...\n" "$perm_base"
            while IFS= read -r line; do
                [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
                IFS=: read -r fpath owner group mode <<< "$line"
                ssh "$target_host" "sudo chown $owner:$group /$perm_base/$fpath && sudo chmod $mode /$perm_base/$fpath" || {
                    printf "{{yellow}}Warning{{reset}}: failed to set perms on /%s/%s\n" "$perm_base" "$fpath"
                }
            done < "$perm_file"
        fi
    done

    # Run .hemma-hooks for content-changed files (post-deploy)
    hooks_script="{{hemma_dir}}/scripts/run-hooks.sh"
    hook_failures=0
    if [ -x "$hooks_script" ] && [ -s "$changes_file" ]; then
        "$hooks_script" \
            --host "$host_name" \
            --target "$target_host" \
            --sysdir "$sysdir" \
            --role "$host_role" \
            --changes-file "$changes_file" \
            ${hook_flags[@]+"${hook_flags[@]}"} || hook_failures=$?
    fi

    # Auto-commit via etckeeper if available
    ssh "$target_host" "command -v etckeeper >/dev/null 2>&1 && sudo etckeeper commit 'hemma system-apply' 2>/dev/null || true"

    if [ "$hook_failures" -gt 0 ]; then
        printf "{{yellow}}Warning{{reset}}: hooks reported failures (see above). Deploy completed.\n"
        exit 1
    fi

    printf "{{green}}Done{{reset}}: system configs deployed to %s.\n" "$host_name"

# Deploy system configs to all non-critical hosts (sequential)
system-apply-all *flags:
    #!/usr/bin/env bash
    set -euo pipefail
    include_critical=false
    for flag in {{flags}}; do
        if [ "$flag" = "--force" ]; then include_critical=true; fi
    done

    printf "{{bold}}{{cyan}}hemma{{reset}} — system-apply-all\n\n"

    sysdir="{{system_dir}}"
    failed=0
    applied=0

    for entry in {{fleet}}; do
        IFS=: read -r name ssh_host role critical <<< "$entry"

        if [ "$critical" = "true" ] && [ "$include_critical" = "false" ]; then
            printf "  {{yellow}}skip{{reset}} %s (critical — use --force to include)\n" "$name"
            continue
        fi

        # Skip hosts with no overlay directory
        has_overlay=false
        for base in etc opt usr Library; do
            if [ -d "$sysdir/common/$base" ] || [ -d "$sysdir/$name/$base" ]; then
                has_overlay=true
                break
            fi
        done
        if [ "$has_overlay" = "false" ]; then
            printf "  {{yellow}}skip{{reset}} %s (no overlay)\n" "$name"
            continue
        fi

        printf "  {{cyan}}applying{{reset}} %s...\n" "$name"
        if just system-apply "$name" --yes 2>&1 | sed 's/^/    /'; then
            applied=$((applied + 1))
        else
            failed=$((failed + 1))
            printf "  {{red}}✗{{reset}} %s failed\n" "$name"
        fi
    done

    if [ "$failed" -gt 0 ]; then
        printf "\n{{red}}%d host(s) failed.{{reset}}\n" "$failed"
        exit 1
    fi
    if [ "$applied" -eq 0 ]; then
        printf "\n{{yellow}}No hosts had system overlays to apply.{{reset}}\n"
    else
        printf "\n{{green}}System configs deployed to %d host(s).{{reset}}\n" "$applied"
    fi

# Pull live system configs from remote back to overlay (reverse of system-apply)
system-pull host *flags:
    #!/usr/bin/env bash
    set -euo pipefail
    target_host=""
    host_name=""
    auto_yes=false

    for flag in {{flags}}; do
        if [ "$flag" = "--yes" ]; then auto_yes=true; fi
    done

    # Resolve host to SSH alias and canonical name
    host_role=""
    for entry in {{fleet}}; do
        IFS=: read -r name ssh_host role critical <<< "$entry"
        if [ "$name" = "{{host}}" ] || [ "$ssh_host" = "{{host}}" ]; then
            target_host="$ssh_host"
            host_name="$name"
            host_role="$role"
            break
        fi
    done

    if [ -z "$target_host" ]; then
        printf "{{red}}Error{{reset}}: Unknown host '{{host}}'\n"
        exit 1
    fi

    sysdir="{{system_dir}}"

    # Detect remote OS — pull /Library/ only from macOS hosts
    remote_os=$(ssh -o ConnectTimeout=5 "$target_host" "uname -s" 2>/dev/null || echo "unknown")
    if [ "$remote_os" = "Darwin" ]; then
        base_paths="etc Library"
    else
        base_paths="etc"
        # Include opt and usr if they exist in the overlay (common, roles, or host)
        for extra in opt usr; do
            if [ -d "$sysdir/common/$extra" ] || [ -d "$sysdir/$host_name/$extra" ]; then
                base_paths="$base_paths $extra"
            else
                IFS=',' read -ra _rl <<< "$host_role"
                for _r in "${_rl[@]}"; do
                    if [ -d "$sysdir/roles/$_r/$extra" ]; then
                        base_paths="$base_paths $extra"
                        break
                    fi
                done
            fi
        done
    fi

    # Build managed file manifest using rsync merge (same pattern as system-apply)
    manifest=$(mktemp)
    tmpdir=$(mktemp -d)
    merge_src=$(mktemp -d)
    trap 'rm -rf "$manifest" "$tmpdir" "$merge_src" "$secrets_list" 2>/dev/null' EXIT

    for base in $base_paths; do
        if [ -d "$sysdir/common/$base" ]; then
            rsync -a "$sysdir/common/$base/" "$merge_src/$base/"
        fi
        # Role overlays
        IFS=',' read -ra role_list <<< "$host_role"
        for r in "${role_list[@]}"; do
            if [ -d "$sysdir/roles/$r/$base" ]; then
                rsync -a "$sysdir/roles/$r/$base/" "$merge_src/$base/"
            fi
        done
        if [ -d "$sysdir/$host_name/$base" ]; then
            rsync -a "$sysdir/$host_name/$base/" "$merge_src/$base/"
        fi
    done
    find "$merge_src" -name ".hemma-perms" -delete 2>/dev/null || true
    find "$merge_src" -name ".hemma-hooks" -delete 2>/dev/null || true

    # Map merged files back to their overlay source paths
    # Priority: host-specific > role > common (last-wins, same as system-apply merge)
    has_files=false
    for base in $base_paths; do
        if [ -d "$merge_src/$base" ]; then
            has_files=true
            find "$merge_src/$base" -type f | sort | while read -r merged_file; do
                relpath="${merged_file#$merge_src/$base/}"
                if [ -f "$sysdir/$host_name/$base/$relpath" ]; then
                    printf "/$base/%s|%s|%s\n" "$relpath" "$sysdir/$host_name/$base/$relpath" "$host_name"
                else
                    # Check role overlays (reverse order so highest-priority role wins)
                    found_role=""
                    IFS=',' read -ra _rl <<< "$host_role"
                    for _r in "${_rl[@]}"; do
                        if [ -f "$sysdir/roles/$_r/$base/$relpath" ]; then
                            found_role="$_r"
                        fi
                    done
                    if [ -n "$found_role" ]; then
                        printf "/$base/%s|%s|role:%s\n" "$relpath" "$sysdir/roles/$found_role/$base/$relpath" "$found_role"
                    elif [ -f "$sysdir/common/$base/$relpath" ]; then
                        printf "/$base/%s|%s|common\n" "$relpath" "$sysdir/common/$base/$relpath"
                    fi
                fi
            done
        fi
    done > "$manifest"

    total=$(wc -l < "$manifest" | tr -d ' ')
    if [ "$total" -eq 0 ]; then
        printf "{{yellow}}No managed overlay files{{reset}} for %s\n" "$host_name"
        exit 0
    fi

    printf "{{bold}}{{cyan}}hemma{{reset}} — system-pull from %s (%d managed files)\n\n" "$host_name" "$total"

    # Phase 0.5: Load .hemma-secrets — files containing secrets that must NOT be auto-pulled
    # Same format as .hemma-perms: relative paths, one per line, # comments allowed.
    # Files listed here are skipped during pull to prevent secret leakage into git.
    # To sync manually: ssh <host> 'sudo cat <path>' | redact secrets | write to overlay
    secrets_list=$(mktemp)
    for base in $base_paths; do
        for secrets_src in "$sysdir/common/$base/.hemma-secrets" "$sysdir/$host_name/$base/.hemma-secrets"; do
            if [ -f "$secrets_src" ]; then
                while IFS= read -r line; do
                    [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
                    echo "/$base/$line" >> "$secrets_list"
                done < "$secrets_src"
            fi
        done
        # Check role overlays for .hemma-secrets
        IFS=',' read -ra _rl <<< "$host_role"
        for _r in "${_rl[@]}"; do
            if [ -f "$sysdir/roles/$_r/$base/.hemma-secrets" ]; then
                while IFS= read -r line; do
                    [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
                    echo "/$base/$line" >> "$secrets_list"
                done < "$sysdir/roles/$_r/$base/.hemma-secrets"
            fi
        done
    done
    secrets_count=$(wc -l < "$secrets_list" | tr -d ' ')

    # Phase 1: Pull all managed files from remote using sudo rsync
    # (symmetric with system-apply which uses --rsync-path="sudo rsync")
    # Build file list for rsync --files-from (excluding secret files)
    pull_filelist=$(mktemp)
    while IFS='|' read -r remote_path local_path source_label; do
        # Skip files listed in .hemma-secrets
        if grep -qxF "$remote_path" "$secrets_list" 2>/dev/null; then
            continue
        fi
        echo "$remote_path" >> "$pull_filelist"
    done < "$manifest"
    # Single rsync call with sudo — pulls all managed files at once
    rsync -e "ssh" --rsync-path="sudo rsync" -rltD --files-from="$pull_filelist" \
        "$target_host:/" "$tmpdir/" 2>/dev/null || true
    rm -f "$pull_filelist"

    # Phase 1b: Diagnose missing files (distinguish "not found" from "permission denied")
    # Only needed for files rsync couldn't pull
    missing_diag=""
    while IFS='|' read -r remote_path local_path source_label; do
        pulled="$tmpdir$remote_path"
        if [ ! -f "$pulled" ]; then
            # Ask remote: does the file exist at all?
            file_status=$(ssh -o ConnectTimeout=5 "$target_host" \
                "sudo test -f '$remote_path' && echo EXISTS || echo MISSING" 2>/dev/null || echo "UNKNOWN")
            missing_diag="${missing_diag}${remote_path}|${file_status}\n"
        fi
    done < "$manifest"

    # Phase 2: Compare and report
    drifted=0
    secrets_skipped=0
    diff_log=$(mktemp)
    while IFS='|' read -r remote_path local_path source_label; do
        # Check if this file is in the secrets list
        if grep -qxF "$remote_path" "$secrets_list" 2>/dev/null; then
            secrets_skipped=$((secrets_skipped + 1))
            printf "  {{cyan}}secret{{reset}}  %s (skipped — listed in .hemma-secrets)\n" "$remote_path"
            continue
        fi
        pulled="$tmpdir$remote_path"
        if [ ! -f "$pulled" ]; then
            # Use diagnosis from Phase 1b
            diag=$(printf "%b" "$missing_diag" | grep "^${remote_path}|" | head -1 | cut -d'|' -f2 || true)
            case "$diag" in
                EXISTS)
                    printf "  {{red}}error{{reset}}   %s (exists but rsync failed — check sudo/permissions)\n" "$remote_path"
                    ;;
                MISSING)
                    printf "  {{yellow}}skip{{reset}}    %s (not found on remote)\n" "$remote_path"
                    ;;
                *)
                    printf "  {{yellow}}skip{{reset}}    %s (could not determine status)\n" "$remote_path"
                    ;;
            esac
            continue
        fi
        if ! diff -q "$local_path" "$pulled" >/dev/null 2>&1; then
            drifted=$((drifted + 1))
            printf "  {{yellow}}drifted{{reset}} %s (source: %s/)\n" "$remote_path" "$source_label"
            file_diff=$(diff -u "$local_path" "$pulled" 2>/dev/null | head -40 || true)
            { echo "=== $remote_path (overlay: $source_label/) ==="; echo "$file_diff"; echo ""; } >> "$diff_log"
            echo "$file_diff" | head -30 | diff-so-fancy 2>/dev/null || echo "$file_diff" | head -30
            echo ""
        else
            printf "  {{green}}match{{reset}}   %s\n" "$remote_path"
        fi
    done < "$manifest"

    # Phase 2.1: LLM triage of drifted files (if available)
    if [ "$drifted" -gt 0 ] && command -v hemma-diff-triage &>/dev/null && [ -n "${OPENAI_API_KEY:-}" ]; then
        echo ""
        printf "{{bold}}AI triage:{{reset}}\n"
        echo ""
        hemma-diff-triage < "$diff_log"
        echo ""
    fi
    rm -f "$diff_log"

    # Phase 2b: Sibling discovery — find new files in directories we already manage
    # For each directory in the overlay, check if the remote has files we don't track
    unmanaged_files=$(mktemp)
    managed_dirs=$(mktemp)

    # Collect unique remote directories from managed files
    # Skip top-level base dirs (/etc, /usr, /opt, /Library) — too noisy
    while IFS='|' read -r remote_path local_path source_label; do
        dir=$(dirname "$remote_path")
        # Only include subdirectories (at least 3 path components: /etc/foo/)
        depth=$(echo "$dir" | tr '/' '\n' | grep -c '.')
        if [ "$depth" -ge 3 ]; then
            echo "$dir"
        fi
    done < "$manifest" | sort -u > "$managed_dirs"

    # For each managed directory, list remote contents and find unmanaged siblings
    unmanaged_count=0
    while read -r rdir; do
        # Get remote file list for this directory (non-recursive, files only)
        remote_files=$(ssh -o ConnectTimeout=5 "$target_host" "find '$rdir' -maxdepth 1 -type f 2>/dev/null" || true)
        for rf in $remote_files; do
            # Skip if already in manifest
            if ! grep -q "^${rf}|" "$manifest"; then
                printf "%s\n" "$rf" >> "$unmanaged_files"
                unmanaged_count=$((unmanaged_count + 1))
            fi
        done
    done < "$managed_dirs"

    if [ "$unmanaged_count" -gt 0 ]; then
        printf "\n  {{cyan}}discover{{reset}} %d unmanaged file(s) in managed directories:\n" "$unmanaged_count"
        while read -r uf; do
            printf "    + %s\n" "$uf"
        done < "$unmanaged_files"
        printf "  {{cyan}}tip{{reset}}      To add: scp %s:<path> %s/%s/<relative-path>\n" "$target_host" "$sysdir" "$host_name"
    fi

    rm -f "$unmanaged_files" "$managed_dirs"

    # Phase 2c: etckeeper discovery — find recently changed /etc files not in overlay
    # Only runs if etckeeper is installed on the remote
    etckeeper_count=0
    has_etckeeper=$(ssh -o ConnectTimeout=5 "$target_host" "command -v etckeeper >/dev/null 2>&1 && [ -d /etc/.git ] && echo yes || echo no" 2>/dev/null || echo "no")
    if [ "$has_etckeeper" = "yes" ]; then
        etckeeper_files=$(mktemp)
        # Skip if only 1 commit (initial commit lists everything — not meaningful)
        commit_count=$(ssh -o ConnectTimeout=5 "$target_host" "cd /etc && git rev-list --count HEAD 2>/dev/null" 2>/dev/null || echo "0")
        if [ "$commit_count" -le 1 ]; then
            echo "" > "$etckeeper_files"
        else
            # Get files changed in /etc in last 7 days via git
            first_commit=$(ssh -o ConnectTimeout=5 "$target_host" "cd /etc && git rev-list --max-parents=0 HEAD 2>/dev/null" 2>/dev/null || echo "")
            if [ -n "$first_commit" ]; then
                # Exclude initial commit (lists everything), show only subsequent changes
                ssh -o ConnectTimeout=5 "$target_host" "cd /etc && git log --name-only --since='7 days ago' --pretty=format:'' ${first_commit}..HEAD 2>/dev/null | sort -u | grep -v '^$'" 2>/dev/null > "$etckeeper_files" || true
            fi
        fi

        while read -r etcfile; do
            [ -z "$etcfile" ] && continue
            remote_path="/etc/$etcfile"
            # Skip if already in manifest (managed file)
            if grep -q "^${remote_path}|" "$manifest"; then
                continue
            fi
            # Skip if in a managed subdirectory (already caught by sibling discovery)
            in_sibling=false
            while read -r mdir; do
                case "$remote_path" in "$mdir"/*) in_sibling=true; break;; esac
            done < "$managed_dirs" 2>/dev/null || true
            if [ "$in_sibling" = "true" ]; then
                continue
            fi
            # Skip known noisy paths
            case "$etcfile" in
                .etckeeper|.git*|ld.so.cache|adjtime|resolv.conf) continue;;
                apt/*|dpkg/*|alternatives/*|ca-certificates*) continue;;
                machine-id|subuid|subgid) continue;;
            esac
            etckeeper_count=$((etckeeper_count + 1))
            if [ "$etckeeper_count" -eq 1 ]; then
                printf "\n  {{cyan}}etckeeper{{reset}} recently changed /etc files not in overlay (last 7 days):\n"
            fi
            printf "    ~ /etc/%s\n" "$etcfile"
        done < "$etckeeper_files"

        rm -f "$etckeeper_files"
    fi

    # Note about secret files skipped
    if [ "$secrets_skipped" -gt 0 ]; then
        printf "\n  {{cyan}}note{{reset}}    %d file(s) skipped via .hemma-secrets (contain plaintext secrets)\n" "$secrets_skipped"
        printf "  {{cyan}}tip{{reset}}      To sync manually: ssh %s 'sudo cat <path>' → redact → save to overlay\n" "$target_host"
    fi

    # Note about encrypted secrets (not pullable)
    for base in $base_paths; do
        if [ -d "$sysdir/secrets/$host_name/$base" ]; then
            secret_count=$(find "$sysdir/secrets/$host_name/$base" -name "*.age" -type f 2>/dev/null | wc -l | tr -d ' ')
            if [ "$secret_count" -gt 0 ]; then
                printf "\n  {{cyan}}note{{reset}}    %d encrypted /%s/ secret(s) skipped (manage via age re-encrypt)\n" "$secret_count" "$base"
            fi
        fi
    done

    discoveries=$((unmanaged_count + etckeeper_count))

    if [ "$drifted" -eq 0 ] && [ "$discoveries" -eq 0 ]; then
        printf "\n{{green}}No drift — overlay matches remote.{{reset}}\n"
        exit 0
    fi

    if [ "$drifted" -eq 0 ] && [ "$discoveries" -gt 0 ]; then
        printf "\n{{green}}No drift in managed files.{{reset}} Review discovered files above.\n"
        exit 0
    fi

    printf "\n{{yellow}}%d file(s) drifted.{{reset}}\n\n" "$drifted"

    if [ "$auto_yes" = "false" ]; then
        printf "Pull remote versions into overlay? [y/N] "
        read -r confirm
        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
            printf "Run 'hemma system-apply %s' to push overlay to remote instead.\n" "$host_name"
            exit 0
        fi
    fi

    # Phase 3: Update overlay with remote versions (skip secrets)
    updated=0
    while IFS='|' read -r remote_path local_path source_label; do
        # Never auto-pull secret files into overlay
        grep -qxF "$remote_path" "$secrets_list" 2>/dev/null && continue
        pulled="$tmpdir$remote_path"
        [ ! -f "$pulled" ] && continue
        if ! diff -q "$local_path" "$pulled" >/dev/null 2>&1; then
            cp "$pulled" "$local_path"
            updated=$((updated + 1))
            printf "  {{green}}pulled{{reset}} %s\n" "$remote_path"
        fi
    done < "$manifest"

    printf "\n{{green}}%d file(s) updated in overlay.{{reset}}\n" "$updated"
    printf "{{yellow}}Tip{{reset}}: Review with 'git diff system/' then commit.\n"

# Prepare RPi SD card boot partition for headless first boot
# Writes firstrun.sh (NetworkManager WiFi, user, hostname, SSH) + cmdline.txt trigger
# Usage: just prepare-sd /Volumes/bootfs mypi MyWiFi <wifi_password> [user]
prepare-sd bootfs hostname wifi_ssid wifi_password user="pi":
    #!/usr/bin/env bash
    set -euo pipefail
    bootfs="{{bootfs}}"
    hostname="{{hostname}}"
    wifi_ssid="{{wifi_ssid}}"
    wifi_password="{{wifi_password}}"
    user="{{user}}"

    if [ ! -f "$bootfs/cmdline.txt" ]; then
        printf "{{red}}Error{{reset}}: %s/cmdline.txt not found — is the SD card mounted?\n" "$bootfs"
        exit 1
    fi

    pass_hash=$(openssl passwd -6 "$hostname")

    printf "{{cyan}}hemma{{reset}}: preparing SD card at %s\n" "$bootfs"
    printf "  hostname: %s\n  user:     %s (password: %s — change after first login)\n" "$hostname" "$user" "$hostname"
    printf "  wifi:     %s\n  country:  SE\n\n" "$wifi_ssid"

    # Use helper script to generate firstrun.sh (avoids Just heredoc escaping issues)
    "{{justfile_directory()}}/generate-firstrun.sh" "$bootfs/firstrun.sh" "$hostname" "$user" "$pass_hash" "$wifi_ssid" "$wifi_password"
    chmod +x "$bootfs/firstrun.sh"
    printf "  {{green}}✓{{reset}} firstrun.sh written\n"

    touch "$bootfs/ssh"
    printf "  {{green}}✓{{reset}} ssh marker created\n"

    current_cmdline=$(cat "$bootfs/cmdline.txt")
    clean_cmdline=$(echo "$current_cmdline" | sed 's| systemd.run=[^ ]* systemd.run_success_action=[^ ]* systemd.unit=[^ ]*||g' | sed 's| cfg80211.ieee80211_regdom=[^ ]*||g')
    printf '%s' "${clean_cmdline} cfg80211.ieee80211_regdom=SE systemd.run=/boot/firmware/firstrun.sh systemd.run_success_action=reboot systemd.unit=kernel-command-line.target" > "$bootfs/cmdline.txt"
    printf "  {{green}}✓{{reset}} cmdline.txt updated\n"

    removed=0
    for f in network-config user-data meta-data userconf.txt; do
        if [ -f "$bootfs/$f" ]; then rm -f "$bootfs/$f"; removed=$((removed + 1)); fi
    done
    if [ "$removed" -gt 0 ]; then
        printf "  {{green}}✓{{reset}} removed %d cloud-init remnant(s)\n" "$removed"
    fi

    printf "\n{{green}}SD card ready.{{reset}} Insert into RPi, power on.\n"
    printf "First boot: firstrun.sh runs → reboot → WiFi + SSH available.\n"
    printf "Connect: ssh %s@<ip> (password: %s)\n" "$user" "$hostname"
    printf "Then run: hemma bootstrap %s <ip> %s\n" "$hostname" "$user"

# Pull system configs from all non-critical hosts
system-pull-all *flags:
    #!/usr/bin/env bash
    set -euo pipefail
    include_critical=false
    for flag in {{flags}}; do
        if [ "$flag" = "--force" ]; then include_critical=true; fi
    done

    printf "{{bold}}{{cyan}}hemma{{reset}} — system-pull-all\n\n"

    sysdir="{{system_dir}}"

    for entry in {{fleet}}; do
        IFS=: read -r name ssh_host role critical <<< "$entry"
        if [ "$critical" = "true" ] && [ "$include_critical" = "false" ]; then
            printf "  {{yellow}}skip{{reset}} %s (critical — use --force to include)\n" "$name"
            continue
        fi

        # Skip hosts with no overlay directory
        has_overlay=false
        for base in etc opt usr Library; do
            if [ -d "$sysdir/common/$base" ] || [ -d "$sysdir/$name/$base" ]; then
                has_overlay=true
                break
            fi
        done
        if [ "$has_overlay" = "false" ]; then
            printf "  {{yellow}}skip{{reset}} %s (no overlay)\n" "$name"
            continue
        fi

        printf "  {{cyan}}pulling{{reset}} %s...\n" "$name"
        just system-pull "$name" --yes 2>&1 | sed 's/^/    /' || true
        printf "\n"
    done
