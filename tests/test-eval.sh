#!/bin/bash

# End-to-end engine test with fake system commands: baseline, monitor-connect
# event, condition filtering, cooldown, disabled rules, and rollback on failure.

set -euo pipefail

plugin_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT

fake_bin="$test_root/bin"
calls="$test_root/calls.log"
mkdir -p "$fake_bin" "$test_root/config" "$test_root/state" "$test_root/power/AC"

# Fake system surface. Every fake appends its argv to calls.log.
make_fake() {
  local name="$1" body="$2"
  printf '#!/bin/bash\necho "%s $*" >>"%s"\n%s\n' "$name" "$calls" "$body" >"$fake_bin/$name"
  chmod +x "$fake_bin/$name"
}
make_fake hyprctl 'if [[ $1 == monitors ]]; then cat "$TEST_MONITORS"; fi'
make_fake nmcli 'if [[ $1 == -t ]]; then cat "$TEST_WIFI"; fi'
make_fake omarchy 'if [[ $1 == theme && $2 == current ]]; then echo old-theme; elif [[ $1 == theme && $2 == list ]]; then printf "old-theme\nwork-theme\nbroken-theme\n"; fi'
make_fake omarchy-shell 'case "$2" in dndState) echo off ;; status) echo "{\"stayAwake\":false}" ;; *) echo ok ;; esac'
make_fake pactl 'if [[ $1 == get-default-sink ]]; then echo old-sink; elif [[ $* == *"list sinks"* ]]; then echo "[{\"name\":\"dock-sink\",\"description\":\"Dock Audio\"}]"; fi'
make_fake omarchy-notification-send 'true'
make_fake gtk-launch 'true'

export TEST_MONITORS="$test_root/monitors.json"
export TEST_WIFI="$test_root/wifi.txt"
echo '[{"name":"eDP-1","description":"Laptop Screen"}]' >"$TEST_MONITORS"
echo 'yes:HomeWifi' >"$TEST_WIFI"
echo Mains >"$test_root/power/AC/type"
echo 1 >"$test_root/power/AC/online"

run_env() {
  HOME="$test_root" \
  XDG_CONFIG_HOME="$test_root/config" \
  XDG_STATE_HOME="$test_root/state" \
  OMAFLOW_POWER_DIR="$test_root/power" \
  PATH="$fake_bin:/usr/bin:/bin" \
    "$@"
}

rules_dir="$test_root/config/omaflow/rules"
mkdir -p "$rules_dir"

cat >"$rules_dir/dock-setup.json" <<'EOF'
{
  "schemaVersion": 1, "id": "dock-setup", "name": "Dock setup", "enabled": true,
  "trigger": {"type": "monitor-connected", "match": {"description": "Dell U38"}},
  "conditions": [{"type": "time-between", "from": "00:00", "to": "23:59"}],
  "actions": [{"type": "theme", "name": "work-theme"}, {"type": "workspace", "number": 2}],
  "cooldownSeconds": 3600, "source": "test"
}
EOF
cat >"$rules_dir/disabled-rule.json" <<'EOF'
{
  "schemaVersion": 1, "id": "disabled-rule", "name": "Disabled", "enabled": false,
  "trigger": {"type": "monitor-connected", "match": {"description": "Dell"}},
  "actions": [{"type": "workspace", "number": 9}], "source": "test"
}
EOF
cat >"$rules_dir/battery-rule.json" <<'EOF'
{
  "schemaVersion": 1, "id": "battery-rule", "name": "Battery saver", "enabled": true,
  "trigger": {"type": "power-source", "source": "battery"},
  "actions": [{"type": "dnd", "state": "on"}], "cooldownSeconds": 0, "source": "test"
}
EOF

state="$test_root/state/omaflow"

# 1. First eval stores a baseline and fires nothing.
run_env "$plugin_dir/bin/omaflow-eval" test
[[ -f $state/domains.json ]]
[[ ! -f $state/log.jsonl ]] || ! grep -q '"kind":"run"' "$state/log.jsonl"

# 2. A matching monitor appears: dock-setup fires, disabled-rule does not.
echo '[{"name":"eDP-1","description":"Laptop Screen"},{"name":"DP-3","description":"Dell U3821DW"}]' >"$TEST_MONITORS"
run_env "$plugin_dir/bin/omaflow-eval" test
grep -q 'omarchy theme set work-theme' "$calls"
grep -q 'hyprctl dispatch workspace 2' "$calls"
! grep -q 'workspace 9' "$calls"
run_env jq -e '.status == "ok" and .ruleId == "dock-setup" and (.trigger | test("monitor-connected"))' \
  <(grep '"kind":"run"' "$state/log.jsonl" | tail -1) >/dev/null

# 3. Cooldown: same monitor cycles off and on again → no second firing.
: >"$calls"
echo '[{"name":"eDP-1","description":"Laptop Screen"}]' >"$TEST_MONITORS"
run_env "$plugin_dir/bin/omaflow-eval" test
echo '[{"name":"eDP-1","description":"Laptop Screen"},{"name":"DP-3","description":"Dell U3821DW"}]' >"$TEST_MONITORS"
run_env "$plugin_dir/bin/omaflow-eval" test
! grep -q 'omarchy theme set' "$calls"

# 4. Power flips to battery → battery-rule fires with dnd on.
echo 0 >"$test_root/power/AC/online"
run_env "$plugin_dir/bin/omaflow-eval" test
grep -q 'omarchy-shell notifications setDnd on' "$calls"

# 5. Failed action rolls back: theme applies, bad sink fails, theme restored.
cat >"$rules_dir/failing-rule.json" <<'EOF'
{
  "schemaVersion": 1, "id": "failing-rule", "name": "Fails", "enabled": true,
  "trigger": {"type": "manual"},
  "actions": [{"type": "theme", "name": "broken-theme"}, {"type": "audio-output", "match": "no-such-sink"}],
  "cooldownSeconds": 0, "source": "test"
}
EOF
: >"$calls"
run_env "$plugin_dir/bin/omaflow-run" failing-rule --trigger test || true
grep -q 'omarchy theme set broken-theme' "$calls"
grep -q 'omarchy theme set old-theme' "$calls"
run_env jq -e '.status == "reverted"' <(grep '"ruleId":"failing-rule"' "$state/log.jsonl" | grep '"kind":"run"' | tail -1) >/dev/null

# 6. Dry-run: plans logged, nothing executed, no cooldown update.
: >"$calls"
run_env "$plugin_dir/bin/omaflow-run" dock-setup --dry-run >/dev/null
! grep -q 'omarchy theme set' "$calls"
run_env jq -e '.kind == "dry-run"' <(tail -1 "$state/log.jsonl") >/dev/null

echo "test-eval: ok"
