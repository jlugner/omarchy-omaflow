#!/bin/bash

set -euo pipefail
trap 'echo "$0: FAILED at line $LINENO" >&2' ERR

plugin_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT

HOME="$test_root" "$plugin_dir/install.sh" >/dev/null
target="$test_root/.local/bin/omaflow"
[[ -L $target ]]
[[ $(readlink -f "$target") == "$plugin_dir/bin/omaflow" ]]
HOME="$test_root" PATH="$test_root/.local/bin:/usr/bin:/bin" omaflow --help | grep -q 'Omaflow CLI'

HOME="$test_root" "$plugin_dir/install.sh" | grep -q 'already installed'
HOME="$test_root" "$plugin_dir/install.sh" --remove >/dev/null
[[ ! -e $target && ! -L $target ]]
HOME="$test_root" "$plugin_dir/install.sh" --remove | grep -q 'not installed'

ln -s /usr/bin/true "$target"
if HOME="$test_root" "$plugin_dir/install.sh" 2>/dev/null; then
  echo "unrelated command link unexpectedly replaced" >&2
  exit 1
fi
[[ $(readlink "$target") == /usr/bin/true ]]
if HOME="$test_root" "$plugin_dir/install.sh" --remove 2>/dev/null; then
  echo "unrelated command link unexpectedly removed" >&2
  exit 1
fi

echo "test-install: ok"
