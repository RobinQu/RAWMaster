from pathlib import Path

import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "docs" / "research" / "assets"
OUT.mkdir(parents=True, exist_ok=True)

COLORS = {
    "ink": "#17212B",
    "muted": "#627080",
    "blue": "#2878B5",
    "teal": "#2A9D8F",
    "orange": "#F4A261",
    "red": "#D9534F",
    "pale_blue": "#EAF3FA",
    "pale_teal": "#E8F6F3",
    "pale_orange": "#FFF3E6",
    "pale_red": "#FCECEB",
    "paper": "#FAFBFC",
}


def box(ax, xy, width, height, text, face, edge, fontsize=10, weight="normal"):
    x, y = xy
    patch = FancyBboxPatch(
        (x, y), width, height,
        boxstyle="round,pad=0.018,rounding_size=0.025",
        linewidth=1.4, edgecolor=edge, facecolor=face,
    )
    ax.add_patch(patch)
    ax.text(x + width / 2, y + height / 2, text, ha="center", va="center",
            fontsize=fontsize, color=COLORS["ink"], weight=weight, linespacing=1.35)
    return patch


def arrow(ax, start, end, color=None, style="-|>", connectionstyle="arc3", lw=1.5, ls="-"):
    arr = FancyArrowPatch(start, end, arrowstyle=style, mutation_scale=13,
                          linewidth=lw, linestyle=ls, color=color or COLORS["muted"],
                          connectionstyle=connectionstyle)
    ax.add_patch(arr)
    return arr


def current_lifecycle():
    fig, ax = plt.subplots(figsize=(14, 8), dpi=180)
    fig.patch.set_facecolor(COLORS["paper"])
    ax.set_facecolor(COLORS["paper"])
    ax.set_xlim(0, 14)
    ax.set_ylim(0, 8)
    ax.axis("off")
    ax.text(0.35, 7.55, "RAWMaster current filter-thumbnail lifecycle", fontsize=19,
            weight="bold", color=COLORS["ink"])
    ax.text(0.35, 7.15, "Display generation, recipe revision and pixel validity are coupled.",
            fontsize=11, color=COLORS["muted"])

    coords = [
        (0.45, 5.45, "Filter panel\nvisible"),
        (2.75, 5.45, "UI gates +\ncanonical witness"),
        (5.35, 5.45, "Matching settled\nmain frame"),
        (7.95, 5.45, "Prepare / reuse\n256 px proxy"),
        (10.45, 5.45, "10 serial tiles\nGPU wait + CPU copy"),
    ]
    for x, y, label in coords:
        box(ax, (x, y), 1.95, 1.0, label, COLORS["pale_blue"], COLORS["blue"], fontsize=10)
    for i in range(len(coords) - 1):
        x = coords[i][0] + 1.95
        arrow(ax, (x, 5.95), (coords[i + 1][0], 5.95), color=COLORS["blue"])

    box(ax, (5.35, 3.25), 2.3, 1.0, "Ready set adopted\nNSImage wrappers", COLORS["pale_teal"], COLORS["teal"], weight="bold")
    arrow(ax, (11.4, 5.42), (7.0, 4.28), color=COLORS["teal"], connectionstyle="arc3,rad=-0.15")

    box(ax, (0.75, 1.0), 2.55, 1.0, "Any recipe change\n(including filter-only)", COLORS["pale_red"], COLORS["red"], weight="bold")
    box(ax, (4.1, 1.0), 2.55, 1.0, "Cancel batch\nDetach last good set", COLORS["pale_red"], COLORS["red"])
    box(ax, (7.45, 1.0), 2.55, 1.0, "One automatic retry\nthen waitingForSource", COLORS["pale_red"], COLORS["red"])
    box(ax, (10.8, 1.0), 2.2, 1.0, "Manual retry\nBlank placeholders", COLORS["pale_red"], COLORS["red"], weight="bold")
    for a, b in [((3.3, 1.5), (4.1, 1.5)), ((6.65, 1.5), (7.45, 1.5)), ((10.0, 1.5), (10.8, 1.5))]:
        arrow(ax, a, b, color=COLORS["red"])
    arrow(ax, (1.95, 2.03), (6.0, 3.23), color=COLORS["red"], connectionstyle="arc3,rad=0.18")
    arrow(ax, (11.85, 2.03), (3.55, 5.42), color=COLORS["red"], connectionstyle="arc3,rad=0.22", ls="--")

    box(ax, (8.2, 3.25), 4.4, 1.0,
        "Shared native worker + quiet-window scheduling\nCanonical work can starve thumbnail generation",
        COLORS["pale_orange"], COLORS["orange"], fontsize=10)
    arrow(ax, (10.35, 4.27), (11.25, 5.42), color=COLORS["orange"], ls="--")

    ax.text(0.5, 0.35, "Observed failure modes: awaitingSource, staleSource, superseded; old images are removed before replacement is ready.",
            fontsize=10, color=COLORS["muted"])
    fig.tight_layout()
    fig.savefig(OUT / "current-filter-thumbnail-lifecycle.png", bbox_inches="tight", facecolor=fig.get_facecolor())
    plt.close(fig)


