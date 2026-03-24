# hemma — fleet provisioning orchestrator
# Swedish: "at home" — makes every machine feel like home
#
# Companion to nit (github.com/semikolon/nit)
# Works with nit or chezmoi for dotfile sync
#
# Usage:
#   just status                  Show fleet status
#   just apply <host>            Apply dotfile sync + system overlay on a host
#   just apply-all               Apply to all non-critical hosts
#   just apply-all --force       Apply to ALL hosts including critical
#   just system-diff <host>      Preview system config changes (dry-run)
#   just system-apply <host>     Deploy system config overlay
#   just system-apply-all        Deploy system configs to all non-critical hosts
#   just system-pull <host>      Pull live /etc back to overlay (reverse sync)
#   just system-pull-all         Pull from all non-critical hosts
#   just bootstrap <host>        Bootstrap a new machine (SSH-reachable)
#   just prepare-sd <bootfs> ... Prepare RPi SD card for headless first boot
#   just update                  Update local machine (dotfile sync, immediate)
#   just run <host> <cmd>        Run arbitrary command on a host
#   just run-all <cmd>           Run command on all non-critical hosts
#   just ssh <host>              Open SSH session to a host
#
# RPi provisioning workflow:
#   1. Flash RPi OS image to SD card (e.g., via dd or RPi Imager)
#   2. just prepare-sd /Volumes/bootfs <hostname> <ssid> <wifi_pw> [user]
#   3. Insert SD card, power on — first boot configures WiFi/SSH/user, reboots
#   4. just bootstrap <hostname> <ip> <user>
#   5. Dotfile manager run_onchange scripts install Docker, HA, Node-RED, etc.

set shell := ["bash", "-euo", "pipefail", "-c"]

# Configurable paths — override via environment variables
dotfiles_dir := env("HEMMA_DOTFILES", home_directory() + "/dotfiles")
hemma_dir := env("HEMMA_DIR", justfile_directory())

# Fleet inventory — parsed from fleet.toml (single source of truth)
# Format: name:ssh_host:role:critical
fleet := `python3 "$HEMMA_DIR/parse-fleet.py"`

# Colors
green := "\\033[32m"
red := "\\033[31m"
yellow := "\\033[33m"
cyan := "\\033[36m"
bold := "\\033[1m"
reset := "\\033[0m"

# System overlay directory (relative to dotfiles repo root)
system_dir := dotfiles_dir + "/system"

# Default recipe — show help
default:
    @just --list --unsorted

# Detect the sync command (nit or chezmoi)
[private]
sync-cmd:
    #!/usr/bin/env bash
    if command -v nit >/dev/null 2>&1; then
        echo "nit update"
    elif command -v chezmoi >/dev/null 2>&1; then
        echo "chezmoi update --no-tty"
    else
        echo "echo 'ERROR: neither nit nor chezmoi found'" >&2
        exit 1
    fi

# Update local machine (git pull + dotfile sync, skips idle check)
update:
    #!/usr/bin/env bash
    set -euo pipefail
    printf "{{bold}}{{cyan}}hemma{{reset}} — updating local machine\n\n"

    # Try nit first, then chezmoi with its idle wrapper, then plain chezmoi
    if command -v nit >/dev/null 2>&1; then
        nit update
    elif [ -x "$HOME/.local/bin/chezmoi-update-if-idle" ]; then
        "$HOME/.local/bin/chezmoi-update-if-idle" --force
    else
        chezmoi_bin=$(command -v chezmoi || echo "$HOME/.local/bin/chezmoi")
        "$chezmoi_bin" update --no-tty
    fi
    printf "\n{{green}}Done{{reset}}: local machine updated.\n"

