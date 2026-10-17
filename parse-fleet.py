#!/usr/bin/env python3
"""Parse fleet.toml and output hemma fleet string.

Output format: name:ssh_host:role:critical (space-separated)
Used by Justfile to derive fleet inventory from the TOML source of truth.

Reads $HEMMA_DOTFILES/fleet.toml (default ~/dotfiles/fleet.toml): the single
fleet definition, shared with nit. There is deliberately no fallback to another
file. An earlier copy kept its own fleet.toml beside this script, it drifted,
and a stale role made `system-apply` deploy one machine's overlay onto another.
A missing fleet.toml is an error; to try hemma on the example, run it with
HEMMA_DOTFILES pointing at a folder holding a copy of examples/fleet.toml.

Supports both role formats:
  role = ["dev", "server"]   # array (nit standard)
  role = "dev,server"        # comma-separated string (legacy)
"""
import os
import sys
import tomllib
from pathlib import Path

dotfiles = Path(os.environ.get("HEMMA_DOTFILES", str(Path.home() / "dotfiles")))
fleet_path = dotfiles / "fleet.toml"
if not fleet_path.is_file():
    sys.exit(f"hemma: no fleet.toml at {fleet_path} (set HEMMA_DOTFILES)")

data = tomllib.loads(fleet_path.read_text())

parts = []
for name, m in data["machines"].items():
    critical = str(m.get("critical", False)).lower()
    role = m["role"]
    role_str = ",".join(role) if isinstance(role, list) else role
    parts.append(f"{name}:{m['ssh_host']}:{role_str}:{critical}")

print(" ".join(parts))
