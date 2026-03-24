# hemma

Swedish: *"at home"* — makes every machine feel like home.

Fleet provisioning orchestrator for dotfiles. Companion to [nit](https://github.com/semikolon/nit).

## Why hemma?

Managing dotfiles on one machine is solved. Managing them across five is not.

Your dotfile manager (nit, chezmoi, etc.) handles `$HOME` beautifully — but what about `/etc/nginx/nginx.conf`? What about `/etc/iptables/rules.v4` on your router? What about bootstrapping a fresh Raspberry Pi from a blank SD card to fully configured in one command?

hemma solves the gap between "my dotfiles are managed" and "my fleet is managed":

- **Dotfile sync** across your fleet via SSH — `hemma apply server` runs `nit update` (or `chezmoi update`) on the remote machine
- **System overlays** for files outside `$HOME` that dotfile managers don't touch — `/etc/`, `/opt/`, `/usr/local/`, `/Library/`
- **Bootstrap** new machines from zero to fully configured in one command
- **Drift detection** tells you when remote configs were changed outside hemma
- **Critical machine protection** prevents accidental changes to routers and infrastructure
- **RPi headless provisioning** prepares SD cards for zero-touch first boot

## Quick Start

### Prerequisites

- [just](https://github.com/casey/just) (command runner)
- Python 3.11+ (for fleet.toml parsing)
- rsync, ssh, age (standard tools)
- A dotfile manager: [nit](https://github.com/semikolon/nit) (preferred) or [chezmoi](https://www.chezmoi.io/)

### Install

```bash
# Clone into your dotfiles repo (or anywhere — it's self-contained)
git clone https://github.com/semikolon/hemma.git ~/dotfiles/hemma

# Or install standalone
git clone https://github.com/semikolon/hemma.git ~/hemma

# Add to PATH
export PATH="$HOME/dotfiles/hemma:$PATH"   # or wherever you cloned it
```

### Configure

1. Create `fleet.toml` at the root of your dotfiles repo (see [fleet.toml](#fleettoml) below)
2. Ensure each machine has an SSH config entry matching the `ssh_host` in fleet.toml
3. Set environment variables if your dotfiles aren't at `~/dotfiles`:
   ```bash
   export HEMMA_DOTFILES="$HOME/my-dotfiles"
   ```

### First run

```bash
hemma status          # See your fleet
hemma apply server    # Sync dotfiles to your server
hemma system-diff server  # Preview system config changes
```

## Commands

| Command | Description |
|---------|-------------|
| `hemma status` | Show fleet status — sync state, git hash, uptime, drift |
| `hemma apply <host>` | Sync dotfiles + system overlay to a host |
| `hemma apply-all` | Sync to all non-critical hosts (parallel) |
| `hemma apply-all --force` | Include critical hosts |
| `hemma update` | Update the local machine (pull + sync) |
| `hemma system-diff <host>` | Preview system config changes (dry-run) |
| `hemma system-apply <host>` | Deploy system config overlay to a host |
| `hemma system-apply-all` | Deploy system configs fleet-wide |
| `hemma system-pull <host>` | Pull live configs back to overlay (reverse sync) |
| `hemma system-pull-all` | Pull from all non-critical hosts |
| `hemma bootstrap <host> <ip> [user]` | Bootstrap a new machine from scratch |
| `hemma prepare-sd <bootfs> ...` | Prepare RPi SD card for headless first boot |
| `hemma run <host> <cmd>` | Run arbitrary command on a host |
| `hemma run-all <cmd>` | Run command on all non-critical hosts |
| `hemma ssh <host>` | Open SSH session to a host |

## fleet.toml

The fleet inventory. Place this at the root of your dotfiles repo. hemma reads it to know which machines exist, how to reach them, and how to treat them.

```toml
# Each machine's ssh_host must match an entry in ~/.ssh/config

[machines.server]
ssh_host = "server"        # SSH config alias
role = "server"
critical = false

[machines.laptop]
ssh_host = "laptop"
role = "laptop"
critical = false

[machines.router]
ssh_host = "router"
role = "router"
critical = true            # Excluded from --all operations

[machines.rpi]
ssh_host = "rpi"
role = "iot"
critical = false
```

**Fields:**

- `ssh_host` — The SSH host alias from `~/.ssh/config`. hemma uses this for all SSH/rsync operations.
- `role` — Comma-separated roles. Used for role-based system overlays (e.g., `"server,router"`).
- `critical` — When `true`, the host is excluded from `--all` operations and requires explicit confirmation before changes. Use for routers, gateways, and infrastructure where a bad deploy means network outage.

If you also use [nit](https://github.com/semikolon/nit), the same `fleet.toml` is shared — one file, both tools.

## Dotfile Sync

hemma wraps your dotfile manager for remote sync. It auto-detects nit or chezmoi on each machine:

```bash
hemma apply server    # SSH to server, run nit update (or chezmoi update)
hemma apply-all       # Do it in parallel for all non-critical hosts
```

When a host has system overlays, `hemma apply` automatically chains `system-apply` after the dotfile sync. One command does everything.

### Critical machine protection

Hosts with `critical = true` are excluded from `--all` operations. When you target them directly, hemma warns and asks for confirmation:

```
⚠ WARNING: router is marked as CRITICAL infrastructure.
Applying changes may affect network connectivity for all machines.
Continue? [y/N]
```

## System Overlays

This is hemma's core feature. Dotfile managers handle `$HOME`. hemma handles everything else.

### What are system overlays?

Files outside your home directory that need to be consistent across machines:

- `/etc/iptables/rules.v4` — firewall rules
- `/etc/nginx/nginx.conf` — web server config
- `/etc/cron.d/backups` — scheduled tasks
- `/opt/myservice/docker-compose.yml` — service definitions
- `/Library/Fonts/` — system fonts on macOS

These files need root to deploy and differ per machine. Your dotfile manager can't (or shouldn't) manage them.

### The overlay structure

Create a `system/` directory in your dotfiles repo:

```
system/
├── common/              # Shared across ALL machines
│   └── etc/
│       └── motd         # Message of the day for everyone
├── roles/               # Per-role configs
│   ├── router/
│   │   └── etc/
│   │       └── iptables/
│   │           └── rules.v4
│   └── server/
│       └── etc/
│           └── nginx/
│               └── nginx.conf
├── <hostname>/          # Machine-specific overrides
│   └── etc/
│       └── hostname
└── secrets/             # Age-encrypted sensitive configs
    └── <hostname>/
        └── etc/
            └── wireguard/
                └── wg0.conf.age
```

### Merge order

Overlays merge in this order — last wins:

1. `common/` — base configs shared by all machines
2. `roles/<role>/` — role-specific configs (a machine can have multiple roles)
3. `<hostname>/` — machine-specific overrides (highest priority)

If the same file exists in `common/etc/foo.conf` and `myserver/etc/foo.conf`, the machine-specific version wins.

### Permission manifests

Some files need specific ownership or permissions (e.g., SSL certificates, firewall rules). Create a `.hemma-perms` file alongside the configs:

```
# .hemma-perms — format: path:owner:group:mode
wireguard/wg0.conf:root:root:600
ssl/cert.pem:root:ssl-cert:644
```

hemma applies these permissions via `sudo chown`/`chmod` on the remote after rsync.

### Secrets

Sensitive files (passwords, certificates, API keys) go in `system/secrets/<hostname>/` as age-encrypted `.age` files. hemma decrypts them at deploy time using your local age key (from `~/.config/nit/key.txt` or `~/.config/chezmoi/key.txt`).

```bash
# Encrypt a secret for deployment
age -e -R recipients.txt -o system/secrets/router/etc/wireguard/wg0.conf.age wg0.conf
```

### Cross-platform path mapping

hemma automatically remaps macOS paths to Linux equivalents:

| macOS path | Linux equivalent |
|------------|-----------------|
| `/Library/Fonts/` | `/usr/local/share/fonts/` |
| `/Library/Keyboard Layouts/` | *(skipped — no Linux equivalent)* |

After deploying fonts to Linux, hemma runs `fc-cache` to rebuild the font cache.

### The diff/apply/pull workflow

**Preview changes** (always safe):
```bash
hemma system-diff server     # Shows what would change, changes nothing
```

**Deploy** (makes changes):
```bash
hemma system-apply server    # Shows preview, asks for confirmation, then deploys
```

**Reverse sync** (pull live configs back):
```bash
hemma system-pull server     # Compares remote to overlay, shows drift
```

### Drift detection

When you run `system-apply`, hemma first checks if remote files were modified outside hemma (e.g., someone SSH'd in and edited a config). If drift is detected, you get three choices:

```
⚠ Remote drift detected — 2 file(s) on server differ from overlay:
  /etc/nginx/nginx.conf
  /etc/cron.d/backups

These remote changes will be OVERWRITTEN.

Action? [O]verwrite all / [S]kip (abort) / [I]nteractive (per-file):
```

In interactive mode, you can overwrite, skip, or pull each file individually.

### Discovery

`system-pull` doesn't just check managed files — it also discovers:

- **Sibling files** — new files in directories you already manage (e.g., a new cron job appeared in `/etc/cron.d/`)
- **etckeeper changes** — if the remote uses [etckeeper](https://etckeeper.branchable.com/), hemma shows recently changed `/etc` files not in your overlay

This helps you decide what to bring under management.

### LLM-powered diff triage (optional)

If `hemma-diff-triage` is on `$PATH` and `$OPENAI_API_KEY` is set, `system-pull` pipes diffs through an LLM to categorize them (RUNTIME_DRIFT, CONFIG_CHANGE, SECRET_MISMATCH, etc.). This is entirely optional — hemma works fine without it.

## Bootstrap

Bootstrap takes a fresh, SSH-reachable machine to fully provisioned in one command:

```bash
hemma bootstrap myserver 192.168.1.100 admin
```

This runs 7 steps:

1. **Copy bootstrap.sh** to the remote machine
2. **Run bootstrap.sh** — installs dependencies, generates age + SSH keys, sets zsh
3. **Register SSH key** on GitHub (via `gh`)
4. **Register deploy key** for your dotfiles repo
5. **Add age recipient** — inserts the machine's age public key into your config template, re-encrypts all secrets
6. **Initialize dotfile manager** — runs `nit init --apply` (or `chezmoi init --apply`) on the remote
7. **Apply system overlay** — deploys system configs if any exist for this host

After bootstrap, the machine is part of your fleet — `hemma apply` and `hemma status` work immediately.

### Environment variables for bootstrap

Bootstrap needs to know your dotfiles repo:

```bash
export HEMMA_DOTFILES_REPO="youruser/dotfiles"     # GitHub owner/repo
export HEMMA_DOTFILES_SSH="git@github.com:youruser/dotfiles.git"
```

### bootstrap.sh

hemma looks for `bootstrap.sh` in your dotfiles repo root, then in the hemma directory. This script runs on the remote machine and should install basic dependencies (git, age, zsh, etc.) and generate SSH + age keys. Write your own — it's specific to your setup.

## RPi Headless Provisioning

For Raspberry Pi machines, hemma can prepare an SD card for zero-touch first boot:

```bash
# 1. Flash RPi OS to SD card (dd or RPi Imager)
# 2. Prepare the boot partition:
hemma prepare-sd /Volumes/bootfs myrpi MyWiFi wifi_password

# 3. Insert SD card, power on — first boot configures WiFi/SSH/user, reboots
# 4. Bootstrap once it's on the network:
hemma bootstrap myrpi 192.168.1.50 pi
```

`prepare-sd` writes a `firstrun.sh` script to the boot partition that:
- Sets the hostname
- Creates a user account
- Enables SSH
- Configures WiFi via NetworkManager
- Sets locale and regulatory domain
- Reboots into a ready-to-bootstrap state

## Integration with nit

hemma and [nit](https://github.com/semikolon/nit) share `fleet.toml` — one file defines your fleet for both tools. hemma handles orchestration and system overlays; nit handles the dotfiles themselves.

When nit is installed, hemma automatically uses it:
- `hemma update` calls `nit update`
- `hemma apply <host>` runs `nit update` on the remote
- `hemma status` checks `nit status` for drift counts

Without nit, hemma falls back to chezmoi with the same semantics.

## Configuration

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `HEMMA_DOTFILES` | `~/dotfiles` | Path to your dotfiles repo |
| `HEMMA_DOTFILES_REPO` | *(required for bootstrap)* | GitHub owner/repo (e.g., `youruser/dotfiles`) |
| `HEMMA_DOTFILES_SSH` | *(required for bootstrap)* | SSH clone URL for dotfiles |

### Optional tools

hemma gracefully enhances its output when these are available:

| Tool | Used for |
|------|----------|
| `rsync-humanize` | Human-readable diff output in system-diff/apply |
| [diff-so-fancy](https://github.com/so-fancy/diff-so-fancy) | Colorized diffs in system-pull |
| `hemma-diff-triage` | LLM-powered diff categorization (Fabric + OpenAI) |
| [etckeeper](https://etckeeper.branchable.com/) | Discovery of recently changed /etc files |
| [gh](https://cli.github.com/) | GitHub key registration during bootstrap |

All optional — hemma falls back to raw output or skips the feature.

## How It Works

hemma is a thin shell wrapper around a [Justfile](https://github.com/casey/just). The wrapper sets up environment variables; the Justfile contains all the logic.

```
hemma apply server
  ↓
hemma (shell wrapper) → sets HEMMA_DIR, HEMMA_DOTFILES
  ↓
just --justfile Justfile apply server
  ↓
parse-fleet.py → reads fleet.toml → outputs machine list
  ↓
SSH to server → nit update (or chezmoi update)
  ↓
If system overlay exists → rsync with sudo
```

System overlays use rsync with checksum comparison — only files with actual content changes are deployed, not timestamp-only differences.

## License

MIT
