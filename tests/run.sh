#!/bin/sh
# Usage: tests/run.sh <builddir> <offscreen|wayland> [qmltestrunner args...]
# TEST_INPUT selects a test file or directory (default: all tst_*.qml).
#
# offscreen: Qt offscreen platform, Chromium ozone "headless".
# wayland:   starts a private headless Weston compositor and runs the tests as
#            a real Wayland client (Qt wayland + Chromium ozone "wayland").
set -eu
builddir=$(cd "$1" && pwd); mode=$2; shift 2
here=$(cd "$(dirname "$0")" && pwd)

runner=${QMLTESTRUNNER:-}
if [ -z "$runner" ]; then
  for c in qmltestrunner6 qmltestrunner-qt6 /usr/lib/qt6/bin/qmltestrunner /usr/lib64/qt6/bin/qmltestrunner qmltestrunner; do
    if command -v "$c" >/dev/null 2>&1; then runner=$c; break; fi
  done
fi
[ -n "$runner" ] || { echo "qmltestrunner not found" >&2; exit 77; }

export QML_IMPORT_PATH="$builddir${QML_IMPORT_PATH:+:$QML_IMPORT_PATH}"
# Isolated browser profile per run.
tmp=$(mktemp -d)
trap 'kill $weston_pid 2>/dev/null || true; rm -rf "$tmp"' EXIT INT TERM
weston_pid=
export CEF_QML_CACHE_DIR="$tmp/profile"
# tst_hotreload writes QML files here through XMLHttpRequest.
export QML_XHR_ALLOW_FILE_WRITE=1 QML_XHR_ALLOW_FILE_READ=1
rm -rf "$builddir/test-hotreload"; mkdir -p "$builddir/test-hotreload"

case $mode in
  offscreen)
    export QT_QPA_PLATFORM=offscreen
    ;;
  wayland)
    command -v weston >/dev/null 2>&1 || { echo "weston not found" >&2; exit 77; }
    export XDG_RUNTIME_DIR="$tmp/xdg"
    mkdir -m 700 "$XDG_RUNTIME_DIR"
    weston --backend=headless --socket=cefqml-test --width=1280 --height=800 \
      --idle-time=0 >"$tmp/weston.log" 2>&1 &
    weston_pid=$!
    i=0
    while [ ! -S "$XDG_RUNTIME_DIR/cefqml-test" ]; do
      i=$((i + 1))
      if [ $i -gt 100 ] || ! kill -0 $weston_pid 2>/dev/null; then
        echo "weston failed to start:" >&2; cat "$tmp/weston.log" >&2; exit 1
      fi
      sleep 0.1
    done
    export WAYLAND_DISPLAY=cefqml-test
    export QT_QPA_PLATFORM=wayland
    # Qt 6.4's QtWayland dereferences a missing text-input device when the
    # compositor (headless weston) offers no text-input protocol; any
    # TextInput then crashes. The compose input context sidesteps it.
    export QT_IM_MODULE=${QT_IM_MODULE:-compose}
    unset DISPLAY
    # QtWayland < 6.5.1 frees the wl_display before destroying its frame
    # event queue (~QWaylandDisplay: wl_display_disconnect, then
    # wl_event_queue_destroy, which locks the freed display's mutex; fixed
    # upstream by qtwayland a76bf824 "Destroy frame queue before display").
    # The stale mutex is harmless with plain glibc malloc, but meson sets
    # MALLOC_PERTURB_, which fills freed memory with a random byte: then any
    # Qt Wayland client (with or without CefQml) hangs or aborts in
    # pthread_mutex_lock after its last test has passed. Do not perturb the
    # Wayland client on affected Qt versions; the offscreen suite keeps it.
    qtver=$(qtpaths6 --qt-version 2>/dev/null || qtpaths --qt-version 2>/dev/null || echo 0)
    if [ "$(printf '%s\n' 6.5.1 "$qtver" | sort -V | head -n1)" != 6.5.1 ]; then
      unset MALLOC_PERTURB_
    fi
    ;;
  *) echo "unknown mode $mode" >&2; exit 2 ;;
esac

set +e
${TEST_WRAPPER:-} "$runner" -input "${TEST_INPUT:-$here}" "$@" >"$tmp/out.log" 2>&1
status=$?
cat "$tmp/out.log"
set -e
exit "$status"