def target_architecture():
    fig, ax = plt.subplots(figsize=(14, 9), dpi=180)
    fig.patch.set_facecolor(COLORS["paper"])
    ax.set_facecolor(COLORS["paper"])
    ax.set_xlim(0, 14)
    ax.set_ylim(0, 9)
    ax.axis("off")
    ax.text(0.35, 8.55, "Target: independent content lifetimes + GPU-resident rendering", fontsize=19,
            weight="bold", color=COLORS["ink"])
    ax.text(0.35, 8.15, "Revision controls delivery; content keys control reuse. Last-known-good pixels stay visible.",
            fontsize=11, color=COLORS["muted"])

    layers = [
        (6.95, "UI / delivery epoch", "Visibility · latest-request-wins · atomic swap · stale badge", COLORS["pale_blue"], COLORS["blue"]),
        (5.45, "Candidate pixels", "Normalized recipe content key · filter-only edits reuse all 10 tiles", COLORS["pale_teal"], COLORS["teal"]),
        (3.95, "256 px source proxy", "Source + decoder + native WB / EV / NR · grace-period LRU", COLORS["pale_teal"], COLORS["teal"]),
        (2.45, "LUT GPU resources", "Catalog generation · bounded LRU · no per-tile trim / reload", COLORS["pale_orange"], COLORS["orange"]),
    ]
    for y, title, subtitle, face, edge in layers:
        box(ax, (0.65, y), 5.25, 1.05, f"{title}\n{subtitle}", face, edge, fontsize=10, weight="bold" if y == 6.95 else "normal")

    box(ax, (7.0, 6.55), 2.0, 1.0, "2400 px\ninteractive proxy", COLORS["pale_blue"], COLORS["blue"], weight="bold")
    box(ax, (9.35, 6.55), 1.55, 1.0, "Global", COLORS["pale_blue"], COLORS["blue"])
    box(ax, (11.25, 6.55), 1.55, 1.0, "Photo LUT", COLORS["pale_orange"], COLORS["orange"], weight="bold")
    arrow(ax, (9.0, 7.05), (9.35, 7.05), color=COLORS["blue"])
    arrow(ax, (10.9, 7.05), (11.25, 7.05), color=COLORS["blue"])
    box(ax, (9.0, 5.05), 2.0, 1.0, "Advanced / Mask\nsame canonical order", COLORS["pale_blue"], COLORS["blue"])
    box(ax, (11.35, 5.05), 1.55, 1.0, "Metal\npresenter", COLORS["pale_teal"], COLORS["teal"], weight="bold")
    arrow(ax, (12.0, 6.52), (10.2, 6.08), color=COLORS["blue"], connectionstyle="arc3,rad=-0.15")
    arrow(ax, (11.0, 5.55), (11.35, 5.55), color=COLORS["teal"])

    box(ax, (7.0, 3.05), 2.0, 1.0, "256 px proxy\n(no settled gate)", COLORS["pale_teal"], COLORS["teal"])
    box(ax, (9.35, 3.05), 1.8, 1.0, "Batched 10 looks\nvisible first", COLORS["pale_teal"], COLORS["teal"])
    box(ax, (11.5, 3.05), 1.4, 1.0, "GPU atlas\natomic swap", COLORS["pale_teal"], COLORS["teal"], weight="bold")
    arrow(ax, (9.0, 3.55), (9.35, 3.55), color=COLORS["teal"])
    arrow(ax, (11.15, 3.55), (11.5, 3.55), color=COLORS["teal"])

    box(ax, (7.0, 0.85), 5.9, 1.1,
        "Settled / Save / Export\nCanonical full-resolution renderer remains authoritative; interactive proxies never replace final output.",
        COLORS["pale_red"], COLORS["red"], fontsize=10)
    arrow(ax, (8.0, 5.0), (8.5, 1.98), color=COLORS["muted"], ls="--", connectionstyle="arc3,rad=0.12")
    arrow(ax, (12.2, 3.02), (11.5, 1.98), color=COLORS["muted"], ls="--", connectionstyle="arc3,rad=-0.1")

    ax.text(0.7, 0.35, "Performance work is gated by input-to-presented-frame measurements, not API return time.",
            fontsize=10, color=COLORS["muted"])
    fig.tight_layout()
    fig.savefig(OUT / "target-filter-rendering-architecture.png", bbox_inches="tight", facecolor=fig.get_facecolor())
    plt.close(fig)


def performance_chart():
    labels = ["Exposure", "Texture", "Clarity"]
    lightflow = [10.0525, 9.4525, 10.3725]
    rawmaster = [18.4, 26.6, 32.2]
    x = np.arange(len(labels))
    width = 0.34
    fig, ax = plt.subplots(figsize=(10.5, 6.2), dpi=180)
    fig.patch.set_facecolor(COLORS["paper"])
    ax.set_facecolor(COLORS["paper"])
    bars1 = ax.bar(x - width / 2, lightflow, width, label="LightFlow frame event median", color=COLORS["teal"])
    bars2 = ax.bar(x + width / 2, rawmaster, width, label="RAWMaster UI interaction median", color=COLORS["orange"])
    ax.set_ylabel("Milliseconds (lower is better)")
    ax.set_title("Existing main-preview measurements — not filter-specific", fontsize=16, weight="bold", pad=18)
    ax.set_xticks(x, labels)
    ax.set_ylim(0, 38)
    ax.grid(axis="y", alpha=0.22)
    ax.spines[["top", "right"]].set_visible(False)
    ax.legend(frameon=False, loc="upper left")
    ax.bar_label(bars1, fmt="%.1f", padding=3)
    ax.bar_label(bars2, fmt="%.1f", padding=3)
    fig.text(0.1, 0.015,
             "Different instrumentation boundaries; use only as an order-of-magnitude baseline, not a strict benchmark.\n"
             "Sources: output/lightflow-research/runtime-summary.json and specs/024-jpeg-display-proxy/editing-performance-comparison.md.",
             fontsize=9, color=COLORS["muted"])
    fig.tight_layout(rect=(0, 0.09, 1, 1))
    fig.savefig(OUT / "existing-interactive-performance.png", bbox_inches="tight", facecolor=fig.get_facecolor())
    plt.close(fig)


if __name__ == "__main__":
    current_lifecycle()
    target_architecture()
    performance_chart()
    print(OUT)
