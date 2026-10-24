#!/bin/zsh
# Build and install Purrload: the app into ~/Applications, the commands into ~/.local/bin, then start the engine.
set -euo pipefail
ROOT=${0:A:h:h}

"$ROOT/scripts/build.sh" --install

mkdir -p "$HOME/.local/bin"
for cmd in purr purr-torrent purr-progress purrload-engine; do
  ln -sf "$ROOT/bin/$cmd" "$HOME/.local/bin/$cmd"
done
echo "linked purr commands into ~/.local/bin"
[[ ":$PATH:" == *":$HOME/.local/bin:"* ]] || echo "add this to ~/.zshrc:  export PATH=\"\$HOME/.local/bin:\$PATH\""

"$ROOT/bin/purrload-engine"
echo
echo "Done. If the notch shows 'off', give your terminal Full Disk Access"
echo "(System Settings > Privacy & Security) and run: purrload-engine"
