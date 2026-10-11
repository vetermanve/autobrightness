#!/bin/bash
# Installs autobrightness into ~/.local (no sudo, nothing outside your home).
set -eu
SRC="$(cd "$(dirname "$0")" && pwd)"
BIN="$HOME/.local/bin"
LIBEXEC="$HOME/.local/libexec"

command -v m1ddc >/dev/null || { echo "m1ddc is required: brew install m1ddc"; exit 1; }
command -v swiftc >/dev/null || { echo "swiftc is required: install Xcode command line tools"; exit 1; }

mkdir -p "$BIN" "$LIBEXEC"

echo "compiling helpers"
swiftc -O -o "$LIBEXEC/autobrightness-builtin-brightness" "$SRC/src/builtin-brightness.swift"
swiftc -O -o "$LIBEXEC/autobrightness-softdim" "$SRC/src/softdim.swift"

for f in autobrightness ddc-tune display-check; do
    ln -sf "$SRC/bin/$f" "$BIN/$f"
    echo "linked $BIN/$f"
done

case ":$PATH:" in
    *":$BIN:"*) ;;
    *) echo; echo "NOTE: $BIN is not on your PATH. Add it to your shell profile." ;;
esac

echo
echo "next:"
echo "  1. autobrightness status          - see what it detects"
echo "  2. edit the DISPLAYS list       - see README, config goes in"
echo "                                    ~/.config/autobrightness/config"
echo "  3. autobrightness install         - load the launchd agent"
