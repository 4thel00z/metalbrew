#!/usr/bin/env bash
#
# metalbrew vs Homebrew install benchmark (macOS aarch64).
#
#   ./bench/bench.sh            # Track A only (safe, fully reversible)
#   ./bench/bench.sh --with-deps  # also Track B (installs real dep trees — see WARNING)
#   python3 bench/plot.py       # regenerate docs/benchmark.svg from results.tsv
#
# Methodology
#   * Cold cache: the relevant bottle caches are cleared before every run, so each
#     timing includes the network download (metalbrew has no on-disk bottle cache,
#     so this is the only fair like-for-like).
#   * metalbrew installs into a throwaway prefix ($WORK) — your ~/.metalbrew is
#     never touched. The formula index is staged once (Homebrew's metadata is
#     already on disk, so neither tool re-fetches it per install).
#   * HOMEBREW_NO_AUTO_UPDATE=1 — otherwise `brew` runs `git fetch` and skews
#     timings by seconds.
#   * Timing = wall-clock `real` from `/usr/bin/time -p`, median of $RUNS.
#
# Track A — single-bottle, ZERO-dependency packages. Identical work each side
#   (download → extract → link one bottle). Packages absent from your system are
#   installed, timed, then uninstalled — your machine ends exactly as it started.
#
# Track B (--with-deps) — full dependency tree, cold. metalbrew installs the WHOLE
#   tree into the clean prefix; Homebrew installs only the bottles you're missing.
#   We record both bottle counts so the comparison is transparent.
#   WARNING: `brew install` of a dep-bearing package may AUTO-UPGRADE shared
#   dependencies already on your system (e.g. openssl@3). The restore step removes
#   only the newly-added formulae; upgraded shared deps stay upgraded. This is why
#   Track B is opt-in. Run `brew missing` afterward if you want to double-check.
set -uo pipefail

MB="$(command -v metalbrew || true)"
[ -n "$MB" ] || { echo "metalbrew not on PATH"; exit 1; }
command -v brew >/dev/null || { echo "brew not on PATH"; exit 1; }

RUNS=${RUNS:-3}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mbbench.XXXXXX")
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULTS="$ROOT/bench/results.tsv"
TEMPLATE="$WORK/template/.metalbrew"
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_INSTALL_CLEANUP=1

TRACK_A=(tokei micro gdu neofetch duf procs)   # zero-dependency
TRACK_B=(eza pandoc)                            # have dependency trees
WITH_DEPS=0
[ "${1:-}" = "--with-deps" ] && WITH_DEPS=1

trap 'rm -rf "$WORK"' EXIT
log(){ printf '\033[0;36m[bench]\033[0m %s\n' "$*" >&2; }

# echo real seconds; all command output (incl. /usr/bin/time's "real") -> logfile
timeit(){ local lf="$1"; shift; /usr/bin/time -p "$@" >>"$lf" 2>&1; awk '/^real/{v=$2} END{print v}' "$lf"; }
median(){ printf '%s\n' "$@" | sort -n | awk '{a[NR]=$1} END{print (NR%2)?a[(NR+1)/2]:(a[NR/2]+a[NR/2+1])/2}'; }
snapshot(){ brew list --formula -1 2>/dev/null | sort; }
brew_clear_cache(){ local c; c="$(brew --cache "$1" 2>/dev/null)"; [ -n "$c" ] && rm -f "$c"; }

fresh_prefix(){ # clean metalbrew prefix with the index pre-staged
  local p="$WORK/run.$RANDOM/.metalbrew"
  mkdir -p "$p/cache/api"
  cp "$TEMPLATE/cache/api/formula.json" "$p/cache/api/" 2>/dev/null
  echo "$p"
}

prep_index(){
  log "staging metalbrew index (one-time)…"
  mkdir -p "$TEMPLATE"
  METALBREW_PREFIX="$TEMPLATE" "$MB" update >/dev/null 2>&1 || { log "FATAL: metalbrew update failed"; exit 1; }
}

: > "$RESULTS"
prep_index

log "=== Track A: single-bottle leaf packages ==="
for pkg in "${TRACK_A[@]}"; do
  if snapshot | grep -qx "$pkg"; then log "SKIP $pkg (already installed)"; continue; fi
  bt=(); mt=()
  for i in $(seq 1 "$RUNS"); do
    brew_clear_cache "$pkg"
    t=$(timeit "$WORK/brew.$pkg.log" brew install "$pkg")
    brew uninstall --ignore-dependencies "$pkg" >/dev/null 2>&1
    bt+=("$t")
    pfx="$(fresh_prefix)"
    m=$(METALBREW_PREFIX="$pfx" timeit "$WORK/mb.$pkg.log" "$MB" install "$pkg")
    rm -rf "$(dirname "$pfx")"
    mt+=("$m")
    log "$pkg run$i: brew=${t}s metalbrew=${m}s"
  done
  printf 'A\t%s\t1\t1\t%s\t%s\n' "$pkg" "$(median "${bt[@]}")" "$(median "${mt[@]}")" >> "$RESULTS"
done

if [ "$WITH_DEPS" = 1 ]; then
  log "=== Track B: full dependency tree (cold) — may upgrade shared deps ==="
  for pkg in "${TRACK_B[@]}"; do
    if snapshot | grep -qx "$pkg"; then log "SKIP $pkg (already installed)"; continue; fi
    base="$(snapshot)"; deps="$(brew deps "$pkg" 2>/dev/null)"
    bt=(); mt=(); bcount=0; mcount=0
    for i in $(seq 1 "$RUNS"); do
      brew_clear_cache "$pkg"
      while IFS= read -r d; do [ -n "$d" ] && brew_clear_cache "$d"; done <<< "$deps"
      t=$(timeit "$WORK/brew.$pkg.log" brew install "$pkg")
      after="$(snapshot)"
      bcount=$(comm -13 <(printf '%s\n' "$base") <(printf '%s\n' "$after") | grep -c .)
      comm -13 <(printf '%s\n' "$base") <(printf '%s\n' "$after") | xargs -r brew uninstall --ignore-dependencies >/dev/null 2>&1
      bt+=("$t")
      pfx="$(fresh_prefix)"
      m=$(METALBREW_PREFIX="$pfx" timeit "$WORK/mb.$pkg.log" "$MB" install "$pkg")
      mcount=$(find "$(dirname "$pfx")/.metalbrew/Cellar" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | grep -c .)
      rm -rf "$(dirname "$pfx")"
      mt+=("$m")
      log "$pkg run$i: brew=${t}s (${bcount} new bottles) metalbrew=${m}s (${mcount} bottles)"
    done
    printf 'B\t%s\t%s\t%s\t%s\t%s\n' "$pkg" "$bcount" "$mcount" "$(median "${bt[@]}")" "$(median "${mt[@]}")" >> "$RESULTS"
  done
fi

log "=== done — results in bench/results.tsv ==="
cat "$RESULTS" >&2
