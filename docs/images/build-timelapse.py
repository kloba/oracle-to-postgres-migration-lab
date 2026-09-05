#!/usr/bin/env python3
"""Build the migration timelapse — compose the frames, then encode GIF and MP4.

Takes the screenshots captured during the real 2026-09-04 conversion run, scales
them to a common width, and stamps each with the wall-clock time it was taken,
the elapsed time since the first frame, and one line saying what is happening.
A progress bar along the bottom carries the sense of time passing, which is the
whole point of a timelapse and is otherwise invisible in a slideshow of dialogs.

Run it:  ./docs/images/build-timelapse.py

Needs ImageMagick and ffmpeg:
    brew install imagemagick ffmpeg     |     apt-get install -y imagemagick ffmpeg

Writes docs/images/migration-timelapse.gif (embedded in README.md, because GitHub
plays an animated GIF inline and will not play a committed .mp4) and
docs/images/migration-timelapse.mp4 (the same thing at better quality, linked).
Intermediate frames land in out/timelapse/, which is gitignored.

Do NOT hand-edit the .gif or .mp4. Edit the FRAMES table below and re-run.
"""
import subprocess
import sys
import pathlib
from PIL import Image, ImageDraw, ImageFont

REPO = pathlib.Path("/Users/tk/repos/oracle-to-postgres-migration-lab")
SHOTS = REPO / "docs/images/screenshots"
OUT = REPO / "out" / "timelapse"
OUT.mkdir(parents=True, exist_ok=True)

W = 1200                     # target frame width
BAR_H = 104                  # caption strip height
PROG_H = 5                   # progress bar height

BG      = (24, 24, 27)       # strip background, close to the VS Code chrome
FG      = (243, 244, 246)    # title
DIM     = (150, 154, 162)    # subtitle / right-hand meta
ACCENT  = (86, 156, 214)     # the extension's blue, used for the clock
OK      = (78, 201, 138)
WARN    = (220, 100, 100)
TRACK   = (48, 48, 54)

F_CLOCK = ImageFont.truetype("/System/Library/Fonts/Menlo.ttc", 26)
F_TITLE = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial Bold.ttf", 25)
F_SUB   = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", 19)
F_META  = ImageFont.truetype("/System/Library/Fonts/Menlo.ttc", 16)

# (source, clock, minutes-since-start, title, subtitle, accent colour for the clock)
FRAMES = [
    (SHOTS / "01-oracle-connected.png",   "19:11",   0,
     "Oracle connects",
     "localhost:1521/FREEPDB1 as CONTOSO — Load Schemas opens the real connection", ACCENT),

    (SHOTS / "02-schemas-contoso.png",    "19:12",   1,
     "One schema selected",
     "CONTOSO, not PUBLIC — 1,855 objects seeded, of which 1,299 are extractable", ACCENT),

    (SHOTS / "03-extensions-missing.png", "19:15",   4,
     "Verify Extensions finds nine missing",
     "azure.extensions allowlists them; nothing ever ran CREATE EXTENSION", WARN),

    (SHOTS / "04-extensions-verified.png","19:19",   8,
     "Extensions verified",
     "install-pg-extensions.sh — and plpgsql_check confirmed loaded, not just allowlisted", OK),

    (SHOTS / "05-apikey-disabled.png",    "19:20",   9,
     "The API key is refused",
     "a tenant policy rewrites disableLocalAuth to true on every write", WARN),

    (SHOTS / "06-foundry-entra-ok.png",   "19:26",  15,
     "Microsoft Entra ID accepted",
     "gpt-5.2 on Microsoft Foundry, 500 kTPM — the only auth path that works here", OK),

    (SHOTS / "07-project-created.png",    "19:26",  15,
     "Migration project created",
     "Schema Migration, Schema Review, Application Migration (preview)", ACCENT),

    (SHOTS / "08-extraction-failed.png",  "19:27",  16,
     "Extraction Failed — and that is the whole message",
     "ORA-00942 on V$RESOURCE_LIMIT: the pool never initialised, 0 objects out", WARN),

    (SHOTS / "08a-extracting.png", "19:31", 20,
     "Extracting, after one SYSDBA grant",
     "1,299 extracted, 0 failed, 185 excluded, in 2m 50s", OK),

    (SHOTS / "08b-converting.png",  "22:22", 191,
     "Converting — nearly three hours in",
     "56 chunks against gpt-5.2; it stalled twice on scratch-database catalog locks", ACCENT),

    (SHOTS / "09-migration-complete.png", "22:32", 201,
     "Migration Complete",
     "947 of 1,185 objects · 79.92% · 2h 56m 53s · 7,178,840 tokens", OK),
]

