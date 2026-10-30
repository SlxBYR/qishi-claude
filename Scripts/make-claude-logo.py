#!/usr/bin/env python3
"""Split the Claude starburst into layers for the workbench animation.

Input: the flat logo image (orange on white). Output, in Resources/ClaudeLogo:
hub.png plus one spoke-NN.png per ray, all full-canvas alpha masks sharing the
same centre, and layout.json with that centre. Each spoke keeps a root that
reaches into the hub, so scaling a spoke outward never opens a gap.
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
    for old in OUT.glob("spoke-*.png"):
        old.unlink()

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

    layer(lambda x, y: math.hypot(x - cx, y - cy) <= hub + 1).save(OUT / "hub.png")

    def nearest_ray(x, y):
        angle = math.degrees(math.atan2(y - cy, x - cx)) % 360
        return min(range(len(rays)), key=lambda i: abs((angle - rays[i] + 180) % 360 - 180))

    for index in range(len(rays)):
        layer(lambda x, y, i=index: math.hypot(x - cx, y - cy) > hub * 0.45 and nearest_ray(x, y) == i) \
            .save(OUT / f"spoke-{index:02d}.png")
    shutil.copyfile(source, OUT / "source.png")
    layout = {"size": [width, height], "center": [round(cx, 2), round(cy, 2)], "hubRadius": hub,
              "spokes": [{"file": f"spoke-{i:02d}.png", "angle": a} for i, a in enumerate(rays)]}
    (OUT / "layout.json").write_text(json.dumps(layout, indent=2) + "\n")
    print(f"centre ({cx:.1f}, {cy:.1f}), hub radius {hub}, {len(rays)} spokes")


if __name__ == "__main__":
    main(Path(sys.argv[1]) if len(sys.argv) > 1 else OUT / "source.png")
