#!/bin/sh
# Usage: scripts/verify-release.sh <tarball> [workdir]
#
# Checks a tarball made by make-release.sh in isolation: extracts it into a
# fresh directory, checks that the plugin and the helper resolve libcef.so
# inside the extracted tree, then runs the offscreen test suites and the CDP
# remote-control test with QML_IMPORT_PATH pointing only into that tree.
# Move the build directory and subprojects/cef_binary_* out of the way first
# to prove nothing still depends on them.
set -eu
[ $# -ge 1 ] || { echo "usage: $0 <tarball> [workdir]" >&2; exit 2; }
tarball=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
src=$(cd "$(dirname "$0")/.." && pwd)
if [ $# -ge 2 ]; then
  work=$2; mkdir -p "$work"; work=$(cd "$work" && pwd)
else
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT INT TERM
fi

tar -C "$work" -xzf "$tarball"
root=$work/cef-qml
qml=$root/qml
plugin=$qml/CefQml/libcefqmlplugin.so
helper=$root/lib/cef-qml/cef-qml-helper

fail() { echo "verify-release: $*" >&2; exit 1; }
for f in "$plugin" "$helper" "$qml/CefQml/qmldir" "$qml/CefQml/Components/qmldir" \
         "$root/share/cef-qml/examples/browser/main.qml" "$root/LICENSES/CEF-LICENSE.txt"; do
  [ -e "$f" ] || fail "missing $f"
done

# libcef.so must come from the extracted tree, and nothing may be missing.
for f in "$plugin" "$helper"; do
  out=$(env -u LD_LIBRARY_PATH ldd "$f")
  echo "$out" | grep -q "not found" && { echo "$out" >&2; fail "unresolved libraries in $f"; }
  cef=$(echo "$out" | sed -n 's/^[[:space:]]*libcef\.so => \([^ ]*\) .*/\1/p')
  [ "$(realpath "$cef")" = "$(realpath "$root/lib/cef-qml/libcef.so")" ] ||
    fail "$f resolves libcef.so to '$cef'"
done
echo "verify-release: libraries resolve inside $root"

# Run from an unrelated directory with only the extracted tree importable.
cd "$work"
unset QML_IMPORT_PATH LD_LIBRARY_PATH CEF_QML_RUNTIME_DIR
"$src/tests/run.sh" "$qml" offscreen
python3 "$src/tests/cdp_remote.py" "$qml" "$root/share/cef-qml/examples/browser/main.qml"
echo "verify-release: OK ($tarball)"
