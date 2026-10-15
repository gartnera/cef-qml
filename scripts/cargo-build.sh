#!/bin/sh
# Builds libservo_qml.so (servo/) with cargo for the ServoQml module.
# Usage: scripts/cargo-build.sh <Cargo.toml> <cargo target dir> <output .so>
# The output is only replaced when the library changed, so a no-op cargo
# build does not relink the plugin.
set -eu
cargo=${CARGO:-cargo}
"$cargo" build --release --locked --manifest-path "$1" --target-dir "$2"
if ! cmp -s "$2/release/libservo_qml.so" "$3"; then
  cp -f "$2/release/libservo_qml.so" "$3"
fi
