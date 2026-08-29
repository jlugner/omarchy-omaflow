#!/bin/bash

# The while block: reactions that live only between a rule's opening fire and
# its until. Event whiles, repeating interval whiles, until-wins ordering,
# repo watching that follows the armed state, and validation.

set -euo pipefail
trap 'echo "$0: FAILED at line $LINENO" >&2' ERR

plugin_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT

fake_bin="$test_root/bin"
calls="$test_root/calls.log"
mkdir -p "$fake_bin" "$test_root/config/omaflow/rules" "$test_root/state"

make_fake() {
  local name="$1" body="$2"
  printf '#!/bin/bash\necho "%s $*" >>"%s"\n%s\n' "$name" "$calls" "$body" >"$fake_bin/$name"
  chmod +x "$fake_bin/$name"
}

make_fake hyprctl 'echo "[]"'
make_fake nmcli 'true'
make_fake omarchy 'true'
make_fake pactl 'echo "[]"'
make_fake omarchy-shell 'echo ok'
make_fake omarchy-notification-send 'true'

run_env() {
  HOME="$test_root" \
  XDG_CONFIG_HOME="$test_root/config" \
  XDG_STATE_HOME="$test_root/state" \
  OMAFLOW_POWER_DIR="$test_root/no-power" \
  OMAFLOW_LID_DIR="$test_root/no-lid" \
  PATH="$fake_bin:/usr/bin:/bin" \
    "$@"
}

rules_dir="$test_root/config/omaflow/rules"
state="$test_root/state/omaflow"
repo="$test_root/repo"
git init -q "$repo"
echo base >"$repo/tracked.txt"
git -C "$repo" add tracked.txt
git -C "$repo" -c user.name=Omaflow -c user.email=omaflow@example.com commit -qm baseline

cat >"$rules_dir/office-branch.json" <<'EOF'
{
  "schemaVersion": 1, "id": "office-branch", "name": "Office branch", "enabled": true,
  "trigger": {"type": "manual"},
  "actions": [{"type": "notify", "message": "office opened"}],
  "while": [
    {"trigger": {"type": "git-branch-changed", "repo": "~/repo"}, "actions": [{"type": "notify", "message": "switched to {{branch}} from {{from}}"}]},
    {"trigger": {"type": "custom", "name": "office-ping"}, "actions": [{"type": "notify", "message": "office pinged"}]}
  ],
  "until": {
    "trigger": {"type": "custom", "name": "leave-office"},
    "actions": [{"type": "notify", "message": "office closed"}]
  },
  "cooldownSeconds": 0, "source": "test"
}
EOF

cat >"$rules_dir/pulse.json" <<'EOF'
{
  "schemaVersion": 1, "id": "pulse", "name": "Pulse", "enabled": true,
  "trigger": {"type": "manual"},
  "actions": [{"type": "notify", "message": "pulse opened"}],
  "while": [
    {"trigger": {"type": "interval", "minutes": 5}, "actions": [{"type": "notify", "message": "fast-pulse"}]},
    {"trigger": {"type": "interval", "minutes": 10}, "actions": [{"type": "notify", "message": "slow-pulse"}]}
  ],
  "until": {"trigger": {"type": "interval", "minutes": 60}, "actions": [{"type": "notify", "message": "pulse closed"}]},
  "cooldownSeconds": 0, "source": "test"
}
EOF

cat >"$rules_dir/same-event.json" <<'EOF'
{
  "schemaVersion": 1, "id": "same-event", "name": "Same event", "enabled": true,
  "trigger": {"type": "manual"},
  "actions": [{"type": "notify", "message": "same opened"}],
  "while": [{"trigger": {"type": "custom", "name": "ping"}, "actions": [{"type": "notify", "message": "ping while"}]}],
  "until": {"trigger": {"type": "custom", "name": "ping"}, "actions": [{"type": "notify", "message": "ping closed"}]},
  "cooldownSeconds": 0, "source": "test"
}
EOF

run_env "$plugin_dir/bin/omaflow-eval" baseline >/dev/null

# Not armed: the repo is not watched and branch changes do nothing.
run_env jq -e '.dirs | length == 0' "$state/watched-dirs.json" >/dev/null
git -C "$repo" checkout -q -b feature/before
run_env "$plugin_dir/bin/omaflow-eval" tick >/dev/null
! grep -q 'switched to' "$calls"

