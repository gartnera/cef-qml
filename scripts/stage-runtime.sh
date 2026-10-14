#!/bin/sh
# Usage: stage-runtime.sh <cef Release dir> <cef Resources dir> <out dir> <stamp>
# Hard-links (or copies) the CEF runtime into the build tree. Symlinks are not
# used because Chromium resolves its data files relative to the real path of
# libcef.so.
set -eu
release=$1 resources=$2 out=$3 stamp=$4
mkdir -p "$out"
for f in libcef.so libvk_swiftshader.so libvulkan.so.1 v8_context_snapshot.bin vk_swiftshader_icd.json; do
  ln -f "$release/$f" "$out/$f" 2>/dev/null || cp -f "$release/$f" "$out/$f"
done
cp -rlf "$resources/." "$out/" 2>/dev/null || cp -rf "$resources/." "$out/"
touch "$stamp"
