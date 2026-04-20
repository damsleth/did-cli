#!/bin/bash
# Install did-cli as an editable pipx package so the `did-cli` console
# script lands on PATH.
set -e
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if ! command -v pipx >/dev/null 2>&1; then
  echo "pipx not found. Install it first: brew install pipx" >&2
  exit 1
fi

pipx install --force -e "$REPO_DIR"
echo
echo "did-cli installed via pipx. Run: did-cli help"
