<p align="center">
  <img src="logo.svg" alt="metalbrew" width="180">
</p>

<h1 align="center">metalbrew</h1>

<p align="center">
  <strong>Homebrew, rebuilt in Zig — no Ruby, no runtime, one static binary.</strong>
</p>

<p align="center">
  <a href="https://github.com/4thel00z/metalbrew/actions/workflows/ci.yml"><img src="https://github.com/4thel00z/metalbrew/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://ziglang.org/"><img src="https://img.shields.io/badge/zig-0.16.0-f7a41d?logo=zig&logoColor=white" alt="Zig 0.16.0"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT"></a>
  <img src="https://img.shields.io/badge/platform-macOS%20arm64-black?logo=apple" alt="macOS arm64">
</p>

---

## Motivation

Homebrew is Ruby all the way down — formulae are arbitrary Ruby run by a bundled interpreter. metalbrew takes the other road: treat the prebuilt `formulae.brew.sh` JSON index and bottles as the contract, and ship the client as one tiny, dependency-free binary that starts instantly. No Ruby, no GC, no runtime.

## Installation

```bash
git clone git@github.com:4thel00z/metalbrew.git
cd metalbrew
make install
```

Builds a release binary and drops `metalbrew` into `~/.local/bin`. Set `PREFIX` to install elsewhere (`make install PREFIX=/usr/local`).

## Usage

```bash
metalbrew update            # download + cache the formula index
metalbrew info wget         # name, version, description, dependencies
metalbrew search wget       # search formula names
metalbrew deps wget         # transitive runtime deps, in install order
```

The prefix defaults to `~/.metalbrew`; override with `METALBREW_PREFIX`.

## Architecture

Strict ports & adapters. The domain is pure and I/O-free; use-cases orchestrate it through ports; adapters and `main.zig` live at the edge.

| Layer | Path | Responsibility |
|-------|------|----------------|
| Domain | `src/domain/` | Value objects + dependency resolution (pure) |
| Ports | `src/ports/` | Interfaces the app needs (`PackageCatalog`, `IndexCache`) |
| App | `src/app/` | Use-cases: `update` · `info` · `search` · `deps` |
| Adapters | `src/adapters/` | HTTP, filesystem, JSON parsing, CLI |
| Composition | `src/main.zig` | Wires concrete adapters to use-cases |

## Roadmap

- [x] **M1** — read-only spine: index fetch + cache, `update` / `info` / `search` / `deps`, transitive resolution
- [ ] **M2** — install pipeline: ghcr.io bottle fetch + sha256 verify, Mach-O relocation, ad-hoc re-sign, keg linking, receipts; `install` / `uninstall` / `list`
- [ ] **M3** — `upgrade`: version-diff installed vs index, reinstall newer

## Development

```bash
make            # list all targets
make test       # full suite (network tests skip on failure)
make check      # format check + offline tests (CI-style)
```

Requires **Zig 0.16.0** on **macOS arm64**.

## License

[MIT](LICENSE) © 4thel00z
