#!/usr/bin/env python3
import csv
import os
import sys
from datetime import datetime


def usage() -> None:
    print("Usage: ./scripts/plot-history.py [csv_file] [svg_out]")
    print("Default csv_file: results/benchmark_history.csv")


def load_rows(path: str):
    rows = []
    with open(path, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for r in reader:
            try:
                ts = datetime.strptime(r["timestamp"], "%Y%m%d_%H%M%S")
                rows.append(
                    {
                        "timestamp": r["timestamp"],
                        "dt": ts,
                        "mode": r["mode"],
                        "max_us": float(r["max_us"]),
                        "avg_us": float(r["avg_us"]),
                        "min_us": float(r["min_us"]),
                    }
                )
            except Exception:
                continue
    rows.sort(key=lambda x: x["dt"])
    return rows


def split_modes(rows):
    baseline = [r for r in rows if r["mode"] == "baseline"]
    profiled = [r for r in rows if r["mode"] == "profiled"]
    return baseline, profiled


def svg_line(points, color, x_map, y_map):
    if not points:
        return ""
    coords = [f"{x_map(i):.1f},{y_map(p['max_us']):.1f}" for i, p in enumerate(points)]
    return f'<polyline fill="none" stroke="{color}" stroke-width="2" points="{" ".join(coords)}" />'


def main():
    csv_path = sys.argv[1] if len(sys.argv) > 1 else "results/benchmark_history.csv"
    if len(sys.argv) > 2:
        svg_path = sys.argv[2]
    else:
        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        svg_path = f"results/benchmark_plot_{ts}.svg"

    if not os.path.exists(csv_path):
        print(f"CSV not found: {csv_path}")
        return 1

    rows = load_rows(csv_path)
    if not rows:
        print("No valid rows in CSV")
        return 1

    baseline, profiled = split_modes(rows)
    all_max = [r["max_us"] for r in rows]
    max_y = max(all_max) if all_max else 1.0
    max_y = max(max_y, 10.0)

    width, height = 1000, 520
    left, right, top, bottom = 70, 30, 40, 70
    pw = width - left - right
    ph = height - top - bottom

    n = max(len(baseline), len(profiled), 1)

    def x_map(i):
        if n == 1:
            return left + pw / 2
        return left + (i / (n - 1)) * pw

    def y_map(v):
        return top + (1.0 - (v / max_y)) * ph

    y_ticks = 6
    tick_vals = [max_y * i / y_ticks for i in range(y_ticks + 1)]

    lines = []
    lines.append(f'<rect x="0" y="0" width="{width}" height="{height}" fill="#0f172a" />')
    lines.append(f'<rect x="{left}" y="{top}" width="{pw}" height="{ph}" fill="#111827" stroke="#334155" />')

    for tv in tick_vals:
        y = y_map(tv)
        lines.append(f'<line x1="{left}" y1="{y:.1f}" x2="{left+pw}" y2="{y:.1f}" stroke="#1f2937" />')
        lines.append(f'<text x="{left-10}" y="{y+4:.1f}" fill="#94a3b8" font-size="12" text-anchor="end">{tv:.0f}</text>')

    lines.append(svg_line(baseline, "#22c55e", x_map, y_map))
    lines.append(svg_line(profiled, "#38bdf8", x_map, y_map))

    for i, p in enumerate(baseline):
        x, y = x_map(i), y_map(p["max_us"])
        lines.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="3" fill="#22c55e" />')
    for i, p in enumerate(profiled):
        x, y = x_map(i), y_map(p["max_us"])
        lines.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="3" fill="#38bdf8" />')

    lines.append('<text x="24" y="28" fill="#e5e7eb" font-size="20" font-family="monospace">RT Latency Max(us) Trend</text>')
    lines.append('<text x="24" y="48" fill="#94a3b8" font-size="12" font-family="monospace">green=baseline blue=profiled</text>')
    lines.append(f'<text x="{left}" y="{height-18}" fill="#94a3b8" font-size="12" font-family="monospace">samples={n}  source={csv_path}</text>')

    svg = (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">'
        + "".join(lines)
        + "</svg>"
    )

    os.makedirs(os.path.dirname(svg_path) or ".", exist_ok=True)
    with open(svg_path, "w", encoding="utf-8") as f:
        f.write(svg)

    print(f"Saved plot: {svg_path}")
    print(f"Rows: {len(rows)} (baseline={len(baseline)}, profiled={len(profiled)})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
