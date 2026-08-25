#!/bin/bash
# Lab TV kiosk supervisor.
#
# Holds the display up between ON_HOUR and OFF_HOUR Madrid time and leaves the
# panel asleep the rest of the day. It is also the whole crash recovery story:
# if Chromium dies during opening hours the next pass round the loop starts it
# again, and nothing outside this file needs to know the schedule.
#
# INSTALL (on the Pi)
#   sudo apt install v4l-utils                  # cec-ctl, to switch the panel
#   mkdir -p ~/lab-tv
#   cp -r lab-tv-kiosk.sh h264-only ~/lab-tv/
#   chmod +x ~/lab-tv/lab-tv-kiosk.sh
#   cp lab-tv-kiosk.desktop ~/.config/autostart/
#   reboot

set -u

URL=https://lab-video-tv.vercel.app
ON_HOUR=8                 # first hour of the day the display is up
OFF_HOUR=22               # first hour it is down
ZONE=Europe/Madrid        # by name, not by offset, so the clocks change on their own
POLL=30                   # seconds between checks

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

# Best effort: the display still works without CEC, it just can't put the panel
# to sleep, so a missing cec-ctl is not worth failing over.
panel() {
  command -v cec-ctl >/dev/null || return 0
  case "$1" in
    on)  cec-ctl -d/dev/cec0 --playback --to 0 --image-view-on ;;
    off) cec-ctl -d/dev/cec0 --playback --to 0 --standby ;;
  esac >/dev/null 2>&1
}

running() { pgrep -f "user-data-dir=$PROFILE" >/dev/null; }

while :; do
  hour=$(TZ="$ZONE" date +%-H)

  if [ "$hour" -ge "$ON_HOUR" ] && [ "$hour" -lt "$OFF_HOUR" ]; then
    if ! running; then
      panel on
      # --load-extension is what keeps 1080p affordable: see h264-only/.
      "$BROWSER" \
        --user-data-dir="$PROFILE" \
        --load-extension="$EXT" --disable-extensions-except="$EXT" \
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
