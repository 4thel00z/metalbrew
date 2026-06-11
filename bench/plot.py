#!/usr/bin/env python3
"""Render bench/results.tsv into docs/benchmark.svg (grouped horizontal bars).

No dependencies — hand-writes a small SVG so it renders crisply on GitHub in
both light and dark themes. Re-run after ./bench.sh:  python3 bench/plot.py
"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TSV = os.path.join(ROOT, "bench", "results.tsv")
OUT = os.path.join(ROOT, "docs", "benchmark.svg")

BREW = "#8a8f98"   # neutral slate — Homebrew
META = "#f7a41d"   # Zig gold — metalbrew
INK = "#1f2328"
MUTE = "#57606a"
GRID = "#d0d7de"
CARD = "#ffffff"
BORDER = "#d0d7de"


def esc(s: str) -> str:
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def load():
    rows = []
    with open(TSV) as f:
        for line in f:
            p = line.rstrip("\n").split("\t")
            if len(p) != 6:
                continue
            track, name, bbot, mbot, btime, mtime = p
            rows.append((track, name, int(bbot), int(mbot), float(btime), float(mtime)))
    return rows


def main():
    rows = [r for r in load() if r[0] == "A"]  # Track A = identical work
    if not rows:
        sys.exit("no Track A rows in results.tsv")

    W = 760
    pad_l, pad_r, pad_t, pad_b = 96, 70, 78, 42
    group_h = 44
    bar_h = 14
    bar_gap = 3
    H = pad_t + len(rows) * group_h + pad_b

    plot_w = W - pad_l - pad_r
    vmax = max(r[4] for r in rows)
    axis_max = (int(vmax) + 1) if vmax > int(vmax) else int(vmax) + 1
    sx = plot_w / axis_max

    s = []
    s.append(f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" '
             f'viewBox="0 0 {W} {H}" font-family="-apple-system,Segoe UI,Helvetica,Arial,sans-serif">')
    s.append(f'<rect x="0.5" y="0.5" width="{W-1}" height="{H-1}" rx="10" fill="{CARD}" stroke="{BORDER}"/>')
    s.append(f'<text x="{pad_l}" y="34" font-size="19" font-weight="700" fill="{INK}">'
             f'metalbrew vs Homebrew — install time</text>')
    s.append(f'<text x="{pad_l}" y="54" font-size="12.5" fill="{MUTE}">'
             f'single-bottle packages · cold cache · median of 3 · lower is better</text>')

    # legend
    lx = W - pad_r - 250
    s.append(f'<rect x="{lx}" y="20" width="12" height="12" rx="2" fill="{BREW}"/>')
    s.append(f'<text x="{lx+18}" y="30" font-size="12.5" fill="{INK}">Homebrew</text>')
    s.append(f'<rect x="{lx+100}" y="20" width="12" height="12" rx="2" fill="{META}"/>')
    s.append(f'<text x="{lx+118}" y="30" font-size="12.5" fill="{INK}">metalbrew</text>')

    # x gridlines + labels
    for i in range(axis_max + 1):
        gx = pad_l + i * sx
        s.append(f'<line x1="{gx:.1f}" y1="{pad_t}" x2="{gx:.1f}" y2="{H-pad_b}" '
                 f'stroke="{GRID}" stroke-width="1"/>')
        s.append(f'<text x="{gx:.1f}" y="{H-pad_b+16}" font-size="11" fill="{MUTE}" '
                 f'text-anchor="middle">{i}s</text>')

    # bars
    for idx, (_, name, _, _, bt, mt) in enumerate(rows):
        gy = pad_t + idx * group_h
        s.append(f'<text x="{pad_l-12}" y="{gy+group_h/2+1:.1f}" font-size="13" '
                 f'font-weight="600" fill="{INK}" text-anchor="end">{esc(name)}</text>')
        y1 = gy + (group_h - (2 * bar_h + bar_gap)) / 2
        bw = bt * sx
        s.append(f'<rect x="{pad_l}" y="{y1:.1f}" width="{bw:.1f}" height="{bar_h}" rx="2.5" fill="{BREW}"/>')
        s.append(f'<text x="{pad_l+bw+6:.1f}" y="{y1+bar_h-3:.1f}" font-size="11.5" '
                 f'fill="{MUTE}">{bt:.2f}s</text>')
        y2 = y1 + bar_h + bar_gap
        mw = mt * sx
        s.append(f'<rect x="{pad_l}" y="{y2:.1f}" width="{mw:.1f}" height="{bar_h}" rx="2.5" fill="{META}"/>')
        spd = bt / mt if mt else 0
        s.append(f'<text x="{pad_l+mw+6:.1f}" y="{y2+bar_h-3:.1f}" font-size="11.5" '
                 f'fill="{INK}" font-weight="600">{mt:.2f}s  ({spd:.1f}× faster)</text>')

    s.append('</svg>')
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w") as f:
        f.write("\n".join(s) + "\n")
    print(f"wrote {OUT} ({len(rows)} packages)")


if __name__ == "__main__":
    main()