# Armed: the repo joins the watch list and a branch switch runs the while
# actions, leaving the rule armed.
run_env "$plugin_dir/bin/omaflow-run" office-branch >/dev/null
run_env jq -e 'has("office-branch")' "$state/armed.json" >/dev/null
run_env "$plugin_dir/bin/omaflow-eval" tick >/dev/null
run_env jq -e '.dirs | length == 1 and (.[0] | endswith("/repo/.git"))' "$state/watched-dirs.json" >/dev/null
! grep -q 'switched to' "$calls"
git -C "$repo" checkout -q -b feature/during
run_env "$plugin_dir/bin/omaflow-eval" tick >/dev/null
grep -q 'omarchy-notification-send.*switched to feature/during from feature/before' "$calls"
run_env jq -e 'has("office-branch")' "$state/armed.json" >/dev/null
run_env jq -e '.kind == "while" and .ruleId == "office-branch" and .status == "ok" and .trigger == "while[0]:git-branch-changed"' \
  <(grep '"kind":"while".*"ruleId":"office-branch"' "$state/log.jsonl" | tail -1) >/dev/null
run_env "$plugin_dir/bin/omaflow" trigger office-ping >/dev/null
grep -q 'omarchy-notification-send.*office pinged' "$calls"
run_env jq -e '.trigger == "while[1]:custom"' \
  <(grep '"kind":"while".*"ruleId":"office-branch"' "$state/log.jsonl" | tail -1) >/dev/null
run_env jq -e 'has("office-branch")' "$state/armed.json" >/dev/null
[[ $(grep -c '"kind":"armed".*"ruleId":"office-branch"' "$state/log.jsonl") == 1 ]]

# Closed: disarmed, repo dropped from the watch list, branch changes ignored.
run_env "$plugin_dir/bin/omaflow" trigger leave-office >/dev/null
grep -q 'omarchy-notification-send.*office closed' "$calls"
run_env jq -e 'has("office-branch") | not' "$state/armed.json" >/dev/null
run_env "$plugin_dir/bin/omaflow" trigger office-ping >/dev/null
[[ $(grep -c 'office pinged' "$calls") == 1 ]]
run_env "$plugin_dir/bin/omaflow-eval" tick >/dev/null
run_env jq -e '.dirs | length == 0' "$state/watched-dirs.json" >/dev/null
git -C "$repo" checkout -q -b feature/after
run_env "$plugin_dir/bin/omaflow-eval" tick >/dev/null
[[ $(grep -c 'switched to' "$calls") == 1 ]]

# Interval while repeats from the later of arming and its own last fire; the
# interval until still closes the rule, and a due while does not fire in the
# tick that closes.
set_armed() {
  run_env jq "$1" "$state/armed.json" >"$state/armed.json.tmp"
  mv "$state/armed.json.tmp" "$state/armed.json"
  chmod 600 "$state/armed.json"
}
: >"$calls"
run_env "$plugin_dir/bin/omaflow-run" pulse >/dev/null
run_env "$plugin_dir/bin/omaflow-eval" tick >/dev/null
! grep -q 'omarchy-notification-send.*fast-pulse$' "$calls"
set_armed '.pulse.armedEpoch -= 400'
run_env "$plugin_dir/bin/omaflow-eval" tick >/dev/null
[[ $(grep -c 'omarchy-notification-send.*fast-pulse$' "$calls") == 1 ]]
! grep -q 'slow-pulse' "$calls"
run_env jq -e '.pulse.whileEpochs["0"] | type == "number"' "$state/armed.json" >/dev/null
run_env jq -e '.pulse.whileEpochs | has("1") | not' "$state/armed.json" >/dev/null
run_env "$plugin_dir/bin/omaflow-eval" tick >/dev/null
[[ $(grep -c 'omarchy-notification-send.*fast-pulse$' "$calls") == 1 ]]
set_armed '.pulse.whileEpochs["0"] -= 400 | .pulse.armedEpoch -= 400'
run_env "$plugin_dir/bin/omaflow-eval" tick >/dev/null
[[ $(grep -c 'omarchy-notification-send.*fast-pulse$' "$calls") == 2 ]]
[[ $(grep -c 'slow-pulse' "$calls") == 1 ]]
run_env jq -e '.pulse.whileEpochs | has("0") and has("1")' "$state/armed.json" >/dev/null
run_env jq -e 'has("pulse")' "$state/armed.json" >/dev/null
set_armed '.pulse.armedEpoch -= 4000 | .pulse.whileEpochs["0"] -= 4000 | .pulse.whileEpochs["1"] -= 4000'
run_env "$plugin_dir/bin/omaflow-eval" tick >/dev/null
grep -q 'omarchy-notification-send.*pulse closed' "$calls"
[[ $(grep -c 'omarchy-notification-send.*fast-pulse$' "$calls") == 2 ]]
[[ $(grep -c 'slow-pulse' "$calls") == 1 ]]
run_env jq -e 'has("pulse") | not' "$state/armed.json" >/dev/null