TOTAL = FRAMES[-1][2]


def elapsed(mins: int) -> str:
    return f"T+{mins // 60}:{mins % 60:02d}"


first = Image.open(FRAMES[0][0])
scale = W / first.width
IMG_H = round(first.height * scale)
H = IMG_H + BAR_H

for i, (src, clock, mins, title, sub, colour) in enumerate(FRAMES, 1):
    shot = Image.open(src).convert("RGB").resize((W, IMG_H), Image.LANCZOS)
    canvas = Image.new("RGB", (W, H), BG)
    canvas.paste(shot, (0, 0))
    d = ImageDraw.Draw(canvas)

    y = IMG_H + 22
    # clock + elapsed, monospace so the column does not jitter between frames
    d.text((28, y - 3), clock, font=F_CLOCK, fill=colour)
    cw = d.textlength(clock, font=F_CLOCK)
    d.text((28 + cw + 14, y + 4), elapsed(mins), font=F_META, fill=DIM)

    x = 28 + cw + 14 + d.textlength(elapsed(mins), font=F_META) + 26

    # Short, right-aligned on the title row. It has to be short: the longest
    # title runs to about x+570, so anything starting before ~x+620 collides.
    meta = "Oracle  ->  PostgreSQL"
    meta_w = d.textlength(meta, font=F_META)
    meta_x = W - 28 - meta_w
    d.text((meta_x, y + 4), meta, font=F_META, fill=(96, 99, 106))

    # Truncate rather than overlap, if a title or subtitle ever outgrows the gap.
    def fit(text, font, limit):
        if d.textlength(text, font=font) <= limit:
            return text
        while text and d.textlength(text + "...", font=font) > limit:
            text = text[:-1]
        return text + "..."

    avail = meta_x - x - 24
    d.text((x, y - 2), fit(title, F_TITLE, avail), font=F_TITLE, fill=FG)
    d.text((x, y + 30), fit(sub, F_SUB, W - 28 - x), font=F_SUB, fill=DIM)

    # progress bar: how far through the run this frame sits
    d.rectangle([0, H - PROG_H, W, H], fill=TRACK)
    d.rectangle([0, H - PROG_H, round(W * mins / TOTAL), H], fill=colour)

    canvas.save(OUT / f"frame-{i:02d}.png")
    print(f"frame-{i:02d}.png  {clock}  {elapsed(mins):>7}  {title}")

print(f"\n{len(FRAMES)} frames at {W}x{H}")


# ---------------------------------------------------------------------------
# Encode
#
# The GIF is written with one GIF frame per screenshot and a per-frame delay,
# so the file stays under a megabyte. Do not add `-layers Optimize`: it turns on
# transparency-based frame differencing, which on these screenshots produces a
# file that is a third the size and visibly corrupt -- earlier frames ghost
# through later ones. `-colors 256` without differencing is correct and small
# enough.
# ---------------------------------------------------------------------------
def need(tool):
    from shutil import which
    if which(tool) is None:
        sys.exit(f"build-timelapse: {tool} is not installed.\n"
                 f"fix: brew install imagemagick ffmpeg  |  apt-get install -y imagemagick ffmpeg")
    return tool


HOLD, FINAL_HOLD = 2.0, 4.5
frames = sorted(OUT.glob("frame-*.png"))

need("magick")
args = ["magick", "-loop", "0"]
for f in frames[:-1]:
    args += ["-delay", str(int(HOLD * 100)), str(f)]
args += ["-delay", str(int(FINAL_HOLD * 100)), str(frames[-1])]
args += ["-resize", "1100x", "-colors", "256", str(REPO / "docs/images/migration-timelapse.gif")]
subprocess.run(args, check=True)

need("ffmpeg")
listing = OUT / "concat.txt"
lines = [f"file '{f.name}'\nduration {HOLD}" for f in frames[:-1]]
lines.append(f"file '{frames[-1].name}'\nduration {FINAL_HOLD}")
lines.append(f"file '{frames[-1].name}'")   # repeated so the last duration is honoured
listing.write_text("\n".join(lines) + "\n")
subprocess.run([
    "ffmpeg", "-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", str(listing),
    "-vf", f"scale={W}:{H}:flags=lanczos,format=yuv420p", "-r", "25",
    "-c:v", "libx264", "-preset", "slow", "-crf", "20", "-movflags", "+faststart",
    str(REPO / "docs/images/migration-timelapse.mp4"),
], check=True)

for out in ("migration-timelapse.gif", "migration-timelapse.mp4"):
    kb = (REPO / "docs/images" / out).stat().st_size / 1024
    print(f"  {out:<28} {kb:7.0f} KB")
