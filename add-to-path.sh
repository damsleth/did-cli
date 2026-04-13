#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="/usr/local/bin/did-cli"

chmod +x "$SCRIPT_DIR/did-cli.zsh"

if [ -L "$TARGET" ] || [ -e "$TARGET" ]; then
  echo "'$TARGET' already exists. Overwrite? (y/N)"
  read -r answer
  [ "$answer" != "y" ] && echo "Aborted." && exit 1
  rm "$TARGET"
fi

ln -s "$SCRIPT_DIR/did-cli.zsh" "$TARGET"
echo "Linked $TARGET -> $SCRIPT_DIR/did-cli.zsh"
echo "Run 'did-cli help' to get started."
