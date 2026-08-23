#!/bin/bash

# Validator fixtures: schema failures fail, referential failures fail,
# not-currently-present hardware only warns.

set -euo pipefail

plugin_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT

fake_bin="$test_root/bin"
apps_dir="$test_root/share/applications"
mkdir -p "$fake_bin" "$apps_dir"

printf '#!/bin/bash\nif [[ "$*" == *"theme list"* ]]; then printf "tokyo-night\nkanagawa\n"; fi\n' >"$fake_bin/omarchy"
printf '#!/bin/bash\necho "[]"\n' >"$fake_bin/pactl"
chmod +x "$fake_bin"/*
printf '[Desktop Entry]\nName=Slack\nExec=slack\n' >"$apps_dir/slack.desktop"

validate() {
  HOME="$test_root" \
  XDG_DATA_HOME="$test_root/share" \
  PATH="$fake_bin:/usr/bin:/bin" \
    "$plugin_dir/bin/omaflow-validate" "$1"
}

good="$test_root/good.json"
cat >"$good" <<'EOF'
{
  "schemaVersion": 1, "id": "good-rule", "name": "Good", "enabled": true,
  "trigger": {"type": "wifi-connected", "match": {"ssid": "Office"}},
  "conditions": [{"type": "weekday", "days": ["mon", "fri"]}],
  "actions": [
    {"type": "theme", "name": "kanagawa"},
    {"type": "launch", "app": "Slack", "workspace": 3},
    {"type": "audio-output", "match": "dock"}
  ],
  "cooldownSeconds": 60, "source": "test"
}
EOF
out=$(validate "$good")
grep -q "^warn:.*dock" <<<"$out"      # sink not present → warning only
! grep -q "^error:" <<<"$out"

bad="$test_root/bad.json"
cat >"$bad" <<'EOF'
{
  "schemaVersion": 1, "id": "Bad_ID!", "name": "Bad", "enabled": "yes",
  "trigger": {"type": "full-moon"},
  "actions": [
    {"type": "theme", "name": "no-such-theme"},
    {"type": "launch", "app": "NoSuchApp"},
    {"type": "self-destruct"}
  ],
  "extraField": true, "source": "test"
}
EOF
if validate "$bad" >"$test_root/bad.out"; then
  echo "bad rule unexpectedly validated" >&2
  exit 1
fi
grep -q "error: id must be" "$test_root/bad.out"
grep -q "error: enabled must be" "$test_root/bad.out"
grep -q "error: unknown trigger type: full-moon" "$test_root/bad.out"
grep -q "error: theme not installed" "$test_root/bad.out"
grep -q "error: no desktop entry" "$test_root/bad.out"
grep -q "error: unknown action type: self-destruct" "$test_root/bad.out"
grep -q "error: unknown top-level field" "$test_root/bad.out"

echo "test-validate: ok"
