#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd "$ROOT_DIR"
meson setup build --reconfigure >/dev/null
meson compile -C build

if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
  echo "Build finished. GUI launch skipped: no display server detected (DISPLAY/WAYLAND_DISPLAY is unset)."
  exit 0
fi

if [[ -n "${DISPLAY:-}" ]] && command -v xset >/dev/null 2>&1; then
  if ! xset q >/dev/null 2>&1; then
    echo "Build finished. GUI launch skipped: X11 display '$DISPLAY' is not accessible in this shell."
    exit 0
  fi
fi

if [[ -n "${WAYLAND_DISPLAY:-}" ]] && [[ ! -S "/run/user/$(id -u)/${WAYLAND_DISPLAY}" ]]; then
  echo "Build finished. GUI launch skipped: WAYLAND_DISPLAY '$WAYLAND_DISPLAY' socket is not available."
  exit 0
fi

"$ROOT_DIR/build/omanager"
