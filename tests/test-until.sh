#!/bin/bash

set -euo pipefail
trap 'echo "$0: FAILED at line $LINENO" >&2' ERR

plugin_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT

fake_bin="$test_root/bin"
calls="$test_root/calls.log"
wifi="$test_root/wifi.txt"
mkdir -p "$fake_bin" "$test_root/config/omaflow/rules" "$test_root/state"

make_fake() {
  local name="$1" body="$2"
  printf '#!/bin/bash\necho "%s $*" >>"%s"\n%s\n' "$name" "$calls" "$body" >"$fake_bin/$name"
  chmod +x "$fake_bin/$name"
}

make_fake hyprctl 'echo "[]"'
make_fake nmcli 'cat "$TEST_WIFI"'
make_fake omarchy 'true'
make_fake pactl 'echo "[]"'
make_fake omarchy-notification-send 'true'
make_fake gtk-launch 'true'

run_env() {
  HOME="$test_root" \
  XDG_CONFIG_HOME="$test_root/config" \
  XDG_STATE_HOME="$test_root/state" \
  OMAFLOW_POWER_DIR="$test_root/no-power" \
  OMAFLOW_LID_DIR="$test_root/no-lid" \
  TEST_WIFI="$wifi" \
  PATH="$fake_bin:/usr/bin:/bin" \
    "$@"
}

rules_dir="$test_root/config/omaflow/rules"
state="$test_root/state/omaflow"

cat >"$rules_dir/office.json" <<'EOF'
{
  "schemaVersion": 1, "id": "office", "name": "Office", "enabled": true,
  "trigger": {"type": "wifi-connected", "match": {"ssid": "Office"}},
  "conditions": [{"type": "on-ssid", "ssid": "Office"}],
  "actions": [{"type": "notify", "message": "office opened"}],
  "until": {
    "trigger": {"type": "wifi-disconnected"},
    "actions": [{"type": "notify", "message": "office closed {{ssid}}"}]
  },
  "cooldownSeconds": 0, "source": "test"
}
EOF

cat >"$rules_dir/timeout-rule.json" <<'EOF'
{
  "schemaVersion": 1, "id": "timeout-rule", "name": "Timeout", "enabled": true,
  "trigger": {"type": "manual"},
  "actions": [{"type": "notify", "message": "timer opened"}],
  "until": {
    "trigger": {"type": "interval", "minutes": 5},
    "actions": [{"type": "notify", "message": "timer closed"}]
  },
  "cooldownSeconds": 0, "source": "test"
}
EOF

echo 'yes:Home' >"$wifi"
run_env "$plugin_dir/bin/omaflow-eval" baseline

: >"$calls"
echo 'yes:Office' >"$wifi"
run_env "$plugin_dir/bin/omaflow-eval" connect
grep -q 'omarchy-notification-send.*office opened' "$calls"
run_env jq -e '.office.armedAt != null and (.office.armedEpoch | type == "number")' "$state/armed.json" >/dev/null
[[ $(stat -c '%a' "$state/armed.json") == 600 ]]
grep -q '"kind":"armed".*"ruleId":"office"' "$state/log.jsonl"

run_env jq '.office.armedEpoch = 1' "$state/armed.json" >"$state/armed.json.tmp"
mv "$state/armed.json.tmp" "$state/armed.json"
chmod 600 "$state/armed.json"
run_env "$plugin_dir/bin/omaflow-run" office >/dev/null
run_env jq -e 'keys == ["office"] and .office.armedEpoch > 1' "$state/armed.json" >/dev/null
[[ $(grep -c 'omarchy-notification-send.*office opened' "$calls") == 2 ]]

echo -n >"$wifi"
run_env "$plugin_dir/bin/omaflow-eval" disconnect
grep -q 'omarchy-notification-send.*office closed Office' "$calls"
run_env jq -e 'has("office") | not' "$state/armed.json" >/dev/null
run_env jq -e '.kind == "until" and .ruleId == "office" and .status == "ok" and .trigger == "until:wifi-disconnected"' \
  <(grep '"kind":"until".*"ruleId":"office"' "$state/log.jsonl" | tail -1) >/dev/null

: >"$calls"
run_env "$plugin_dir/bin/omaflow-run" timeout-rule >/dev/null
run_env jq '."timeout-rule".armedEpoch = (now | floor) - 100' "$state/armed.json" >"$state/armed.json.tmp"
mv "$state/armed.json.tmp" "$state/armed.json"
chmod 600 "$state/armed.json"
run_env "$plugin_dir/bin/omaflow-eval" early
! grep -q 'omarchy-notification-send.*timer closed' "$calls"
run_env jq -e 'has("timeout-rule")' "$state/armed.json" >/dev/null

