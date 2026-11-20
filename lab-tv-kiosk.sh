#!/bin/bash
# Lab TV kiosk supervisor.
#
# Holds the display up between ON_HOUR and OFF_HOUR Madrid time and leaves the
# panel asleep the rest of the day. It is also the whole crash recovery story:
# if Chromium dies during opening hours the next pass round the loop starts it
# again, and nothing outside this file needs to know the schedule. A Chromium
# that is up but whose page never loaded (plain white, 2026-11-20) is caught by
# a heartbeat: the page requests playlist.js?hb=... every minute, the server
# logs it to http.log, and silence past HB_GRACE + HB_STALE gets the browser
# restarted, at most HB_MAX_RESTARTS times an hour. With HB_ENFORCE=0 it only
# logs what it would have done.
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

# Heartbeat watchdog, all in seconds. The page checks in once a minute.
HB_ENFORCE=0              # 0: only log "would restart". 1: actually restart.
HB_STALE=300              # this long without a heartbeat and the page is dead
HB_GRACE=180              # after every Chromium start, before HB_STALE counts.
                          # A cold start right after boot took 51 s to its first
                          # renderer on 2026-11-20; 3 min is that with room to spare.
HB_MAX_RESTARTS=3         # heartbeat restarts allowed per HB_WINDOW, then it
HB_WINDOW=3600            # logs loudly and leaves the browser alone until one ages out
HTTP_LOG_MAX=262144       # bytes; past this http.log is cut to its last
HTTP_LOG_KEEP=500         # this many lines (a day of heartbeats is ~100 KB)

OUTPUT=HDMI-A-1           # `wlr-randr` with no arguments lists the output names

HERE="$(cd "$(dirname "$0")" && pwd)"
EXT="$HERE/h264-only"
PROFILE="$HOME/.config/labtv-kiosk"   # also how we recognise our own Chromium
LOG="$HERE/kiosk.log"
BROWSER_LOG="$HERE/chromium.log"    # last launch only, whether it lived or not
HTTP_LOG="$HERE/http.log"           # the server's request log, heartbeats included
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
serving() { pgrep -f "lab-tv-http $PORT" >/dev/null; }

# The folder's web server: Python's http.server plus two things it lacks.
# Cache-Control: no-cache, because without it Chromium judged a file unchanged
# for weeks to be fresh and kept serving its own copy of local-display.html
# without asking (2026-11-20: a deployed page edit never reached the screen).
# Every load now revalidates, which costs a 304 when nothing changed. And
# single byte ranges (206), which it ignores, sending the whole file to a
# seek instead. Requests are logged to stderr, which goes to http.log.
SERVER_PY=$(cat <<'EOF'
import functools, http.server, os, sys

class Handler(http.server.SimpleHTTPRequestHandler):
    left = None   # bytes still to send for a range response

    def end_headers(self):
        self.send_header('Cache-Control', 'no-cache')
        self.send_header('Accept-Ranges', 'bytes')
        super().end_headers()

    def send_head(self):
        rng = self.headers.get('Range', '')
        path = self.translate_path(self.path)
        if not rng.startswith('bytes=') or ',' in rng or not os.path.isfile(path):
            return super().send_head()
        size = os.path.getsize(path)
        first, _, last = rng[6:].partition('-')
        try:
            if first:
                start, end = int(first), min(int(last) if last else size - 1, size - 1)
            else:
                start, end = max(size - int(last), 0), size - 1
        except ValueError:
            return super().send_head()
        if start > end:
            self.send_response(416)
            self.send_header('Content-Range', f'bytes */{size}')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return None
        f = open(path, 'rb')
        f.seek(start)
        self.send_response(206)
        self.send_header('Content-Type', self.guess_type(path))
        self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
        self.send_header('Content-Length', str(end - start + 1))
        self.send_header('Last-Modified', self.date_time_string(int(os.path.getmtime(path))))
        self.end_headers()
        self.left = end - start + 1
        return f

    def copyfile(self, src, dst):
        if self.left is None:
            return super().copyfile(src, dst)
        left, self.left = self.left, None
        while left > 0:
            buf = src.read(min(64 * 1024, left))
            if not buf:
                break
            dst.write(buf)
            left -= len(buf)

port, folder = int(sys.argv[2]), sys.argv[3]
http.server.ThreadingHTTPServer(
    ('127.0.0.1', port), functools.partial(Handler, directory=folder)).serve_forever()
EOF
)

