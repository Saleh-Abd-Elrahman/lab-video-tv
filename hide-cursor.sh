#!/bin/bash
# Make the mouse pointer invisible on the Pi. Run once, per user account.
#
# The panel is a display, not a workstation: nothing should ever be pointed at.
# But the pointer sits wherever it was left — usually near the top left corner,
# over the video — and stays there. CSS `cursor: none` in display.css does not
# help: labwc draws the pointer itself, and only hands the client the chance to
# restyle it once the mouse actually moves. On a box with no mouse attached that
# moment never comes.
#
# So the cursor is made invisible at its source: a cursor theme whose every
# shape is one transparent pixel. labwc renders it, it just has nothing to show,
# and Chromium picks the same theme up out of the environment for the cursors it
# draws itself. No packages, no root, and nothing running in the background.
#
#   ./hide-cursor.sh      # then log out and back in, or reboot
#
# To undo: delete ~/.local/share/icons/blank, and drop the XCURSOR_THEME line
# from ~/.config/labwc/environment.

set -eu

THEME="$HOME/.local/share/icons/blank"
ENVFILE="$HOME/.config/labwc/environment"
RC="$HOME/.config/labwc/rc.xml"

mkdir -p "$THEME/cursors"
cat > "$THEME/index.theme" <<'EOF'
[Icon Theme]
Name=blank
Comment=A cursor theme that draws nothing
EOF

# One Xcursor file holding a 1x1 fully transparent image at each of the sizes a
# theme is normally asked for. The format is a header, a table of contents and
# one chunk per image; writing it by hand beats pulling in xcursorgen, which
# Debian no longer ships.
python3 - "$THEME/cursors/default" <<'EOF'
import struct, sys

SIZES = (24, 32, 48, 64, 96)
IMAGE = 0xfffd0002

toc, chunks = b"", b""
pos = 16 + 12 * len(SIZES)          # header, then one TOC entry per image
for size in SIZES:
    toc += struct.pack("<III", IMAGE, size, pos)
    # chunk header is 36 bytes: the common 16 plus width/height/hotspot/delay,
    # followed by the pixels themselves as ARGB. Ours is a single clear pixel.
    chunk = struct.pack("<IIIIIIIII", 36, IMAGE, size, 1, 1, 1, 0, 0, 0)
    chunk += struct.pack("<I", 0)
    chunks += chunk
    pos += len(chunk)

with open(sys.argv[1], "wb") as f:
    f.write(b"Xcur" + struct.pack("<III", 16, 0x00010000, len(SIZES)))
    f.write(toc + chunks)
EOF

# Every shape by name, so nothing falls back to the theme we are hiding: a text
# caret or a resize arrow is just as visible as the pointer. Adwaita is the stock
# theme here and names them all.
for name in $(ls /usr/share/icons/Adwaita/cursors 2>/dev/null); do
  [ "$name" = default ] || ln -sf default "$THEME/cursors/$name"
done

# labwc reads this file at startup and passes it on to everything it launches,
# which is how Chromium ends up using the same empty theme.
mkdir -p "$(dirname "$ENVFILE")"
touch "$ENVFILE"
grep -q '^XCURSOR_THEME=' "$ENVFILE" || printf 'XCURSOR_THEME=blank\n' >> "$ENVFILE"

# The same theme named in rc.xml, which labwc re-reads on demand — that is what
# lets the change land on a screen that is already up, without logging out.
if ! grep -q '<cursor name="blank"' "$RC"; then
  sed -i 's|</labwc_config>|    <theme>\n        <cursor name="blank" size="24" />\n    </theme>\n</labwc_config>|' "$RC"
fi
labwc --reconfigure 2>/dev/null || true

# unclutter is the X11 answer to this and does nothing under Wayland — it exits
# on startup every boot. Take it out rather than leave it looking like the fix.
rm -f "$HOME/.config/autostart/unclutter.desktop"

echo "hide-cursor: theme written to $THEME — log out and back in to pick it up"
