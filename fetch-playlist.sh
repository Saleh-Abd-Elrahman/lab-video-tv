#!/bin/bash
# Downloads the playlist into videos/ and writes videos/playlist.js, which is the
# list local-display.html plays. Safe to re-run: an archive file records what has
# already been fetched, so a second run only picks up what's new.
#
# REQUIREMENTS
#   sudo apt install -y ffmpeg          # yt-dlp needs it to mux video with audio
#   sudo apt install -y yt-dlp
#
# yt-dlp goes stale badly — YouTube changes something and an old build simply
# stops working. If the version in apt starts failing, replace it with the
# current release and re-run:
#   sudo apt remove -y yt-dlp
#   mkdir -p ~/.local/bin
#   curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp \
#        -o ~/.local/bin/yt-dlp && chmod +x ~/.local/bin/yt-dlp
#
# USAGE
#   ./fetch-playlist.sh
#
# Videos dropped from the playlist upstream are left on disk but won't appear in
# playlist.js, so they stop being shown. Delete videos/ entirely and re-run for a
# clean slate.

set -euo pipefail

PLAYLIST_ID=PLjxddgZe17mykjPF2kbzCZFfGsw20HU1p
HERE="$(cd "$(dirname "$0")" && pwd)"
DIR="$HERE/videos"

# Vertical phone-shot clips. On the YouTube player these were skipped at
# playback time; here it is simpler not to have them on the disk at all.
SKIP=(
  91nEFo7FQDw   # VictorIA Project
  2KsvCRMe0O8   # Botzo Project
  Hl9w9s7gV_c   # Creating the Website
)

# These already have subtitles burned into the picture, so downloading a
# subtitle file for them would put the text on screen twice.
BURNED_IN_SUBS=(
  TnFKP2k0vCA
  5S9eMuWnhj8
  91nEFo7FQDw
  2KsvCRMe0O8
  Hl9w9s7gV_c
  Uhx3vMD4bh8
)

command -v yt-dlp >/dev/null || { echo "fetch-playlist: yt-dlp not installed — see the notes at the top of this file" >&2; exit 1; }
command -v ffmpeg >/dev/null || { echo "fetch-playlist: ffmpeg not installed — yt-dlp can't mux without it" >&2; exit 1; }

mkdir -p "$DIR"

# Build "id!=aaa & id!=bbb" for the ones to leave alone.
filter=""
for id in "${SKIP[@]}"; do
  filter="${filter:+$filter & }id!=$id"
done

# H.264 is not a preference here, it is the whole point. The Pi 4 has a hardware
# decoder for H.264 and for nothing else, so a VP9 file would be decoded on the
# processor and stutter exactly the way the YouTube embed used to. avc1 first,
# and the fallbacks after it are only there so an odd video without an H.264
# version still ends up on the disk rather than failing the whole run.
yt-dlp \
  --format 'bv*[vcodec^=avc1][height<=1080]+ba[acodec^=mp4a]/bv*[vcodec^=avc1][height<=1080]+ba/bv*[height<=1080]+ba/b[height<=1080]' \
  --merge-output-format mp4 \
  --match-filter "$filter" \
  --output "$DIR/%(playlist_index)03d-%(id)s.%(ext)s" \
  --download-archive "$DIR/.archive" \
  --write-subs --sub-langs 'en.*' --convert-subs vtt \
  --no-overwrites --ignore-errors --no-warnings \
  "https://www.youtube.com/playlist?list=$PLAYLIST_ID"

# Subtitles were fetched for everything, which is one pass instead of two; the
# ones that would double up with burned-in text get dropped again here.
for id in "${BURNED_IN_SUBS[@]}"; do
  rm -f "$DIR"/*"-$id".*.vtt
done

# playlist.js is generated rather than hand-kept so the page can't drift out of
# step with what is actually on the disk. Filenames carry the playlist index, so
# sorting them puts the videos back in the playlist's own order.
python3 - "$DIR" <<'PY'
import json, os, sys

folder = sys.argv[1]
names = sorted(os.listdir(folder))
items = []

for name in names:
    if not name.endswith('.mp4'):
        continue
    stem = name[:-4]
    vtt = next((v for v in names if v.startswith(stem + '.') and v.endswith('.vtt')), None)
    items.append({'file': name, 'vtt': vtt} if vtt else {'file': name})

with open(os.path.join(folder, 'playlist.js'), 'w') as f:
    f.write('// Written by fetch-playlist.sh. Edits here are lost on the next run.\n')
    f.write('window.PLAYLIST = ' + json.dumps(items, indent=2) + ';\n')

subs = sum(1 for i in items if 'vtt' in i)
print(f'playlist.js: {len(items)} videos, {subs} with subtitles')
PY
