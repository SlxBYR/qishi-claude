#!/usr/bin/env python3
"""Split the Claude starburst into layers for the workbench animation.

Input: the flat logo image (orange on white). Output, in Resources/ClaudeLogo:
core.png plus one spoke-NN.png per ray, all full-canvas alpha masks sharing the
same centre, and layout.json with that centre. The core holds the hub and the
inner part of every ray, where neighbouring rays join; it never moves. Each
spoke file holds only the outer part of its ray and overlaps the core by
OVERLAP pixels, so stretching or shortening a ray never opens a gap.
Requires Pillow:  python3 Scripts/make-claude-logo.py path/to/logo.png
"""
import json
import math
import shutil
import sys
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "Resources" / "ClaudeLogo"
JOIN = 2.2          # core radius, in hub radii: beyond the webbing between rays
OVERLAP = 30        # pixels each outer ray reaches back into the core


def main(source: Path):
    image = Image.open(source).convert("RGB")
    width, height = image.size
    px = image.load()
    # Coverage from the green channel: white is 255, the logo orange is 119.
    alpha = [[max(0.0, min(1.0, (255 - px[x, y][1]) / (255 - 119))) for x in range(width)] for y in range(height)]
    solid = [(x, y) for y in range(height) for x in range(width) if alpha[y][x] > 0.5]
    cx = sum(x for x, _ in solid) / len(solid)
    cy = sum(y for _, y in solid) / len(solid)

    def ring_coverage(r):
        samples = 360
        return sum(alpha[int(cy + r * math.sin(a))][int(cx + r * math.cos(a))] > 0.5
                   for a in (2 * math.pi * i / samples for i in range(samples))) / samples

    hub = 0
    while ring_coverage(hub + 1) > 0.97:
        hub += 1

    # Ray directions are the peaks of the angular histogram just outside the hub.
    bins = [0.0] * 720
    for x, y in solid:
        r = math.hypot(x - cx, y - cy)
        if hub * 1.3 < r < hub * 2.6:
            bins[int((math.degrees(math.atan2(y - cy, x - cx)) % 360) * 2)] += 1
    smooth = [sum(bins[(i + k) % 720] for k in range(-6, 7)) for i in range(720)]
    floor = max(smooth) * 0.25
    peaks = [i / 2 for i in range(720)
             if smooth[i] > floor and smooth[i] >= max(smooth[(i + k) % 720] for k in range(-14, 15))]
    rays = []
    for angle in peaks:                      # merge plateaus into single rays
        if not rays or angle - rays[-1] > 6:
            rays.append(angle)
    if len(rays) > 1 and rays[0] + 360 - rays[-1] <= 6:
        rays.pop()

    OUT.mkdir(parents=True, exist_ok=True)
    for old in [*OUT.glob("spoke-*.png"), OUT / "hub.png"]:
        old.unlink(missing_ok=True)

    def layer(select):
        mask = Image.new("L", (width, height), 0)
        mp = mask.load()
        for y in range(height):
            for x in range(width):
                if alpha[y][x] > 0 and select(x, y):
                    mp[x, y] = int(round(alpha[y][x] * 255))
        out = Image.new("RGBA", (width, height), (217, 119, 87, 0))
        out.putalpha(mask)
        return out

    join = hub * JOIN
    regions = []
    layer(lambda x, y: math.hypot(x - cx, y - cy) <= join).save(OUT / "core.png")

    # Outside the core every ray is its own connected region: assign pixels by
    # region, never by angle, so no edge fringe can ride along with a neighbour.
    owner = {}
    for y in range(height):
        for x in range(width):
            if alpha[y][x] > 0 and (x, y) not in owner and math.hypot(x - cx, y - cy) > join:
                region, queue = [], [(x, y)]
                owner[(x, y)] = -1
                while queue:
                    i, j = queue.pop()
                    region.append((i, j))
                    for di in (-1, 0, 1):
                        for dj in (-1, 0, 1):
                            k = (i + di, j + dj)
                            if 0 <= k[0] < width and 0 <= k[1] < height and k not in owner and alpha[k[1]][k[0]] > 0 \
                                    and math.hypot(k[0] - cx, k[1] - cy) > join:
                                owner[k] = -1
                                queue.append(k)
                regions.append(region)
    regions.sort(key=len, reverse=True)
    if len(regions) < len(rays):
        raise SystemExit(f"rays still touch beyond the core ({len(regions)} regions); raise JOIN")
    axes = []
    for region in regions[:len(rays)]:
        # Axis through the centre of the ray's body, just outside the core.
        near = [(x, y) for x, y in region if math.hypot(x - cx, y - cy) < join + 60] or region
        mx, my = sum(x for x, _ in near) / len(near), sum(y for _, y in near) / len(near)
        t = math.atan2(my - cy, mx - cx)
        half = max(abs(-(x - cx) * math.sin(t) + (y - cy) * math.cos(t)) for x, y in near if math.hypot(x - cx, y - cy) < join + 15)
        axes.append((math.degrees(t) % 360, t, half, set(region)))
    axes.sort(key=lambda axis: axis[0])
    for index, (_, t, half, region) in enumerate(axes):
        def mine(x, y, t=t, half=half, region=region):
            r = math.hypot(x - cx, y - cy)
            if r > join:
                return (x, y) in region
            # The root inside the overlap: a straight continuation of the body only.
            along = (x - cx) * math.cos(t) + (y - cy) * math.sin(t)
            across = -(x - cx) * math.sin(t) + (y - cy) * math.cos(t)
            return r > join - OVERLAP and along > 0 and abs(across) <= half
        layer(mine).save(OUT / f"spoke-{index:02d}.png")
    rays = [axis[0] for axis in axes]
    if source.resolve() != (OUT / "source.png").resolve():
        shutil.copyfile(source, OUT / "source.png")
    layout = {"size": [width, height], "center": [round(cx, 2), round(cy, 2)], "hubRadius": hub,
              "core": "core.png", "coreRadius": round(join, 1), "overlap": OVERLAP,
              "spokes": [{"file": f"spoke-{i:02d}.png", "angle": round(a, 2)} for i, a in enumerate(rays)]}
    (OUT / "layout.json").write_text(json.dumps(layout, indent=2) + "\n")
    print(f"centre ({cx:.1f}, {cy:.1f}), hub radius {hub}, {len(rays)} spokes")


if __name__ == "__main__":
    main(Path(sys.argv[1]) if len(sys.argv) > 1 else OUT / "source.png")
