#!/bin/bash
# Installs autocontrast into ~/.local (no sudo, nothing outside your home).
set -eu
SRC="$(cd "$(dirname "$0")" && pwd)"
BIN="$HOME/.local/bin"
LIBEXEC="$HOME/.local/libexec"

command -v m1ddc >/dev/null || { echo "m1ddc is required: brew install m1ddc"; exit 1; }
command -v swiftc >/dev/null || { echo "swiftc is required: install Xcode command line tools"; exit 1; }

mkdir -p "$BIN" "$LIBEXEC"

echo "compiling builtin-brightness helper"
swiftc -O -o "$LIBEXEC/autocontrast-builtin-brightness" "$SRC/src/builtin-brightness.swift"

for f in autocontrast ddc-tune display-check; do
    ln -sf "$SRC/bin/$f" "$BIN/$f"
    echo "linked $BIN/$f"
done

case ":$PATH:" in
    *":$BIN:"*) ;;
    *) echo; echo "NOTE: $BIN is not on your PATH. Add it to your shell profile." ;;
esac

echo
echo "next:"
echo "  1. autocontrast status          - see what it detects"
echo "  2. edit the DISPLAYS list       - see README, config goes in"
echo "                                    ~/.config/autocontrast/config"
echo "  3. autocontrast install         - load the launchd agent"
