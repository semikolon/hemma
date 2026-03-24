#!/usr/bin/env python3
"""Parse fleet.toml and output hemma fleet string.

Output format: name:ssh_host:role:critical (space-separated)
Used by Justfile to derive fleet inventory from the TOML source of truth.

Reads fleet.toml from $HEMMA_DOTFILES (default: ~/dotfiles).
"""
import os
import tomllib
from pathlib import Path

dotfiles = os.environ.get("HEMMA_DOTFILES", str(Path.home() / "dotfiles"))
fleet_path = Path(dotfiles) / "fleet.toml"

# Also check hemma dir itself (for standalone usage)
if not fleet_path.exists():
    fleet_path = Path(os.environ.get("HEMMA_DIR", ".")) / "fleet.toml"

data = tomllib.loads(fleet_path.read_text())

parts = []
for name, m in data["machines"].items():
    critical = str(m.get("critical", False)).lower()
    parts.append(f"{name}:{m['ssh_host']}:{m['role']}:{critical}")

print(" ".join(parts))
