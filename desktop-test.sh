#!/usr/bin/env bash
#
# The window itself, an application started from a shell, one started from the palette, and a
# browser in a frame.
#
#   ./desktop-test.sh [out-dir]
#
# The machine has no keyboard this side can type on - an ARM guest has no PS/2 keyboard for
# `VBoxManage controlvm keyboardputscancode` - so the typing is done inside it, by xdotool
# against the running X session, and the looking is done out here, by screenshot.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-$HERE/.cache/desktop-test}"
mkdir -p "$OUT"

on_the_machine() {
    "$HERE/vm.sh" ssh "DISPLAY=:0 $*"
}

shot() {
    sleep "${2:-3}"
    "$HERE/vm.sh" shot "$OUT/$1.png" >/dev/null
    echo "  $OUT/$1.png"
}

echo "=== is the desktop up?"
on_the_machine 'xdotool search --class moonreview' >/dev/null \
    || { echo "moon has no window on :0 - see ~/.local/state/moon-desktop.log" >&2; exit 1; }
shot 01-desktop 1

echo "=== xeyes, started from a shell of the machine"
on_the_machine 'xeyes >/dev/null 2>&1 &' || true
shot 02-xeyes

echo "=== the applications extension, from the palette"
# COMMAND is ctrl here, so the palette is ctrl+shift+p; then its name, and Enter.
on_the_machine 'xdotool key --clearmodifiers ctrl+shift+p'
sleep 1
on_the_machine 'xdotool type --delay 40 applications'
sleep 1
on_the_machine 'xdotool key --clearmodifiers Return'
shot 03-applications

echo "=== the first application of the list, started from it"
on_the_machine 'xdotool key --clearmodifiers Return'
shot 04-started

echo "=== chromium"
on_the_machine 'chromium --no-first-run --no-default-browser-check about:blank >/dev/null 2>&1 &' || true
shot 05-chromium 15

echo
echo "the pictures are in $OUT"