# Seconds on a clock that only goes forward. The Pi has no RTC, so the wall
# clock can jump minutes when NTP first syncs after boot, which would read as a
# stale heartbeat. /proc/uptime doesn't jump; date is only the fallback off Linux.
now() {
  local up
  if [ -r /proc/uptime ]; then read -r up _ < /proc/uptime; echo "${up%.*}"
  else date +%s; fi
}

heartbeats() {
  local n
  n=$(grep -cF '?hb=' "$HTTP_LOG" 2>/dev/null)
  echo "${n:-0}"
}

# Kept bounded here rather than by logrotate (no root). Rewritten in place, not
# replaced: http.server holds it open for appending and carries on at the new end.
trim_http_log() {
  local kept
  [ -f "$HTTP_LOG" ] || return 0
  [ $(( $(wc -c < "$HTTP_LOG") )) -gt "$HTTP_LOG_MAX" ] || return 0
  kept=$(tail -n "$HTTP_LOG_KEEP" "$HTTP_LOG")
  printf '%s\n' "$kept" > "$HTTP_LOG"
  hb_seen=$(heartbeats)   # counting starts again from what was kept
}

# Called each pass while the browser is up in opening hours. Restarts it the
# same way a person would when the page has gone quiet, but never more than
# HB_MAX_RESTARTS times in HB_WINDOW: a page that dies again straight after each
# restart has a cause a restart won't fix, and looping on it helps nobody.
heartbeat_check() {
  local t n r recent="" count=0 mode=""
  [ "$HB_ENFORCE" = 1 ] || mode=" (log-only)"
  t=$(now)
  n=$(heartbeats)
  [ "$n" -gt "$hb_seen" ] && hb_last=$t
  hb_seen=$n

  for r in $hb_restarts; do
    [ $((t - r)) -lt "$HB_WINDOW" ] && { recent="$recent $r"; count=$((count + 1)); }
  done
  hb_restarts=$recent
  if [ "$hb_capped" = yes ] && [ "$count" -lt "$HB_MAX_RESTARTS" ]; then
    log "heartbeat watchdog$mode: back under $HB_MAX_RESTARTS restarts an hour, restarting again if needed"
    hb_capped=no
  fi

  [ $((t - hb_last)) -gt "$HB_STALE" ] || return 0

  if [ "$count" -ge "$HB_MAX_RESTARTS" ]; then
    if [ "$hb_capped" = no ]; then
      log "!!! HEARTBEAT WATCHDOG$mode GAVE UP: no heartbeat for $((t - hb_last))s after $count restarts in the last $((HB_WINDOW / 60)) min. Leaving the browser alone until one ages out. See chromium.log and http.log."
      hb_capped=yes
    fi
    return 0
  fi

  hb_restarts="$hb_restarts $t"
  if [ "$HB_ENFORCE" = 1 ]; then
    log "no heartbeat from the page for $((t - hb_last))s, restarting the browser ($((count + 1)) of $HB_MAX_RESTARTS this hour)"
    pkill -f "user-data-dir=$PROFILE"
    sleep 2
  else
    # Counted, capped and timed exactly like a real restart, grace included, so a
    # day of log-only lines is what enforce mode would have done.
    log "heartbeat watchdog (log-only): would restart the browser, no heartbeat for $((t - hb_last))s ($((count + 1)) of $HB_MAX_RESTARTS this hour)"
    hb_last=$(( t + HB_GRACE ))
  fi
}

log "supervisor started (display hours ${ON_HOUR}-${OFF_HOUR} $ZONE)"
last_state=init   # never a real state, so the first pass always logs
dmesg_seen=$(dmesg 2>/dev/null | wc -l)

