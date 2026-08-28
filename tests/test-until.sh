#!/bin/bash

set -euo pipefail
trap 'echo "$0: FAILED at line $LINENO" >&2' ERR

plugin_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT

fake_bin="$test_root/bin"
calls="$test_root/calls.log"
wifi="$test_root/wifi.txt"
dnd_state="$test_root/dnd-state"
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
cat >"$fake_bin/omarchy-shell" <<'EOF'
#!/bin/bash
echo "omarchy-shell $*" >>"$TEST_CALLS"
case "$2" in
  dndState) cat "$TEST_DND_STATE" ;;
  setDnd) printf '%s\n' "$3" >"$TEST_DND_STATE" ;;
esac
EOF
chmod +x "$fake_bin/omarchy-shell"

run_env() {
  HOME="$test_root" \
  XDG_CONFIG_HOME="$test_root/config" \
  XDG_STATE_HOME="$test_root/state" \
  OMAFLOW_POWER_DIR="$test_root/no-power" \
  OMAFLOW_LID_DIR="$test_root/no-lid" \
  TEST_WIFI="$wifi" \
  TEST_CALLS="$calls" \
  TEST_DND_STATE="$dnd_state" \
  PATH="$fake_bin:/usr/bin:/bin" \
    "$@"
}

rules_dir="$test_root/config/omaflow/rules"
state="$test_root/state/omaflow"
opening_script="$test_root/opening-script"
closing_script="$test_root/closing-script"

cat >"$opening_script" <<'EOF'
#!/bin/bash
printf 'opening-script\n' >>"$TEST_CALLS"
EOF
chmod +x "$opening_script"
cat >"$closing_script" <<'EOF'
#!/bin/bash
printf 'closing-script\n' >>"$TEST_CALLS"
EOF
chmod +x "$closing_script"
printf '{"opening-only":{"path":"%s","description":"Opening dependency"},"closing-only":{"path":"%s","description":"Closing dependency"}}\n' \
  "$opening_script" "$closing_script" \
  >"$test_root/config/omaflow/scripts.json"

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

cat >"$rules_dir/zoom-dnd.json" <<'EOF'
{"schemaVersion":1,"id":"zoom-dnd","name":"Zoom DND","enabled":true,"trigger":{"type":"manual"},"actions":[{"type":"dnd","state":"on"}],"until":{"trigger":{"type":"custom","name":"zoom-closed"},"revert":true},"cooldownSeconds":0,"source":"test"}
EOF

cat >"$rules_dir/revert-actions.json" <<'EOF'
{"schemaVersion":1,"id":"revert-actions","name":"Revert and actions","enabled":true,"trigger":{"type":"manual"},"actions":[{"type":"dnd","state":"on"},{"type":"notify","message":"opening"}],"until":{"trigger":{"type":"custom","name":"revert-actions-closed"},"revert":true,"actions":[{"type":"dnd","state":"on"}]},"cooldownSeconds":0,"source":"test"}
EOF

cat >"$rules_dir/missing-snapshot.json" <<'EOF'
{"schemaVersion":1,"id":"missing-snapshot","name":"Missing snapshot","enabled":true,"trigger":{"type":"manual"},"actions":[{"type":"dnd","state":"on"}],"until":{"trigger":{"type":"custom","name":"missing-snapshot-closed"},"revert":true,"actions":[{"type":"notify","message":"missing snapshot closed"}]},"cooldownSeconds":0,"source":"test"}
EOF

cat >"$rules_dir/phase-close.json" <<'EOF'
{"schemaVersion":1,"id":"phase-close","name":"Phase close","enabled":true,"trigger":{"type":"manual"},"actions":[{"type":"script","name":"opening-only"}],"until":{"trigger":{"type":"custom","name":"phase-close-event"},"actions":[{"type":"notify","message":"phase close ran"}]},"cooldownSeconds":0,"source":"test"}
EOF

cat >"$rules_dir/preflight-close.json" <<'EOF'
{"schemaVersion":1,"id":"preflight-close","name":"Preflight close","enabled":true,"trigger":{"type":"manual"},"actions":[{"type":"notify","message":"preflight opened"}],"until":{"trigger":{"type":"custom","name":"preflight-close-event"},"actions":[{"type":"script","name":"closing-only"}]},"cooldownSeconds":0,"source":"test"}
EOF

