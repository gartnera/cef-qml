#!/bin/sh
# Usage: tests/run.sh <builddir> <offscreen|wayland> [qmltestrunner args...]
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
    unset DISPLAY
    ;;
  *) echo "unknown mode $mode" >&2; exit 2 ;;
esac

set +e
${TEST_WRAPPER:-} "$runner" -input "$here/tst_webview.qml" "$@" >"$tmp/out.log" 2>&1
status=$?
cat "$tmp/out.log"
set -e
# Some QtWayland builds (seen with Qt 6.4) segfault while tearing down a
# focused text-input item, with or without this plugin. Accept that only if
# every test already reported success.
if [ "$status" -ne 0 ] && [ "$mode" = wayland ] &&
   grep -q '^PASS   : .*::cleanupTestCase()' "$tmp/out.log" &&
   ! grep -q '^FAIL!' "$tmp/out.log"; then
  echo "note: ignoring exit status $status after all tests passed (QtWayland teardown crash)" >&2
  status=0
fi
exit "$status"
