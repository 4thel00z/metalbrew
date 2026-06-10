---
name: metalbrew
description: Use when installing, removing, searching, inspecting, or upgrading macOS (Apple Silicon) command-line packages with the metalbrew CLI — a Homebrew-compatible, Zig-based bottle package manager that installs into ~/.metalbrew without sudo. Also use when the user mentions "metalbrew", or wants brew-style package management without Homebrew or Ruby.
---

# metalbrew

## Overview

metalbrew is a Homebrew-compatible package manager written in Zig. It reads
Homebrew's public `formulae.brew.sh` JSON index and installs the same prebuilt
**bottles** (from ghcr.io, sha256-verified) into its **own prefix** —
`~/.metalbrew` by default, **no sudo**. It never touches an existing Homebrew.

Target: **macOS arm64 (Apple Silicon) only.**

## When to use

- Installing / removing / upgrading CLI tools on Apple Silicon without Homebrew.
- Searching or inspecting formula metadata and dependencies.
- The user names `metalbrew`, or wants brew-like installs without Ruby/sudo.

Not for: Linux or Intel macs; GUI casks; building from source (bottles only).

## Quick reference

| Command | What it does |
|---|---|
| `metalbrew update` | Download + cache the formula index. **Run this first.** |
| `metalbrew info <formula>` | Version, description, dependencies. |
| `metalbrew search <query>` | Case-insensitive substring search over names. |
| `metalbrew deps <formula>` | Transitive runtime deps, in install order. |
| `metalbrew install <formula>` | Fetch + verify + relocate + link a bottle and its deps. |
| `metalbrew list` | List installed packages. |
| `metalbrew uninstall <formula>` | Unlink and remove an installed package. |
| `metalbrew upgrade [<formula>]` | Upgrade all installed packages, or just one. |

## Key facts

- **`update` is a prerequisite.** `info`, `search`, `deps`, `install`, and
  `upgrade` read the cached index; without it they report "No index. Run
  `metalbrew update` first."
- **Prefix:** defaults to `~/.metalbrew` (`Cellar/`, `bin/`, `opt/`, …).
  Override per-invocation with the `METALBREW_PREFIX` env var.
- **Linked binaries** land in `~/.metalbrew/bin`. Add it to `PATH` to run them,
  or invoke directly (e.g. `~/.metalbrew/bin/xz --version`).
- Bottles are integrity-checked (sha256) and relocated + ad-hoc re-signed so
  they run from the metalbrew prefix.

## Common mistakes

- Running `install`/`search` before `update` → "No index" message. Fix: `update` first.
- Expecting Intel/Linux support — it's arm64 macOS only.
- Expecting tools on `PATH` immediately — link target is `~/.metalbrew/bin`.

## Verify it's installed

`metalbrew --version` (or `metalbrew help`) lists the commands above. Install
this skill itself into `~/.claude/skills/` with `metalbrew skill install`.