# Show fleet status (sync state, git hash, uptime)
status:
    #!/usr/bin/env bash
    set -euo pipefail
    printf "{{bold}}{{cyan}}hemma{{reset}} — fleet status\n\n"
    printf "%-12s %-10s %-8s %-12s %-20s %-16s %s\n" "MACHINE" "ROLE" "STATUS" "GIT HASH" "UPTIME" "SYNC" "SYSTEM"

    # Detect local sync tool
    sync_tool="unknown"
    if command -v nit >/dev/null 2>&1; then
        sync_tool="nit"
    elif command -v chezmoi >/dev/null 2>&1; then
        sync_tool="chezmoi"
    fi

    # Local machine first
    local_hash=$(git -C "{{dotfiles_dir}}" rev-parse --short HEAD 2>/dev/null || echo "n/a")
    local_uptime=$(uptime | sed 's/.*up //' | sed 's/,.*//')
    local_drift="0"
    if [ "$sync_tool" = "nit" ]; then
        local_drift=$(nit status --count 2>/dev/null || echo "n/a")
    elif [ "$sync_tool" = "chezmoi" ]; then
        local_drift=$(chezmoi status 2>/dev/null | wc -l | tr -d ' ')
    fi
    if [ "$local_drift" = "0" ]; then
        sync_status="{{green}}clean{{reset}}"
    else
        sync_status="{{yellow}}${local_drift} drifted{{reset}}"
    fi
    local_hostname=$(hostname -s 2>/dev/null || hostname)
    printf "%-12s %-10s $(printf '{{green}}')%-8s$(printf '{{reset}}') %-12s %-20s %-16b %s\n" \
        "$local_hostname" "primary" "up" "$local_hash" "$local_uptime" "$sync_status" "-"

    # Remote machines in parallel
    sysdir_base="{{system_dir}}"
    for entry in {{fleet}}; do
        IFS=: read -r name host role critical <<< "$entry"
        (
            if ssh -o ConnectTimeout=3 -o BatchMode=yes "$host" "true" 2>/dev/null; then
                remote_hash=$(ssh -o ConnectTimeout=5 "$host" "git -C \"\${HEMMA_DOTFILES:-\$HOME/dotfiles}\" rev-parse --short HEAD 2>/dev/null || echo 'n/a'")
                remote_uptime=$(ssh -o ConnectTimeout=5 "$host" "uptime" 2>/dev/null | sed 's/.*up //' | sed 's/,.*//')

                # Detect remote sync tool and check status
                remote_sync="n/a"
                if ssh -o ConnectTimeout=5 "$host" "command -v nit >/dev/null 2>&1" 2>/dev/null; then
                    remote_sync=$(ssh -o ConnectTimeout=5 "$host" "nit status --count 2>/dev/null || echo 'n/a'" 2>/dev/null)
                elif ssh -o ConnectTimeout=5 "$host" "command -v chezmoi >/dev/null 2>&1" 2>/dev/null; then
                    remote_sync=$(ssh -o ConnectTimeout=5 "$host" "chezmoi status 2>/dev/null | wc -l | tr -d ' '" 2>/dev/null || echo "n/a")
                fi
                if [ "$remote_sync" = "0" ]; then
                    cstatus="clean"
                elif [ "$remote_sync" = "n/a" ]; then
                    cstatus="not installed"
                else
                    cstatus="${remote_sync} drifted"
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
                        drift_n=$(rsync -e "ssh -o ConnectTimeout=5" --dry-run --itemize-changes --checksum -rltD \
                            "$dir" "$host:/$base/" 2>/dev/null | grep '^[<>]f' | wc -l | tr -d ' ')
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
                if [ "$critical" = "true" ]; then crit_marker=" !"; fi
                printf "%-12s %-10s %-8s %-12s %-20s %-16s %s%s\n" \
                    "$name" "$role" "up" "$remote_hash" "$remote_uptime" "$cstatus" "$sys_drift" "$crit_marker"
            else
                printf "%-12s %-10s %-8s %-12s %-20s %-16s %s\n" \
                    "$name" "$role" "DOWN" "-" "-" "-" "-"
            fi
        ) &
    done
    wait

# Apply dotfile sync on a specific host
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
        printf "{{yellow}}WARNING{{reset}}: {{host}} is marked as CRITICAL infrastructure.\n"
        printf "Applying changes may affect network connectivity for all machines.\n"
        printf "Continue? [y/N] "
        read -r confirm
        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
            printf "Aborted.\n"
            exit 0
        fi
    fi

    # Detect remote sync tool
    sync_cmd="echo 'ERROR: neither nit nor chezmoi found on remote'"
    if ssh -o ConnectTimeout=5 "$target_host" "command -v nit >/dev/null 2>&1" 2>/dev/null; then
        sync_cmd="nit update"
    elif ssh -o ConnectTimeout=5 "$target_host" "command -v chezmoi >/dev/null 2>&1" 2>/dev/null; then
        sync_cmd="chezmoi update --no-tty"
    fi

    printf "{{cyan}}hemma{{reset}}: applying to {{host}} ($target_host)...\n"
    ssh "$target_host" "$sync_cmd 2>&1" || {
        printf "{{red}}Failed{{reset}}: sync on {{host}} exited with $?\n"
        exit 1
    }
    printf "{{green}}Done{{reset}}: {{host}} synced.\n"

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

