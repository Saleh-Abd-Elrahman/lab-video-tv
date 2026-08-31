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
#   chmod +x ~/lab-tv/lab-tv-kiosk.sh ~/lab-tv/fetch-playlist.sh
#   ~/lab-tv/fetch-playlist.sh                             # fills ~/lab-tv/videos
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

# The panel doesn't speak CEC — a topology scan finds nothing at all on the bus
# except this box — so it gets put to sleep by powering the Wayland output down
# and letting the panel drop into standby on its own once the signal stops.
#
# This is only ever called with no browser running, so nothing has a window to
# lose track of while the output is away. Best effort either way: without one of
# these tools the display still keeps its hours, it just shows the panel's own
# no-signal screen overnight instead of going dark.
#
# The environment is set so this works the same when run by hand over SSH, where
# neither variable is inherited from the desktop session.
panel() {
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
  if command -v wlopm >/dev/null; then
    wlopm "--$1" "$OUTPUT"
  elif command -v wlr-randr >/dev/null; then
    wlr-randr --output "$OUTPUT" "--$1"
  fi >/dev/null 2>&1
}

running() { pgrep -f "user-data-dir=$PROFILE" >/dev/null; }
serving() { pgrep -f "http.server $PORT" >/dev/null; }

while :; do
  # local-display.html has to arrive over HTTP rather than as a file:// URL:
  # Chromium refuses to load subtitle tracks off the filesystem. Bound to
  # localhost so this isn't serving the folder to the network.
  if ! serving; then
    python3 -m http.server "$PORT" --directory "$HERE" --bind 127.0.0.1 \
      >/dev/null 2>&1 &
  fi

  hour=$(TZ="$ZONE" date +%-H)

  if [ "$hour" -ge "$ON_HOUR" ] && [ "$hour" -lt "$OFF_HOUR" ]; then
    if ! running; then
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
    pkill -f "user-data-dir=$PROFILE"
    sleep 2
    panel off
  fi

  sleep "$POLL"
done
