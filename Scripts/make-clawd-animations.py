#!/usr/bin/env python3
"""Draw the workbench's extra Clawd pixel animations.

Every frame is drawn on Clawd's own 15x16 cell grid (the rects in
Resources/ClawdWeb/assets/clawd-idle-follow.svg) and scaled by whole pixels,
inside the same 45x45-cell viewBox as the upstream GIFs so all animations share
one framing. Requires Pillow:  python3 Scripts/make-clawd-animations.py
"""
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "Resources" / "Clawd"
CELL = 7                       # pixels per grid cell
VIEW_X, VIEW_Y, VIEW = -15, -25, 45
BODY, EYE, SHADOW = (0xDE, 0x88, 0x6D), (0, 0, 0), (0, 0, 0)
HEART, NOTE, SPARK = (0xD9, 0x77, 0x57), (0x3A, 0x2A, 0x24), (0xF2, 0xC1, 0x4E)


def crab(dx=0, dy=0, arms=(9, 9), eyes="open", look=0, legs=(0, 0), squat=0, shadow=9):
    """Rects for one Clawd pose. dy < 0 lifts the crab; squat lowers the body
    onto shorter legs; legs lifts the (left, right) leg pairs; look moves the eyes."""
    top = 6 + squat
    rects = [
        (2, top, 11, 7, BODY),                      # torso
        (0, arms[0] + squat, 2, 2, BODY),           # left arm
        (13, arms[1] + squat, 2, 2, BODY),          # right arm
    ]
    # A hand raised above the shoulder keeps a one-cell arm down to the body.
    for x, y in ((1, arms[0]), (13, arms[1])):
        if y < 7:
            rects.append((x, y + 2 + squat, 1, 8 - y, BODY))
    for x, lift in ((3, legs[0]), (5, legs[0]), (9, legs[1]), (11, legs[1])):
        rects.append((x, top + 5, 1, 4 - squat - lift, BODY))
    ey = top + 2
    for x in (4 + look, 10 + look):
        if eyes == "open":
            rects.append((x, ey, 1, 2, EYE))
        elif eyes == "closed":
            rects.append((x, ey + 1, 1, 1, EYE))
        elif eyes == "happy":               # ^ ^
            rects += [(x - 1, ey + 1, 1, 1, EYE), (x, ey, 1, 1, EYE), (x + 1, ey + 1, 1, 1, EYE)]
    moved = [(x + dx, y + dy, w, h, c) for x, y, w, h, c in rects]
    if shadow:                               # the ground shadow stays on the floor
        moved.insert(0, ((15 - shadow) // 2 + dx, 15, shadow, 1, SHADOW))
    return moved


def sprite(pattern, x, y, color):
    return [(x + i, y + j, 1, 1, color) for j, row in enumerate(pattern) for i, ch in enumerate(row) if ch == "#"]


HEART_ART = [".#.#.", "#####", "#####", ".###.", "..#.."]
NOTE_ART = ["..##", "..#.", "..#.", "###.", "##.."]
SPARK_ART = [".#.", "###", ".#."]


def render(frames, name, durations):
    images = []
    for rects in frames:
        image = Image.new("RGBA", (VIEW * CELL, VIEW * CELL), (0, 0, 0, 0))
        for x, y, w, h, color in rects:
            if w <= 0 or h <= 0:
                continue
            left, top = int(round((x - VIEW_X) * CELL)), int(round((y - VIEW_Y) * CELL))
            image.paste(color + (255,), (left, top, left + int(w * CELL), top + int(h * CELL)))
        images.append(image)
    # One shared palette with a reserved transparent index keeps colours exact.
    palette_source = Image.new("RGBA", (len(images) * VIEW * CELL, VIEW * CELL))
    for i, image in enumerate(images):
        palette_source.paste(image, (i * VIEW * CELL, 0))
    quantized = palette_source.convert("RGB").quantize(colors=15, method=Image.Quantize.FASTOCTREE)
    out = []
    for image in images:
        frame = image.convert("RGB").quantize(palette=quantized, dither=Image.Dither.NONE)
        mask = image.getchannel("A").point(lambda a: 255 if a == 0 else 0)
        frame.paste(15, mask=mask)
        out.append(frame)
    path = OUT / f"{name}.gif"
    out[0].save(path, save_all=True, append_images=out[1:], duration=durations, loop=0,
                transparency=15, disposal=2, optimize=False)
    print(path.relative_to(ROOT), len(out), "frames", sum(durations), "ms")


def hold(frames, durations, rects, ms):
    frames.append(rects); durations.append(ms)


def hop():
    f, d = [], []
    hold(f, d, crab(), 500)
    for _ in range(2):
        hold(f, d, crab(squat=1, arms=(10, 10)), 120)
        for lift, shadow in ((-2, 7), (-4, 5), (-5, 5), (-4, 5), (-2, 7)):
            hold(f, d, crab(dy=lift, arms=(7, 7), legs=(1, 1), shadow=shadow), 70)
        hold(f, d, crab(squat=1, arms=(10, 10)), 120)
        hold(f, d, crab(), 160)
    hold(f, d, crab(eyes="happy"), 600)
    hold(f, d, crab(), 300)
    return f, d


def wave():
    f, d = [], []
    hold(f, d, crab(), 400)
    hold(f, d, crab(arms=(9, 7)), 120)
    for _ in range(3):
        hold(f, d, crab(arms=(9, 4), eyes="happy"), 180)
        hold(f, d, crab(arms=(9, 6), eyes="happy"), 180)
    hold(f, d, crab(arms=(9, 7)), 120)
    hold(f, d, crab(eyes="closed"), 110)
    hold(f, d, crab(), 600)
    return f, d


def look():
    f, d = [], []
    hold(f, d, crab(), 600)
    hold(f, d, crab(look=-1), 900)
    hold(f, d, crab(), 200)
    hold(f, d, crab(look=1), 900)
    hold(f, d, crab(), 300)
    hold(f, d, crab(eyes="closed"), 110)
    hold(f, d, crab(), 250)
    hold(f, d, crab(eyes="closed"), 110)
    hold(f, d, crab(), 700)
    return f, d


def crabwalk():
    f, d = [], []
    hold(f, d, crab(), 300)
    path = [-1, -2, -3, -3, -2, -1, 0, 1, 2, 3, 3, 2, 1, 0]
    for i, dx in enumerate(path):
        legs = (1, 0) if i % 2 == 0 else (0, 1)
        look = -1 if i < 6 else 1 if i < 13 else 0
        hold(f, d, crab(dx=dx, legs=legs, look=look), 130)
    hold(f, d, crab(eyes="closed"), 110)
    hold(f, d, crab(), 500)
    return f, d


def heart():
    f, d = [], []
    hold(f, d, crab(), 300)
    hold(f, d, crab(arms=(7, 7), eyes="happy"), 160)
    for step, y in enumerate((1, 0, -1, -2, -3, -4)):
        bob = -1 if step % 2 == 0 else 0
        hold(f, d, crab(dy=bob, arms=(4, 4), eyes="happy") + sprite(HEART_ART, 5, y - 1, HEART), 150)
    hold(f, d, crab(arms=(5, 5), eyes="happy") + sprite(SPARK_ART, 6, -5, SPARK), 160)
    hold(f, d, crab(eyes="happy"), 500)
    hold(f, d, crab(), 300)
    return f, d


def hum():
    f, d = [], []
    for i in range(8):
        sway = -1 if i % 4 in (1, 2) else 0
        note = sprite(NOTE_ART, 13 + (i % 2), 1 - i // 2, NOTE)
        hold(f, d, crab(dx=sway, arms=(8, 10) if i % 2 else (10, 8), eyes="closed", legs=(i % 2, 1 - i % 2)) + note, 220)
    hold(f, d, crab(eyes="happy"), 500)
    hold(f, d, crab(), 300)
    return f, d


if __name__ == "__main__":
    for name, make in (("qishi-hop", hop), ("qishi-wave", wave), ("qishi-look", look),
                       ("qishi-crabwalk", crabwalk), ("qishi-heart", heart), ("qishi-hum", hum)):
        frames, durations = make()
        render(frames, name, durations)
