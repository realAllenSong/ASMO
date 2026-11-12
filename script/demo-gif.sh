#!/bin/bash
# Records assets/demo.gif: an agent conversation (drawn) beside real snapshots of the app as the same commands run
# against the Debug demo store (made-up items). Needs: script/run_test_store.sh-style Debug build in DerivedData/mac,
# python3 with Pillow, ffmpeg. The commands change the demo store only.
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
app="$PWD/DerivedData/mac/Build/Products/Debug/ASMO.app"
caches="$HOME/Library/Caches/com.realallensong.asmo"
asmo=".build/release/asmo"
swift build -c release --product asmo > /dev/null

/usr/bin/pkill -f "Debug/ASMO.app" 2>/dev/null || true
sleep 0.7
/usr/bin/open -g -n --env ASMO_TEST_STORE=demo "$app" --args -AppleLanguages "(en)" -desktopAppearance light
sleep 4
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$app" || true

snap() { script/snapshot.sh "$work/$1.png"; }
nav() { echo "$1" > "$caches/asmo-nav.txt"; sleep "${2:-2.5}"; }

snap app0
"$asmo" add "Run" --day 2026-11-11 --time 21:00 --end 22:00 --test > /dev/null
sleep 1; snap app1
"$asmo" add "Call with Li about the lease" --day 2026-11-12 --time 15:00 --end 15:30 --test > /dev/null
sleep 1; snap app2
"$asmo" page write 2026-11-12 --test > /dev/null <<'MD'
## Lease questions

- [ ] Is the deposit refundable?
- [ ] Who pays for repairs?
- [ ] Can we break it after 6 months?

```mermaid
graph LR
  Call[Call Li] --> Read[Read the draft] --> Sign((Sign))
```
MD
nav "edit:2026-11-12"
snap app3
nav close 1

python3 - "$work" assets/demo.gif <<'PY'
import subprocess, sys
from PIL import Image, ImageDraw, ImageFont
work, out = sys.argv[1], sys.argv[2]
H = 680
apps = []
for i in range(4):
    image = Image.open(f"{work}/app{i}.png").convert("RGB")
    apps.append(image.resize((round(image.width * H / image.height), H), Image.LANCZOS))
W_CHAT = 500
mono = ImageFont.truetype("/System/Library/Fonts/SFNSMono.ttf", 17)
sans = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 19)
small = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 15)
INK, QUIET, ACCENT, BG, CARD = (32, 30, 28), (120, 116, 110), (120, 84, 214), (246, 244, 239), (255, 255, 255)
prompt = ("I'm running from 9 to 10 tonight, and tomorrow at 3 I have a call with Li "
          "about the lease. Put my lease questions on tomorrow's page.")
steps = [
    ('asmo add "Run" --day today --time 21:00 --end 22:00', "Run · today 21:00–22:00"),
    ('asmo add "Call with Li about the lease" --day tomorrow --time 15:00 --end 15:30', "Call with Li · tomorrow 15:00"),
    ("asmo page write tomorrow  (checklist + diagram)", "Page of Nov 12 · 4 blocks"),
]

def wrap(text, font, width):
    lines, line = [], ""
    for word in text.split(" "):
        test = (line + " " + word).strip()
        if font.getlength(test) > width and line:
            lines.append(line); line = word
        else:
            line = test
    return lines + [line]

def chat(typed, shown, done):
    panel = Image.new("RGB", (W_CHAT, H), BG)
    d = ImageDraw.Draw(panel)
    d.text((28, 26), "Claude Code", font=small, fill=QUIET)
    y = 64
    lines = wrap(prompt[:typed], sans, W_CHAT - 92)
    box = 22 + 28 * len(lines)
    d.rounded_rectangle((28, y, W_CHAT - 28, y + box), 12, fill=CARD, outline=(226, 222, 214))
    for n, line in enumerate(lines):
        d.text((46, y + 12 + 28 * n), line, font=sans, fill=INK)
    y += box + 26
    for command, result in steps[:shown]:
        d.ellipse((30, y + 7, 40, y + 17), fill=ACCENT)
        for n, line in enumerate(wrap(command, mono, W_CHAT - 100)):
            d.text((52, y + 22 * n), line, font=mono, fill=INK)
            last = n
        y += 22 * (last + 1) + 4
        d.text((52, y), "→ " + result, font=small, fill=QUIET)
        y += 38
    if done:
        for n, line in enumerate(wrap("Done. Tonight 21:00–22:00 Run; tomorrow 15:00 the call with Li, "
                                      "and the questions are on tomorrow's page.", sans, W_CHAT - 70)):
            d.text((30, y + 28 * n), line, font=sans, fill=INK)
    return panel

frames = []
def frame(typed, shown, done, app, ms):
    canvas = Image.new("RGB", (W_CHAT + apps[0].width, H), BG)
    canvas.paste(chat(typed, shown, done), (0, 0))
    canvas.paste(apps[app], (W_CHAT, 0))
    frames.append((canvas, ms))

for typed in range(0, len(prompt) + 1, 12):
    frame(typed, 0, False, 0, 70)
frame(len(prompt), 0, False, 0, 900)
frame(len(prompt), 1, False, 1, 1600)
frame(len(prompt), 2, False, 2, 1600)
frame(len(prompt), 3, False, 3, 1800)
frame(len(prompt), 3, True, 3, 3600)

listing = []
for n, (image, ms) in enumerate(frames):
    image = image.resize((1600, round(image.height * 1600 / image.width)), Image.LANCZOS)
    image.save(f"{work}/f{n:03d}.png")
    listing.append(f"file '{work}/f{n:03d}.png'\nduration {ms / 1000}")
listing.append(f"file '{work}/f{len(frames) - 1:03d}.png'")
open(f"{work}/list.txt", "w").write("\n".join(listing))
subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "concat", "-safe", "0", "-i", f"{work}/list.txt",
                "-vf", "split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4",
                "-loop", "0", out], check=True)
PY
/usr/bin/pkill -f "Debug/ASMO.app" 2>/dev/null || true
ls -la assets/demo.gif
