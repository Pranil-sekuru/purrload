#!/bin/zsh
# Build and install Purrload: the app into ~/Applications, the commands into ~/.local/bin. The app starts the engine.
set -euo pipefail
ROOT=${0:A:h:h}

"$ROOT/scripts/build.sh" --install

mkdir -p "$HOME/.local/bin"
for cmd in purr purr-torrent purr-progress purrload-engine; do
  ln -sf "$ROOT/bin/$cmd" "$HOME/.local/bin/$cmd"
done
echo "linked purr commands into ~/.local/bin"
[[ ":$PATH:" == *":$HOME/.local/bin:"* ]] || echo "add this to ~/.zshrc:  export PATH=\"\$HOME/.local/bin:\$PATH\""

echo
echo "Done. Purrload starts its engine itself; it asks once about running in the background."
