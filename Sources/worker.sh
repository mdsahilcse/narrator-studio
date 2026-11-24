#!/bin/bash
set -eu
resources="$(cd "$(dirname "$0")" && pwd)"
support="$HOME/Library/Application Support/Narrator Studio"
runtime="$support/Engine/$(cat "$resources/runtime-version")"
if [[ ! -x "$runtime/bin/python3.11" ]]; then
    echo 'STUDIO {"message":"Unpacking the offline engine for first use…"}'
    mkdir -p "$support/Engine"
    scratch="$(mktemp -d "$support/Engine/.unpack.XXXXXXXX")"
    trap 'rm -rf "$scratch"' EXIT
    /usr/bin/tar -xf "$resources/runtime.tar.gz" -C "$scratch"
    # A rename exposes the complete runtime atomically, including under concurrent launches.
    /usr/bin/perl -e 'rename($ARGV[0],$ARGV[1]) or exit(! -x "$ARGV[1]/bin/python3.11")' "$scratch/python" "$runtime"
    rm -rf -- "$scratch"
    trap - EXIT
fi
export NARRATOR_RESOURCES="$resources"
export PYTHONDONTWRITEBYTECODE=1
export OMP_NUM_THREADS=2
export OPENBLAS_NUM_THREADS=1
exec "$runtime/bin/python3.11" -IBu "$resources/studio.py" "$1"
