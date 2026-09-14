#!/bin/bash
# Lab TV kiosk supervisor.
#
# Holds the display up between ON_HOUR and OFF_HOUR Madrid time and leaves the
# panel asleep the rest of the day. It is also the whole crash recovery story:
# if Chromium dies during opening hours the next pass round the loop starts it
# again, and nothing outside this file needs to know the schedule.
#
# INSTALL (on the Pi)
#   sudo apt install wlopm || sudo apt install wlr-randr   # to sleep the panel
#   sudo apt install ffmpeg yt-dlp                         # to download the videos
#   git clone <this repo> ~/lab-tv
#   chmod +x ~/lab-tv/*.sh
#   ~/lab-tv/fetch-playlist.sh                             # fills ~/lab-tv/videos
#   ~/lab-tv/hide-cursor.sh                                # hides the mouse pointer
#   cp ~/lab-tv/lab-tv-kiosk.desktop ~/.config/autostart/
#   reboot

set -u

# The local player, served off this box — no network needed once the videos are
# downloaded. Point this at https://lab-video-tv.vercel.app instead to go back to
# streaming the playlist from YouTube; everything else here works either way.
URL="http://localhost:8080/local-display.html"
PORT=8080
ON_HOUR=8                 # first hour of the day the display is up
OFF_HOUR=22               # first hour it is down
ZONE=Europe/Madrid        # by name, not by offset, so the clocks change on their own
POLL=30                   # seconds between checks

OUTPUT=HDMI-A-1           # `wlr-randr` with no arguments lists the output names

HERE="$(cd "$(dirname "$0")" && pwd)"
EXT="$HERE/h264-only"
PROFILE="$HOME/.config/labtv-kiosk"   # also how we recognise our own Chromium
LOG="$HERE/kiosk.log"
BROWSER="$(command -v chromium || command -v chromium-browser)"

if [ -z "$BROWSER" ]; then
  echo "lab-tv: no chromium on PATH, nothing to run" >&2
  exit 1
fi

# Autostart can hand us the session before the audio server has published a
# sink, and Chromium only looks for output devices as it starts up. Miss that
# window and it plays to nothing for as long as it runs, while every manual test
# afterwards works fine.
sleep 10

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"

# The journal on this box is volatile — /var/log/journal does not exist, so
# every boot starts with a clean slate and a display that went dark in the night
# leaves nothing behind to read in the morning. Hence our own log: a handful of
# lines a day, only when something actually changes.
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }

# The panel doesn't speak CEC — a topology scan finds nothing at all on the bus
# except this box — so it gets put to sleep by powering the Wayland output down
# and letting the panel drop into standby on its own once the signal stops.
#
# Best effort: without one of these tools the display still keeps its hours, it
# just shows the panel's own no-signal screen overnight instead of going dark.
# What it is not allowed to do is fail quietly, which is how a display that
# never woke up went unexplained for as long as it did.
panel() {
  local out
  if command -v wlopm >/dev/null; then
    out=$(wlopm "--$1" "$OUTPUT" 2>&1)
  elif command -v wlr-randr >/dev/null; then
    out=$(wlr-randr --output "$OUTPUT" "--$1" 2>&1)
  else
    out="no wlopm or wlr-randr installed"
  fi
  log "panel $1${out:+ -- $out}"
}

# What the compositor thinks the output is doing: "on", "off", or empty when it
# has stopped listing the output at all. That last case is the one to watch for
# in the log — it would mean the display dropped off the bus while it slept and
# the compositor let it go, which no amount of powering the output back on can
# fix from here.
panel_state() {
  command -v wlopm >/dev/null || { echo unknown; return; }
  wlopm 2>/dev/null | awk -v o="$OUTPUT" '$1 == o { print $2 }'
}

