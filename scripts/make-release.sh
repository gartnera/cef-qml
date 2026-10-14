#!/bin/sh
# Usage: scripts/make-release.sh <builddir> <outdir>
#
# Builds the relocatable prebuilt tarball
#   <outdir>/cef-qml-<version>-linux-x86_64.tar.gz (+ .sha256)
# from a build directory configured with a "/" prefix:
#
#   meson setup <builddir> --prefix=/ --libdir=lib \
#     -Dqml_dir=qml -Druntime_dir=lib/cef-qml
#
# Layout of the tarball (QML_IMPORT_PATH=<extracted>/cef-qml/qml is all a user
# needs; the plugin finds libcef.so through RUNPATH $ORIGIN/../../lib/cef-qml):
#
#   cef-qml/qml/CefQml/                 plugin, qmldir, Components/
#   cef-qml/lib/cef-qml/                libcef.so, resources, locales/, helper
#   cef-qml/share/cef-qml/examples/     reference browser
#   cef-qml/README.md, BUILDINFO, LICENSES/
#
# VERSION overrides the version in the file name (default: the meson project
# version). STRIP overrides the strip program.
set -eu
[ $# -eq 2 ] || { echo "usage: $0 <builddir> <outdir>" >&2; exit 2; }
builddir=$(cd "$1" && pwd)
mkdir -p "$2"; outdir=$(cd "$2" && pwd)
src=$(cd "$(dirname "$0")/.." && pwd)
strip=${STRIP:-strip}

version=${VERSION:-$(meson introspect "$builddir" --projectinfo |
  python3 -c 'import json, sys; print(json.load(sys.stdin)["version"])')}
name=cef-qml-$version-linux-x86_64

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT INT TERM
root=$stage/cef-qml

meson compile -C "$builddir"
meson install -C "$builddir" --no-rebuild --strip --destdir "$root" >"$stage/install.log" ||
  { cat "$stage/install.log" >&2; exit 1; }

plugin=$root/qml/CefQml/libcefqmlplugin.so
runtime=$root/lib/cef-qml
for f in "$plugin" "$root/qml/CefQml/qmldir" "$root/qml/CefQml/Components/qmldir" \
         "$runtime/libcef.so" "$runtime/cef-qml-helper" "$runtime/icudtl.dat" \
         "$runtime/locales/en-US.pak"; do
  [ -e "$f" ] || {
    echo "missing $f: configure <builddir> with --prefix=/ --libdir=lib" \
      "-Dqml_dir=qml -Druntime_dir=lib/cef-qml" >&2
    find "$root" -maxdepth 3 >&2; exit 1; }
done
runpath=$(readelf -d "$plugin" | sed -n 's/.*(RUNPATH).*\[\(.*\)\]/\1/p')
[ "$runpath" = '$ORIGIN/../../lib/cef-qml' ] ||
  { echo "unexpected plugin RUNPATH '$runpath' (not relocatable)" >&2; exit 1; }

# Meson only strips what it built; the CEF distribution ships libcef.so with
# full debug info (~1.4 GB, ~270 MB stripped).
for f in "$runtime"/libcef.so "$runtime"/libvk_swiftshader.so "$runtime"/libvulkan.so.1; do
  "$strip" --strip-unneeded "$f"
done

cefdir=$src/subprojects/$(sed -n 's/^directory *= *//p' "$src/subprojects/cef.wrap")
mkdir -p "$root/LICENSES"
cp "$src/README.md" "$root/"
cp "$cefdir/LICENSE.txt" "$root/LICENSES/CEF-LICENSE.txt"
cp "$cefdir/README.txt" "$root/LICENSES/CEF-README.txt"
# Licenses of Chromium and its third-party components.
cp "$cefdir/CREDITS.html" "$root/LICENSES/CHROMIUM-CREDITS.html"

commit=$(git -C "$src" rev-parse HEAD 2>/dev/null || echo unknown)
qtver=$(qtpaths6 --qt-version 2>/dev/null || qtpaths --qt-version 2>/dev/null || echo unknown)
{
  echo "cef-qml $version ($commit)"
  sed -n 's/^CEF Version: *//p' "$cefdir/README.txt" | sed 's/^/CEF /'
  echo "built against Qt $qtver"
  sed -n 's/^PRETTY_NAME="\(.*\)"/built on \1/p' /etc/os-release 2>/dev/null || true
  echo
  echo "Usage: QML_IMPORT_PATH=<this directory>/qml, then 'import CefQml'."
  echo "Example: QML_IMPORT_PATH=\$PWD/qml qml share/cef-qml/examples/browser/main.qml"
} >"$root/BUILDINFO"

tar -C "$stage" --owner=0 --group=0 --numeric-owner --sort=name \
  -cf - cef-qml | gzip -9 >"$outdir/$name.tar.gz"
(cd "$outdir" && sha256sum "$name.tar.gz" >"$name.tar.gz.sha256")
echo "$outdir/$name.tar.gz ($(du -h "$outdir/$name.tar.gz" | cut -f1)," \
  "unpacked $(du -sh "$root" | cut -f1))"