# One event matching both while and until: the until wins.
: >"$calls"
run_env "$plugin_dir/bin/omaflow-run" same-event >/dev/null
run_env "$plugin_dir/bin/omaflow" trigger ping >/dev/null
grep -q 'omarchy-notification-send.*ping closed' "$calls"
! grep -q 'ping while' "$calls"
run_env jq -e 'has("same-event") | not' "$state/armed.json" >/dev/null

# Validation.
expect_error() {
  local file="$1" message="$2"
  if run_env "$plugin_dir/bin/omaflow-validate" "$file" >"$test_root/validate.out" 2>&1; then
    echo "expected validation to fail: $message" >&2
    exit 1
  fi
  grep -q "$message" "$test_root/validate.out"
}
base='{"schemaVersion":1,"id":"w","name":"W","enabled":true,"trigger":{"type":"manual"},"actions":[{"type":"notify","message":"x"}],"source":"test"'
until_block='"until":{"trigger":{"type":"custom","name":"done"},"actions":[{"type":"notify","message":"done"}]}'
reaction='{"trigger":{"type":"custom","name":"a"},"actions":[{"type":"notify","message":"a"}]}'
echo "$base,\"while\":[$reaction]}" >"$test_root/no-until.json"
expect_error "$test_root/no-until.json" 'while needs an until'
echo "$base,$until_block,\"while\":[{\"trigger\":{\"type\":\"manual\"},\"actions\":[{\"type\":\"notify\",\"message\":\"a\"}]}]}" >"$test_root/manual.json"
expect_error "$test_root/manual.json" 'a while needs an event to react to'
echo "$base,$until_block,\"while\":[$reaction,{\"trigger\":{\"type\":\"custom\",\"name\":\"b\"},\"actions\":[]}]}" >"$test_root/empty.json"
expect_error "$test_root/empty.json" '.while\[1\].actions must be a non-empty array'
echo "$base,$until_block,\"while\":[{\"trigger\":{\"type\":\"custom\",\"name\":\"a\"},\"actions\":[{\"type\":\"notify\",\"message\":\"a\"}],\"revert\":true}]}" >"$test_root/extra.json"
expect_error "$test_root/extra.json" 'revert'
echo "$base,$until_block,\"while\":{\"trigger\":{\"type\":\"custom\",\"name\":\"a\"},\"actions\":[{\"type\":\"notify\",\"message\":\"a\"}]}}" >"$test_root/object.json"
expect_error "$test_root/object.json" 'while must be an array of 1..5 reactions'
echo "$base,$until_block,\"while\":[]}" >"$test_root/none.json"
expect_error "$test_root/none.json" 'while must be an array of 1..5 reactions'
echo "$base,$until_block,\"while\":[$reaction,$reaction,$reaction,$reaction,$reaction,$reaction]}" >"$test_root/many.json"
expect_error "$test_root/many.json" 'while must be an array of 1..5 reactions'
echo "$base,$until_block,\"while\":[$reaction,\"soon\"]}" >"$test_root/string.json"
expect_error "$test_root/string.json" '.while\[1\] must be an object'
echo "$base,$until_block,\"while\":[$reaction,{\"trigger\":{\"type\":\"interval\",\"minutes\":20},\"actions\":[{\"type\":\"notify\",\"message\":\"b\"}]}]}" >"$test_root/good.json"
run_env "$plugin_dir/bin/omaflow-validate" "$test_root/good.json" >/dev/null

echo "test-while: ok"