# The kernel's side of the story: whether HDMI came loose while the display
# slept, which is the one thing our own logging cannot see. It goes to disk as
# it appears rather than being read on demand, because the ring buffer it comes
# from does not survive the power cycle that people reach for when the display
# is dark, and neither does the journal on this box.
kernel_lines() {
  local n
  n=$(dmesg 2>/dev/null | wc -l) || return 0
  # A wrapped ring buffer gets read from the start again: what fell off is gone
  # either way, and repeating what is still there beats losing the rest.
  [ "$n" -lt "$dmesg_seen" ] && dmesg_seen=0
  if [ "$n" -gt "$dmesg_seen" ]; then
    dmesg 2>/dev/null | tail -n +$((dmesg_seen + 1)) |
      grep -iE 'hdmi|vc4|drm' |
      while IFS= read -r line; do log "kernel: $line"; done
    dmesg_seen=$n
  fi
}

running() { pgrep -f "user-data-dir=$PROFILE" >/dev/null; }
serving() { pgrep -f "http.server $PORT" >/dev/null; }

log "supervisor started (display hours ${ON_HOUR}-${OFF_HOUR} $ZONE)"
last_state=
dmesg_seen=$(dmesg 2>/dev/null | wc -l)

while :; do
  kernel_lines

  # local-display.html has to arrive over HTTP rather than as a file:// URL:
  # Chromium refuses to load subtitle tracks off the filesystem. Bound to
  # localhost so this isn't serving the folder to the network.
  if ! serving; then
    python3 -m http.server "$PORT" --directory "$HERE" --bind 127.0.0.1 \
      >/dev/null 2>&1 &
  fi

  hour=$(TZ="$ZONE" date +%-H)

  if [ "$hour" -ge "$ON_HOUR" ] && [ "$hour" -lt "$OFF_HOUR" ]; then
    # Waking the panel used to be tied to starting the browser, which left one
    # way for the display to stay dark all day: any path that ends with the
    # output powered down while Chromium is still up had nothing left to turn it
    # back on, and the only way out was pulling the Pi's power. So during opening
    # hours the output being off is simply corrected, whatever put it there.
    # "missing" here is the interesting one: the compositor has stopped listing
    # the output, which powering it on cannot fix and a reboot can.
    state=$(panel_state)
    if [ "$state" != "$last_state" ]; then
      log "output is ${state:-missing} (browser up: $(running && echo yes || echo no))"
      last_state=$state
    fi
    [ "$state" = off ] && panel on

    if ! running; then
      log "starting the browser"
      panel on
      # The extension only matches youtube.com, so it does nothing while URL
      # points at the local player — it's kept for the streaming setup above.
      # Two halves of the same fix. --load-extension gets YouTube to send H.264
      # (see h264-only/), and --enable-features points Chromium at the V4L2
      # decoder that can handle it in hardware. This Pi 4 has that decoder sitting
      # on /dev/video10 and was ignoring it, grinding every frame on one core
      # instead. Neither half is any use without the other: the decoder does
      # H.264 and nothing else, so it stays idle while YouTube sends VP9.
      #
      # To check it took, with the display up:  sudo fuser -v /dev/video10
      # Chromium in that list means the decoder is doing the work.
      "$BROWSER" \
        --user-data-dir="$PROFILE" \
        --load-extension="$EXT" --disable-extensions-except="$EXT" \
        --enable-features=AcceleratedVideoDecodeLinuxV4L2,AcceleratedVideoDecodeLinuxGL \
        --ignore-gpu-blocklist \
        --kiosk --app="$URL" \
        --autoplay-policy=no-user-gesture-required \
        --noerrdialogs --disable-infobars --disable-session-crashed-bubble \
        --disable-features=Translate --password-store=basic \
        --check-for-update-interval=31536000 &
    fi
  elif running; then
    # Only on the pass where it was still up, so a panel someone switches back
    # on out of hours for something else is left alone.
    log "closing time, stopping the browser"
    pkill -f "user-data-dir=$PROFILE"
    sleep 2
    panel off
  fi

  sleep "$POLL"
done