# Apply dotfile sync on all non-critical hosts (parallel)
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

            # Detect remote sync tool
            sync_cmd="echo 'ERROR: no sync tool found'"
            if ssh -o ConnectTimeout=5 -o BatchMode=yes "$ssh_host" "command -v nit >/dev/null 2>&1" 2>/dev/null; then
                sync_cmd="nit update"
            elif ssh -o ConnectTimeout=5 -o BatchMode=yes "$ssh_host" "command -v chezmoi >/dev/null 2>&1" 2>/dev/null; then
                sync_cmd="chezmoi update --no-tty"
            fi

            if ssh -o ConnectTimeout=5 -o BatchMode=yes "$ssh_host" "$sync_cmd" > "$tmpdir/$name.log" 2>&1; then
                printf "  {{green}}✓{{reset}} %s\n" "$name" > "$tmpdir/$name.status"
            else
                printf "  {{red}}✗{{reset}} %s (exit $?)\n" "$name" > "$tmpdir/$name.status"
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

    # Find bootstrap.sh — check dotfiles repo first, then hemma dir
    script="{{dotfiles_dir}}/bootstrap.sh"
    if [ ! -f "$script" ]; then
        script="{{hemma_dir}}/bootstrap.sh"
    fi
    if [ ! -f "$script" ]; then
        printf "{{red}}Error{{reset}}: bootstrap.sh not found in {{dotfiles_dir}} or {{hemma_dir}}\n"
        printf "Create a bootstrap.sh that installs dependencies, generates age+SSH keys, sets zsh.\n"
        exit 1
    fi

    # Configure your dotfiles repo here
    dotfiles_repo="${HEMMA_DOTFILES_REPO:-}"
    dotfiles_ssh="${HEMMA_DOTFILES_SSH:-}"

    if [ -z "$dotfiles_repo" ] || [ -z "$dotfiles_ssh" ]; then
        printf "{{red}}Error{{reset}}: Set HEMMA_DOTFILES_REPO and HEMMA_DOTFILES_SSH environment variables.\n"
        printf "  Example:\n"
        printf "    export HEMMA_DOTFILES_REPO=youruser/dotfiles\n"
        printf "    export HEMMA_DOTFILES_SSH=git@github.com:youruser/dotfiles.git\n"
        exit 1
    fi

    # Detect dotfile manager config template
    toml_tmpl=""
    if [ -f "{{dotfiles_dir}}/home/.chezmoi.toml.tmpl" ]; then
        toml_tmpl="{{dotfiles_dir}}/home/.chezmoi.toml.tmpl"
    elif [ -f "{{dotfiles_dir}}/.chezmoi.toml.tmpl" ]; then
        toml_tmpl="{{dotfiles_dir}}/.chezmoi.toml.tmpl"
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

    # --- Step 5: Add age recipient + re-encrypt ---
    printf "\n{{bold}}Step 5: Adding age recipient...{{reset}}\n"

    # Detect age key location (nit uses ~/.config/nit/key.txt, chezmoi uses ~/.config/chezmoi/key.txt)
    age_pubkey=""
    for key_path in ~/.config/nit/key.txt ~/.config/chezmoi/key.txt; do
        result=$(ssh "$remote" "grep 'public key:' $key_path 2>/dev/null | cut -d: -f2 | tr -d ' '" 2>/dev/null || true)
        if [ -n "$result" ]; then
            age_pubkey="$result"
            break
        fi
    done

    if [ -z "$age_pubkey" ]; then
        printf "{{red}}  ✗{{reset}} Could not read age public key from {{host}}\n"
        printf "    Manual fix: ssh $remote 'cat ~/.config/nit/key.txt' (or chezmoi/key.txt)\n"
    elif [ -n "$toml_tmpl" ] && grep -q "$age_pubkey" "$toml_tmpl" 2>/dev/null; then
        printf "{{green}}  ✓{{reset}} age recipient already in config template\n"
    elif [ -n "$toml_tmpl" ]; then
        # Insert new recipient before the closing bracket in recipients array
        insert_line="        \"${age_pubkey}\","
        awk -v line="$insert_line" '
            /recipients = \[/ { in_block=1 }
            in_block && /^[[:space:]]*\]/ { print line; in_block=0 }
            { print }
        ' "$toml_tmpl" > "${toml_tmpl}.tmp" && mv "${toml_tmpl}.tmp" "$toml_tmpl"

        if grep -q "$age_pubkey" "$toml_tmpl"; then
            printf "{{green}}  ✓{{reset}} age recipient added: %s\n" "$age_pubkey"
        else
            printf "{{red}}  ✗{{reset}} Failed to add age recipient to config template\n"
            printf "    Manual fix: add \"%s\" to recipients list\n" "$age_pubkey"
        fi

        # Commit the change
        cd "{{dotfiles_dir}}"
        git add "$toml_tmpl"
        git commit -m "hemma: add {{host}} age recipient" "$toml_tmpl" 2>/dev/null || true

        # Re-encrypt secrets for new recipient
        printf "{{cyan}}hemma{{reset}}: re-encrypting secrets for new recipient...\n"
        if command -v nit >/dev/null 2>&1; then
            nit rekey
        elif [ -x "$HOME/.local/bin/chezmoi-re-encrypt" ]; then
            "$HOME/.local/bin/chezmoi-re-encrypt"
        else
            printf "{{yellow}}  ⚠{{reset}} No rekey tool found — re-encrypt secrets manually\n"
        fi

        # Push
        git push 2>/dev/null || true
        printf "{{green}}  ✓{{reset}} secrets re-encrypted and pushed\n"
    else
        printf "{{yellow}}  ⚠{{reset}} No config template found — add age recipient manually\n"
        printf "    Public key: %s\n" "$age_pubkey"
    fi

    # --- Step 6: Run dotfile manager init on remote ---
    printf "\n{{bold}}Step 6: Initializing dotfile manager on {{host}}...{{reset}}\n"
    sync_ok=false
    if ssh -o ConnectTimeout=5 "$remote" "ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no git@github.com 2>&1 | grep -q 'successfully authenticated'" 2>/dev/null; then
        printf "{{cyan}}hemma{{reset}}: {{host}} can reach GitHub — running init\n"

        # Try nit first, then chezmoi
        init_cmd=""
        if ssh -o ConnectTimeout=5 "$remote" "command -v nit >/dev/null 2>&1" 2>/dev/null; then
            init_cmd="nit init --apply $dotfiles_ssh"
        else
            init_cmd="PATH=\$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:\$PATH chezmoi init --apply $dotfiles_ssh"
        fi

        if ssh "$remote" "$init_cmd" 2>&1; then
            printf "{{green}}  ✓{{reset}} dotfile manager initialized and applied on {{host}}\n"
            sync_ok=true
        else
            printf "{{yellow}}  ⚠{{reset}} init failed — run manually when resolved:\n"
            printf "    ssh $remote '$init_cmd'\n"
        fi
    else
        printf "{{yellow}}  ⚠{{reset}} {{host}} cannot reach github.com (no internet?) — skipping init\n"
        printf "  Run when internet is available:\n"
        printf "    ssh $remote 'nit init --apply $dotfiles_ssh'  # or chezmoi init --apply\n"
    fi

    # --- Step 7: Apply system config overlay ---
    sysdir="{{system_dir}}"
    if [ -d "$sysdir/common" ] || [ -d "$sysdir/{{host}}" ]; then
        printf "\n{{bold}}Step 7: Applying system config overlay...{{reset}}\n"
        if [ "$sync_ok" = true ]; then
            if just system-apply "{{host}}" --yes 2>&1; then
                printf "{{green}}  ✓{{reset}} system overlay applied to {{host}}\n"
            else
                printf "{{yellow}}  ⚠{{reset}} system-apply failed — run manually:\n"
                printf "    hemma system-apply {{host}}\n"
            fi
        else
            printf "{{yellow}}  ⚠{{reset}} skipping system-apply (dotfile manager not initialized yet)\n"
            printf "  After init, run: hemma system-apply {{host}}\n"
        fi
    fi

    # --- Summary ---
    printf "\n{{bold}}{{green}}Bootstrap complete for {{host}}!{{reset}}\n"
    has_manual=false

    if [ "$sync_ok" = false ]; then
        has_manual=true
        printf "\n{{bold}}{{yellow}}Deferred steps (need internet):{{reset}}\n"
        printf "  1. ssh $remote 'nit init --apply $dotfiles_ssh'  # or chezmoi\n"
        if [ -d "$sysdir/common" ] || [ -d "$sysdir/{{host}}" ]; then
            printf "  2. hemma system-apply {{host}}\n"
        fi
    fi

    # Check for remaining manual steps
    manual_items=""
    if ! grep -q "Host {{host}}" "$HOME/.ssh/config" 2>/dev/null; then
        manual_items="${manual_items}\n  - Add SSH config entry: Host {{host}} / HostName {{ip}} / User ${target_user}"
    fi
    fleet_toml="{{dotfiles_dir}}/fleet.toml"
    if [ -f "$fleet_toml" ] && ! grep -q "{{host}}" "$fleet_toml" 2>/dev/null; then
        manual_items="${manual_items}\n  - Add {{host}} to fleet.toml"
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
            # Try nit key location first, then chezmoi
            age_key=""
            for key_path in "$HOME/.config/nit/key.txt" "$HOME/.config/chezmoi/key.txt"; do
                if [ -f "$key_path" ]; then
                    age_key="$key_path"
                    break
                fi
            done
            if [ -z "$age_key" ]; then
                printf "{{red}}Error{{reset}}: age key not found (checked ~/.config/nit/key.txt and ~/.config/chezmoi/key.txt)\n"
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
    total_changed=0
    for base in $deploy_bases; do
        if [ -d "$mergedir/$base" ]; then
            raw=$(rsync -e "ssh" --dry-run --itemize-changes --checksum -rltD \
                "$mergedir/$base/" "$target_host:/$base/" 2>&1) || true
            if [ -n "$raw" ]; then
                # Use rsync-humanize if available, otherwise show raw
                if command -v rsync-humanize >/dev/null 2>&1; then
                    echo "$raw" | rsync-humanize "$base"
                else
                    echo "$raw" | sed "s|^|  /$base/|"
                fi
                # Count actual content changes (not timestamp-only)
                n=$(echo "$raw" | grep -E '^[<>][^ ]*[cs]' | wc -l | tr -d ' ')
                total_changed=$((total_changed + n))
            fi
        fi
    done

    if [ "$total_changed" -eq 0 ]; then
        printf "{{green}}No content changes needed.{{reset}}\n"
    else
        printf "\n{{bold}}%d file(s) with content changes.{{reset}}\n" "$total_changed"
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

    for flag in {{flags}}; do
        if [ "$flag" = "--yes" ]; then skip_confirm=true; fi
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
        printf "{{yellow}}WARNING{{reset}}: %s is marked as CRITICAL infrastructure.\n" "$host_name"
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
    trap 'rm -rf "$mergedir"' EXIT

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
            # Try nit key location first, then chezmoi
            age_key=""
            for key_path in "$HOME/.config/nit/key.txt" "$HOME/.config/chezmoi/key.txt"; do
                if [ -f "$key_path" ]; then
                    age_key="$key_path"
                    break
                fi
            done
            if [ -z "$age_key" ]; then
                printf "{{red}}Error{{reset}}: age key not found (checked ~/.config/nit/key.txt and ~/.config/chezmoi/key.txt)\n"
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
    # Common perms first, then host-specific overrides (last wins for duplicate paths)
    perms_files=()
    for base in $source_bases; do
        if [ -f "$sysdir/common/$base/.hemma-perms" ]; then
            perms_files+=("$base:$sysdir/common/$base/.hemma-perms")
        fi
        if [ -f "$sysdir/$host_name/$base/.hemma-perms" ]; then
            perms_files+=("$base:$sysdir/$host_name/$base/.hemma-perms")
        fi
    done

    # Remove .hemma-perms from merge (not deployed to remote)
    find "$mergedir" -name ".hemma-perms" -delete 2>/dev/null || true

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
    # Uses rsync --existing to compare only files we manage (overlay → remote).
    # Reverse itemize (remote → local) detects remote-side modifications.
    drift_list=""
    for base in $deploy_bases; do
        if [ -d "$mergedir/$base" ]; then
            # --existing: only check files that exist in overlay (our managed set)
            # Reverse direction: remote → overlay merge dir (read-only, dry-run)
            # Only flag files with actual content changes (c=checksum, s=size)
            base_drift=$(rsync -e "ssh" --rsync-path="sudo rsync" --dry-run --existing \
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
    done
    if [ -n "$drift_list" ]; then
        drift_count=$(printf "%b" "$drift_list" | grep -c '/' || true)
        printf "{{yellow}}Remote drift detected{{reset}} — %s file(s) on %s differ from overlay:\n" "$drift_count" "$host_name"
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
            raw=$(rsync -e "ssh" --dry-run --itemize-changes --checksum -rltD \
                "$mergedir/$base/" "$target_host:/$base/" 2>&1) || true
            if [ -n "$raw" ]; then
                # Use rsync-humanize if available, otherwise show raw
                if command -v rsync-humanize >/dev/null 2>&1; then
                    echo "$raw" | rsync-humanize "$base"
                else
                    echo "$raw" | sed "s|^|  /$base/|"
                fi
                n=$(echo "$raw" | grep -E '^[<>][^ ]*[cs]' | wc -l | tr -d ' ')
                total_changed=$((total_changed + n))
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

    # Auto-commit via etckeeper if available
    ssh "$target_host" "command -v etckeeper >/dev/null 2>&1 && sudo etckeeper commit 'hemma system-apply' 2>/dev/null || true"

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
    trap 'rm -rf "$manifest" "$tmpdir" "$merge_src"' EXIT

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

    # Map merged files back to their overlay source paths
    has_files=false
    for base in $base_paths; do
        if [ -d "$merge_src/$base" ]; then
            has_files=true
            find "$merge_src/$base" -type f | sort | while read -r merged_file; do
                relpath="${merged_file#$merge_src/$base/}"
                if [ -f "$sysdir/$host_name/$base/$relpath" ]; then
                    printf "/$base/%s|%s|%s\n" "$relpath" "$sysdir/$host_name/$base/$relpath" "$host_name"
                elif [ -f "$sysdir/common/$base/$relpath" ]; then
                    printf "/$base/%s|%s|common\n" "$relpath" "$sysdir/common/$base/$relpath"
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

    # Phase 1: Pull all managed files from remote
    while IFS='|' read -r remote_path local_path source_label; do
        pulled="$tmpdir$remote_path"
        mkdir -p "$(dirname "$pulled")"
        scp -q "$target_host:$remote_path" "$pulled" 2>/dev/null || true
    done < "$manifest"

    # Phase 2: Compare and report
    drifted=0
    diff_log=$(mktemp)
    while IFS='|' read -r remote_path local_path source_label; do
        pulled="$tmpdir$remote_path"
        if [ ! -f "$pulled" ]; then
            printf "  {{yellow}}skip{{reset}}    %s (not found on remote)\n" "$remote_path"
            continue
        fi
        if ! diff -q "$local_path" "$pulled" >/dev/null 2>&1; then
            drifted=$((drifted + 1))
            printf "  {{yellow}}drifted{{reset}} %s (source: %s/)\n" "$remote_path" "$source_label"
            file_diff=$(diff -u "$local_path" "$pulled" 2>/dev/null | head -40 || true)
            { echo "=== $remote_path (overlay: $source_label/) ==="; echo "$file_diff"; echo ""; } >> "$diff_log"
            # Use diff-so-fancy if available, otherwise plain diff
            if command -v diff-so-fancy >/dev/null 2>&1; then
                echo "$file_diff" | head -30 | diff-so-fancy 2>/dev/null || echo "$file_diff" | head -30
            else
                echo "$file_diff" | head -30
            fi
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

    # Phase 3: Update overlay with remote versions
    updated=0
    while IFS='|' read -r remote_path local_path source_label; do
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
# Usage: just prepare-sd /Volumes/bootfs myrpi MyWiFi <wifi_password> [user]
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
    printf "  wifi:     %s\n\n" "$wifi_ssid"

    # Use helper script to generate firstrun.sh (avoids Just heredoc escaping issues)
    "{{hemma_dir}}/generate-firstrun.sh" "$bootfs/firstrun.sh" "$hostname" "$user" "$pass_hash" "$wifi_ssid" "$wifi_password"
    chmod +x "$bootfs/firstrun.sh"
    printf "  {{green}}✓{{reset}} firstrun.sh written\n"

    touch "$bootfs/ssh"
    printf "  {{green}}✓{{reset}} ssh marker created\n"

    current_cmdline=$(cat "$bootfs/cmdline.txt")
    clean_cmdline=$(echo "$current_cmdline" | sed 's| systemd.run=[^ ]* systemd.run_success_action=[^ ]* systemd.unit=[^ ]*||g' | sed 's| cfg80211.ieee80211_regdom=[^ ]*||g')
    printf '%s' "${clean_cmdline} systemd.run=/boot/firmware/firstrun.sh systemd.run_success_action=reboot systemd.unit=kernel-command-line.target" > "$bootfs/cmdline.txt"
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