echo 'yes:Home' >"$wifi"
echo off >"$dnd_state"
run_env "$plugin_dir/bin/omaflow-eval" baseline

: >"$calls"
echo 'yes:Office' >"$wifi"
run_env "$plugin_dir/bin/omaflow-eval" connect
grep -q 'omarchy-notification-send.*office opened' "$calls"
run_env jq -e '.office.armedAt != null and (.office.armedEpoch | type == "number") and (.office.execId | type == "string")' \
  "$state/armed.json" >/dev/null
[[ $(stat -c '%a' "$state/armed.json") == 600 ]]
grep -q '"kind":"armed".*"ruleId":"office"' "$state/log.jsonl"

first_exec_id=$(run_env jq -r '.office.execId' "$state/armed.json")
run_env jq '.office.armedEpoch = 1' "$state/armed.json" >"$state/armed.json.tmp"
mv "$state/armed.json.tmp" "$state/armed.json"
chmod 600 "$state/armed.json"
run_env "$plugin_dir/bin/omaflow-run" office >/dev/null
run_env jq -e --arg first "$first_exec_id" \
  'keys == ["office"] and .office.armedEpoch > 1 and .office.execId != $first' "$state/armed.json" >/dev/null
[[ $(grep -c 'omarchy-notification-send.*office opened' "$calls") == 2 ]]

echo -n >"$wifi"
run_env "$plugin_dir/bin/omaflow-eval" disconnect
grep -q 'omarchy-notification-send.*office closed Office' "$calls"
run_env jq -e 'has("office") | not' "$state/armed.json" >/dev/null
run_env jq -e '.kind == "until" and .ruleId == "office" and .status == "ok" and .trigger == "until:wifi-disconnected"' \
  <(grep '"kind":"until".*"ruleId":"office"' "$state/log.jsonl" | tail -1) >/dev/null

echo off >"$dnd_state"
run_env "$plugin_dir/bin/omaflow-run" zoom-dnd >/dev/null
[[ $(<"$dnd_state") == on ]]
run_env "$plugin_dir/bin/omaflow" trigger zoom-closed >/dev/null
[[ $(<"$dnd_state") == off ]]
run_env jq -e 'has("zoom-dnd") | not' "$state/armed.json" >/dev/null
run_env jq -e '.status == "ok" and .detail == "revert: ok"' \
  <(grep '"kind":"until".*"ruleId":"zoom-dnd"' "$state/log.jsonl" | tail -1) >/dev/null

echo on >"$dnd_state"
run_env "$plugin_dir/bin/omaflow-run" zoom-dnd >/dev/null
run_env "$plugin_dir/bin/omaflow" trigger zoom-closed >/dev/null
[[ $(<"$dnd_state") == on ]]

