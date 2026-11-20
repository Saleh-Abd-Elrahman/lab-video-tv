# Refreshing the videos on the lab TV

The TV plays `.mp4` files off the Pi's own disk, not YouTube. Adding a video to
the YouTube playlist therefore changes nothing on the screen until someone runs
the download script on the Pi. This is that procedure.

Nothing here needs a laptop or a deploy. It is all done on the Pi, over SSH or
with a keyboard plugged into it.

---

## The short version

```bash
cd ~/lab-tv
git pull                                   # only if the scripts changed
./fetch-playlist.sh                        # downloads whatever is new
pkill -f "user-data-dir=$HOME/.config/labtv-kiosk"   # reload the display
```

The last line kills Chromium. The supervisor script that is already running
notices within 30 seconds and starts it again, pointed at the rewritten
playlist. Do not reboot and do not kill the supervisor.

Everything below is why, and what to do when the short version isn't enough.

---

## How the pieces fit together

```
YouTube playlist
      │
      │  ./fetch-playlist.sh   (manual, on the Pi)
      ▼
~/lab-tv/videos/
      ├── 001-vs84JMNtjGI.mp4
      ├── 001-vs84JMNtjGI.en.vtt      ← subtitles, when the video has any
      ├── 002-K_ulRZjJXnA.mp4
      ├── ...
      ├── .archive                    ← ids already downloaded
      └── playlist.js                 ← generated; the list the page reads
      │
      │  python3 -m http.server 8080  (started by the supervisor)
      ▼
local-display.html  in Chromium kiosk  →  the TV
```

- **`fetch-playlist.sh`** is the only thing that touches `videos/`. It is safe to
  re-run as often as you like.
- **`playlist.js`** is written by that script every single run, from whatever
  `.mp4` files are actually on the disk. The page can't drift out of step with
  reality, and hand-editing it is pointless — the next run overwrites it.
- **`lab-tv-kiosk.sh`** is the supervisor. It runs from `~/.config/autostart/`
  at login, keeps the display up from 08:00 to 22:00 Madrid time, serves the
  folder on port 8080, and restarts Chromium whenever it dies. It knows nothing
  about the videos.

---

## Step by step

### 1. Add the video to the YouTube playlist

Ordinary YouTube work, nothing special. The playlist the Pi reads is fixed in
`fetch-playlist.sh`:

```
PLAYLIST_ID=PLjxddgZe17mykjPF2kbzCZFfGsw20HU1p
```

The video has to be public or unlisted. A private video cannot be downloaded
and the run will report an error for it and carry on.

### 2. Decide whether the video needs special handling

Two lists at the top of `fetch-playlist.sh` exist because some videos can't just
be played as-is. Check the new video against both **before** downloading — it
saves a second run.

**`SKIP`** — videos that should not appear on the TV at all. Currently the
vertical phone-shot clips, which would show as a thin strip between two black
bars on a 16:9 panel. Add the id and the file is deleted right after it is
fetched.

**`BURNED_IN_SUBS`** — videos that already have subtitle text baked into the
picture by whoever edited them. Downloading a subtitle file for these puts the
text on screen twice, one line over the other. Add the id and the `.vtt` is
deleted, leaving the video itself alone.

The id is the part of the YouTube URL after `v=`:
`https://www.youtube.com/watch?v=` **`K_ulRZjJXnA`**.

Both lists take one id per line, with a comment naming the video so the next
person knows what they're looking at:

```bash
SKIP=(
  91nEFo7FQDw   # VictorIA Project
  ...
  NEWIDHERE     # what this video is
)
```

You don't have to get this right in advance — see *"The new video shows its
subtitles twice"* below for fixing it after the fact.

### 3. Run the download

```bash
cd ~/lab-tv
./fetch-playlist.sh
```

It only downloads what it hasn't seen before, so this normally takes as long as
the one new video, not the whole playlist. The run ends with a line that is the
one thing worth reading:

```
playlist.js: 19 videos, 13 with subtitles
```

Check the video count went up by the number you added. If it didn't, jump to
*Troubleshooting*.

### 4. Reload the display

```bash
pkill -f "user-data-dir=$HOME/.config/labtv-kiosk"
```

The page reads `playlist.js` once, when it loads, so a display that is already
running keeps the old list in memory until Chromium is relaunched. It will be
back up within 30 seconds.

Out of hours (before 08:00, after 22:00) nothing is running and there is nothing
to reload — the next morning picks up the new playlist on its own.

### 5. Watch it for one full loop

The videos play in order with the logo card every 3rd video, so one full loop
takes a while, but you only really need to see the new video come round once.
Confirm:

- it plays, with sound
- it fills the screen rather than sitting in a box (if not: it's vertical, add
  it to `SKIP`)
- subtitles appear once, not twice, and not at all if the video has them burned
  in
- the picture doesn't stutter

Press **L** on a keyboard attached to the Pi to trigger the logo card by hand
without waiting.

---

## Troubleshooting

### The count didn't go up

```
Playlist ...: Downloading 0 items of 19
```

usually with a warning about an unsupported "lockup view model" just above it.
This means `yt-dlp` is too old — YouTube changed the shape of a page and the
installed build can no longer see anything on it. It is not a problem with this
script, and it will happen again eventually. Replace it with the current
release:

```bash
sudo apt remove -y yt-dlp
sudo curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp \
     -o /usr/local/bin/yt-dlp
sudo chmod a+rx /usr/local/bin/yt-dlp
./fetch-playlist.sh
```

Then run it again. `/usr/local/bin` rather than `~/.local/bin` so it is found
from a non-login shell too.

### The new video shows its subtitles twice

Its subtitles are burned into the picture. Add the id to `BURNED_IN_SUBS` and
re-run:

```bash
./fetch-playlist.sh
```

No re-download happens — the script deletes the `.vtt` and rewrites
`playlist.js` on every run regardless. Same procedure for adding an id to
`SKIP`.

### The new video has no subtitles when it should

The archive is recorded **per video, not per file**. A video already listed in
`videos/.archive` is skipped whole on the next run, so no subtitle file will
appear for it no matter what changes. To backfill:

```bash
rm videos/.archive
./fetch-playlist.sh
```

The `.mp4` files are kept (`--no-overwrites`), so this only costs the subtitle
downloads, and the archive is rebuilt as it goes.

If it still comes back with no `.vtt`, that video genuinely has no captions on
YouTube — neither uploaded nor auto-generated. Nothing to be done here; add
captions on YouTube and backfill again.

### The display sits on the logo card and won't play anything

That is the deliberate behaviour when `playlist.js` is empty or every file in it
fails: the card stays up and the page reloads every 60 seconds, so it recovers
on its own once the files are there. It is not a crash. Check that
`videos/*.mp4` exist and that the download finished.

### The display is plain white

Chromium is up but its page never loaded (2026-11-20: after a power cut, its
network service crashed mid-load). The supervisor now catches this on its own:
the page sends a heartbeat (`HEAD videos/playlist.js?hb=...`) every minute, and
if none arrives for 5 minutes (counted from 3 minutes after each browser start)
it restarts Chromium. It does this at most 3 times an hour. Look in `kiosk.log`
for `no heartbeat from the page`, and for `HEARTBEAT WATCHDOG GAVE UP`, which
means the restarts didn't help and something else is wrong. The heartbeats
themselves are in `http.log`:

```bash
grep -F '?hb=' http.log | tail -3
```

To recover by hand, restart the browser the usual way (step 4).

### A video plays but the picture stutters

The Pi 4 can only decode H.264 in hardware, and the script asks for H.264
first for exactly that reason. A video with no H.264 version available falls
back to whatever YouTube has, which the processor then has to decode on its own.
Check the decoder is being used, with the display up:

```bash
sudo fuser -v /dev/video10
```

Chromium in that list means the hardware decoder is doing the work.

### Taking an id back out of `SKIP`

The video was downloaded once and recorded in the archive before being deleted,
so removing it from the list is not enough on its own:

```bash
rm videos/.archive
./fetch-playlist.sh
```

---

## Two things to know about the playlist order

Filenames start with the video's position in the YouTube playlist
(`003-abc123.mp4`), and the page plays them in filename order. Two consequences:

**Inserting a video in the middle of the YouTube playlist doesn't renumber the
files already on the disk** — they aren't re-downloaded, so they keep the
numbers they had. The new video lands in roughly the right place and the rest
stay in their old relative order, which is usually fine. To get the true
playlist order back, start clean:

```bash
rm -rf videos
./fetch-playlist.sh          # re-downloads everything, takes a while
```

**Removing a video from the YouTube playlist leaves the file on the disk**, but
it stops appearing in `playlist.js`, so it stops being shown. Harmless. Delete
`videos/` and re-run if you want the disk space back.

---

## What is deliberately not automated

There is no cron job for this. The playlist changes a few times a year, a run
can fail in ways that want a human to look at them (a stale `yt-dlp`, a video
that needs adding to one of the lists), and an unattended run that half-worked
overnight is worse than a display showing last month's videos. Someone adds a
video, someone runs the script.