run_env jq '."timeout-rule".armedEpoch = (now | floor) - 301' "$state/armed.json" >"$state/armed.json.tmp"
mv "$state/armed.json.tmp" "$state/armed.json"
chmod 600 "$state/armed.json"
run_env "$plugin_dir/bin/omaflow-eval" elapsed
grep -q 'omarchy-notification-send.*timer closed' "$calls"
run_env jq -e 'has("timeout-rule") | not' "$state/armed.json" >/dev/null
run_env jq -e '.trigger == "until:interval" and .status == "ok"' \
  <(grep '"kind":"until".*"ruleId":"timeout-rule"' "$state/log.jsonl" | tail -1) >/dev/null

run_env "$plugin_dir/bin/omaflow-run" timeout-rule >/dev/null
run_env "$plugin_dir/bin/omaflow" list | grep -q '^◉ timeout-rule.*(armed'
run_env "$plugin_dir/bin/omaflow" disarm timeout-rule | grep -q 'Disarmed rule: timeout-rule'
run_env jq -e 'has("timeout-rule") | not' "$state/armed.json" >/dev/null
grep -q '"kind":"disarmed".*"ruleId":"timeout-rule"' "$state/log.jsonl"
if run_env "$plugin_dir/bin/omaflow" disarm timeout-rule >"$test_root/disarm.out" 2>&1; then
  echo 'unarmed rule unexpectedly disarmed' >&2
  exit 1
fi
grep -q 'Rule is not armed: timeout-rule' "$test_root/disarm.out"

disarmed_before=$(grep -c '"kind":"disarmed"' "$state/log.jsonl")
printf '%s\n' '{"stale-id":{"armedAt":"2026-01-01T00:00:00Z","armedEpoch":1}}' >"$state/armed.json"
chmod 600 "$state/armed.json"
run_env "$plugin_dir/bin/omaflow-eval" stale
run_env jq -e '. == {}' "$state/armed.json" >/dev/null
[[ $(grep -c '"kind":"disarmed"' "$state/log.jsonl") == "$disarmed_before" ]]

manual_until="$test_root/manual-until.json"
cat >"$manual_until" <<'EOF'
{"schemaVersion":1,"id":"bad-manual","name":"Bad manual","enabled":true,"trigger":{"type":"manual"},"actions":[{"type":"notify","message":"open"}],"until":{"trigger":{"type":"manual"},"actions":[{"type":"notify","message":"close"}]},"source":"test"}
EOF
if run_env "$plugin_dir/bin/omaflow-validate" "$manual_until" >"$test_root/manual.out"; then
  echo 'manual until unexpectedly validated' >&2
  exit 1
fi
grep -q 'an until needs an event; to end manually, run omaflow disarm <id>' "$test_root/manual.out"

empty_until="$test_root/empty-until.json"
cat >"$empty_until" <<'EOF'
{"schemaVersion":1,"id":"bad-empty","name":"Bad empty","enabled":true,"trigger":{"type":"manual"},"actions":[{"type":"notify","message":"open"}],"until":{"trigger":{"type":"wifi-disconnected"},"actions":[]},"source":"test"}
EOF
if run_env "$plugin_dir/bin/omaflow-validate" "$empty_until" >"$test_root/empty.out"; then
  echo 'empty until actions unexpectedly validated' >&2
  exit 1
fi
grep -q 'until.actions must be a non-empty array' "$test_root/empty.out"

unknown_until="$test_root/unknown-until.json"
cat >"$unknown_until" <<'EOF'
{"schemaVersion":1,"id":"bad-extra","name":"Bad extra","enabled":true,"trigger":{"type":"manual"},"actions":[{"type":"notify","message":"open"}],"until":{"trigger":{"type":"wifi-disconnected"},"actions":[{"type":"notify","message":"close"}],"extra":true},"source":"test"}
EOF
if run_env "$plugin_dir/bin/omaflow-validate" "$unknown_until" >"$test_root/unknown.out"; then
  echo 'unknown until field unexpectedly validated' >&2
  exit 1
fi
grep -q 'unknown field in .until: extra' "$test_root/unknown.out"

dry_output=$(run_env "$plugin_dir/bin/omaflow-run" office --dry-run)
grep -q 'would arm: office' <<<"$dry_output"
run_env jq -e 'has("office") | not' "$state/armed.json" >/dev/null

echo 'test-until: ok'