# A server left over from an earlier supervisor may be the old plain
# http.server logging to /dev/null, which caches badly and from which the
# watchdog would hear no heartbeats at all. Start our own.
pkill -f "http.server $PORT"
pkill -f "lab-tv-http $PORT"
hb_seen=$(heartbeats)
hb_last=$(( $(now) + HB_GRACE ))   # a browser already up when we start gets the grace too
hb_restarts=""
hb_capped=no

while :; do
  kernel_lines
  trim_http_log

  # local-display.html has to arrive over HTTP rather than as a file:// URL:
  # Chromium refuses to load subtitle tracks off the filesystem. Bound to
  # localhost so this isn't serving the folder to the network.
  if ! serving; then
    python3 -c "$SERVER_PY" lab-tv-http "$PORT" "$HERE" >/dev/null 2>>"$HTTP_LOG" &
  fi

  hour=$(TZ="$ZONE" date +%-H)

  if [ "$hour" -ge "$ON_HOUR" ] && [ "$hour" -lt "$OFF_HOUR" ]; then
    # Waking the panel used to be tied to starting the browser, which left one
    # way for the display to stay dark all day: any path that ends with the
    # output powered down while Chromium is still up had nothing left to turn it
    # back on, and the only way out was pulling the Pi's power. So during opening
    # hours the output being off is simply corrected, whatever put it there.
    # "missing" here is the interesting one: the compositor has stopped listing
    # the output, which powering it on cannot fix and a reboot can. The Samsung
    # drops hotplug in standby, which did exactly that 9-12 Nov 2026: dark for
    # four days. Prevented by forcing the connector on in the kernel command line:
    #   sudo sed -i.bak '1 s/$/ video=HDMI-A-1:3840x2160@30D/' /boot/firmware/cmdline.txt
    # then reboot. Re-apply that after any fresh OS install.
    state=$(panel_state)
    if [ "$state" != "$last_state" ]; then
      log "output is ${state:-missing} (browser up: $(running && echo yes || echo no))"
      # An output that drops off and comes back under a running Chromium leaves
      # it painting nothing: the panel shows plain white until the browser is
      # restarted (2026-11-03). Killing it here lets the check below relaunch.
      if [ "$state" = on ] && [ "$last_state" != init ] && running; then
        log "output came back, restarting the browser so it repaints"
        pkill -f "user-data-dir=$PROFILE"
        sleep 2
      fi
      last_state=$state
    fi
    [ "$state" = off ] && panel on

    running && heartbeat_check

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
      # --ozone-platform is not optional here even though Chromium usually works
      # it out: it only does so from a full desktop session's environment, and a
      # supervisor started over SSH, or by anything that does not set
      # XDG_SESSION_TYPE, does not have one. Without the flag Chromium picks X11,
      # finds no X server, and exits before it has drawn anything — which looks
      # from the sofa exactly like a dead display, and is not something the
      # panel's own state can tell you.
      "$BROWSER" \
        --ozone-platform=wayland \
        --user-data-dir="$PROFILE" \
        --load-extension="$EXT" --disable-extensions-except="$EXT" \
        --enable-features=AcceleratedVideoDecodeLinuxV4L2,AcceleratedVideoDecodeLinuxGL \
        --ignore-gpu-blocklist \
        --kiosk --app="$URL" \
        --autoplay-policy=no-user-gesture-required \
        --noerrdialogs --disable-infobars --disable-session-crashed-bubble \
        --disable-features=Translate --password-store=basic \
        --check-for-update-interval=31536000 > "$BROWSER_LOG" 2>&1 &
      hb_last=$(( $(now) + HB_GRACE ))   # HB_STALE counts from the end of the grace

      # A browser that refuses to start says why on the way out, and this is the
      # only chance to catch it: without this the log fills with hundreds of
      # identical "starting the browser" lines and not one word of the reason.
      sleep 5
      running || log "browser exited immediately -- $(tail -2 "$BROWSER_LOG" | tr '\n' ' ' | tail -c 300)"
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
