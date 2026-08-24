#!/bin/bash

set -euo pipefail

plugin_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
source_path="$plugin_dir/bin/omaflow"
target_dir="$HOME/.local/bin"
target_path="$target_dir/omaflow"

fail() {
  echo "omaflow install: $*" >&2
  exit 1
}

installed_here() {
  [[ -L $target_path && $(readlink -f -- "$target_path" 2>/dev/null || true) == "$source_path" ]]
}

case "${1:-}" in
"")
  mkdir -p "$target_dir"
  if installed_here; then
    echo "Omaflow CLI already installed at $target_path"
  elif [[ -e $target_path || -L $target_path ]]; then
    fail "$target_path already exists and is not this plugin's CLI"
  else
    ln -s "$source_path" "$target_path"
    echo "Installed Omaflow CLI at $target_path"
  fi
  ;;
--remove)
  if installed_here; then
    rm "$target_path"
    echo "Removed Omaflow CLI from $target_path"
  elif [[ -e $target_path || -L $target_path ]]; then
    fail "$target_path is not this plugin's CLI"
  else
    echo "Omaflow CLI is not installed at $target_path"
  fi
  ;;
*)
  fail "usage: ./install.sh [--remove]"
  ;;
esac