echo off >"$dnd_state"
run_env "$plugin_dir/bin/omaflow-run" revert-actions >/dev/null
: >"$calls"
run_env "$plugin_dir/bin/omaflow" trigger revert-actions-closed >/dev/null
mapfile -t dnd_calls < <(grep 'omarchy-shell notifications setDnd' "$calls")
[[ ${#dnd_calls[@]} == 2 ]]
[[ ${dnd_calls[0]} == *'setDnd off' ]]
[[ ${dnd_calls[1]} == *'setDnd on' ]]
run_env jq -e '.status == "ok" and (.detail | test("revert: partial"))' \
  <(grep '"kind":"until".*"ruleId":"revert-actions"' "$state/log.jsonl" | tail -1) >/dev/null
run_env jq -e 'has("revert-actions") | not' "$state/armed.json" >/dev/null

echo off >"$dnd_state"
run_env "$plugin_dir/bin/omaflow-run" missing-snapshot >/dev/null
missing_exec_id=$(run_env jq -r '."missing-snapshot".execId' "$state/armed.json")
rm "$state/snapshots/$missing_exec_id.json"
: >"$calls"
run_env "$plugin_dir/bin/omaflow" trigger missing-snapshot-closed >/dev/null 2>&1
grep -q 'omarchy-notification-send.*missing snapshot closed' "$calls"
run_env jq -e 'has("missing-snapshot") | not' "$state/armed.json" >/dev/null
run_env jq -e '.status == "ok" and .detail == "revert: skipped — snapshot expired or missing"' \
  <(grep '"kind":"until".*"ruleId":"missing-snapshot"' "$state/log.jsonl" | tail -1) >/dev/null

run_env "$plugin_dir/bin/omaflow-run" phase-close >/dev/null
grep -q '^opening-script$' "$calls"
rm "$opening_script"
: >"$calls"
run_env "$plugin_dir/bin/omaflow" trigger phase-close-event >/dev/null
grep -q 'omarchy-notification-send.*phase close ran' "$calls"
run_env jq -e 'has("phase-close") | not' "$state/armed.json" >/dev/null
run_env jq -e '.kind == "until" and .ruleId == "phase-close" and .status == "ok"' \
  <(grep '"kind":"until".*"ruleId":"phase-close"' "$state/log.jsonl" | tail -1) >/dev/null

run_env "$plugin_dir/bin/omaflow-run" preflight-close >/dev/null
rm "$closing_script"
run_env "$plugin_dir/bin/omaflow" trigger preflight-close-event >/dev/null 2>&1
run_env jq -e '."preflight-close".pendingUntil.type == "custom" and ."preflight-close".pendingUntil.data.name == "preflight-close-event"' \
  "$state/armed.json" >/dev/null
run_env jq -e '.kind == "until" and .ruleId == "preflight-close" and .status == "invalid"' \
  <(grep '"kind":"until".*"ruleId":"preflight-close"' "$state/log.jsonl" | tail -1) >/dev/null
cat >"$closing_script" <<'EOF'
#!/bin/bash
printf 'closing-script\n' >>"$TEST_CALLS"
EOF
chmod +x "$closing_script"
: >"$calls"
run_env "$plugin_dir/bin/omaflow-eval" retry-preflight-close >/dev/null
grep -q '^closing-script$' "$calls"
run_env jq -e 'has("preflight-close") | not' "$state/armed.json" >/dev/null

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

no_close="$test_root/no-close.json"
cat >"$no_close" <<'EOF'
{"schemaVersion":1,"id":"bad-no-close","name":"Bad no close","enabled":true,"trigger":{"type":"manual"},"actions":[{"type":"notify","message":"open"}],"until":{"trigger":{"type":"wifi-disconnected"}},"source":"test"}
EOF
if run_env "$plugin_dir/bin/omaflow-validate" "$no_close" >"$test_root/no-close.out"; then
  echo 'until without actions or revert unexpectedly validated' >&2
  exit 1
fi
grep -q 'until must have revert: true or 1..10 actions' "$test_root/no-close.out"

bad_revert="$test_root/bad-revert.json"
cat >"$bad_revert" <<'EOF'
{"schemaVersion":1,"id":"bad-revert","name":"Bad revert","enabled":true,"trigger":{"type":"manual"},"actions":[{"type":"dnd","state":"on"}],"until":{"trigger":{"type":"wifi-disconnected"},"revert":"yes"},"source":"test"}
EOF
if run_env "$plugin_dir/bin/omaflow-validate" "$bad_revert" >"$test_root/bad-revert.out"; then
  echo 'non-boolean until revert unexpectedly validated' >&2
  exit 1
fi
grep -q 'until.revert must be true' "$test_root/bad-revert.out"

not_revertible="$test_root/not-revertible.json"
cat >"$not_revertible" <<'EOF'
{"schemaVersion":1,"id":"not-revertible","name":"Not revertible","enabled":true,"trigger":{"type":"manual"},"actions":[{"type":"notify","message":"open"}],"until":{"trigger":{"type":"wifi-disconnected"},"revert":true},"source":"test"}
EOF
warning_output=$(run_env "$plugin_dir/bin/omaflow-validate" "$not_revertible")
grep -q "^warn: nothing in this rule's actions can be reverted" <<<"$warning_output"

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
