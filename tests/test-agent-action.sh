#!/bin/bash

set -euo pipefail
trap 'echo "$0: FAILED at line $LINENO" >&2' ERR

plugin_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT

fake_bin="$test_root/bin"
rules_dir="$test_root/config/omaflow/rules"
state="$test_root/state/omaflow"
mkdir -p "$fake_bin" "$rules_dir" "$state"

cat >"$fake_bin/codex" <<'EOF'
#!/bin/bash
out=""
prev=""
for arg in "$@"; do
  [[ $prev == "--output-last-message" ]] && out=$arg
  prev=$arg
done
printf '%s' "${!#}" >"$TEST_ROOT/prompt"
cp "$TEST_ROOT/answer" "$out"
EOF

cat >"$fake_bin/hyprctl" <<'EOF'
#!/bin/bash
if [[ $1 == clients && $2 == -j ]]; then
  printf '%s\n' '[{"address":"0xabc","class":"Browser","title":"Quarterly plan","workspace":{"id":2}},{"address":"0xdef","class":"Chat","title":"Team room","workspace":{"id":4}}]'
elif [[ $1 == dispatch ]]; then
  printf '%s\n' "$*" >>"$TEST_ROOT/dispatches"
fi
EOF

cat >"$fake_bin/omarchy-notification-send" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$TEST_ROOT/notifications"
EOF

chmod +x "$fake_bin"/*

run_env() {
  TEST_ROOT="$test_root" \
  HOME="$test_root" \
  XDG_CONFIG_HOME="$test_root/config" \
  XDG_STATE_HOME="$test_root/state" \
  OMAFLOW_AGENT=codex \
  PATH="$fake_bin:/usr/bin:/bin" \
    "$@"
}

write_rule() {
  local can=$1
  local task=${2:-Close the matching window for {{trigger}}}
  jq -n --arg task "$task" --arg can "$can" '
    {
      schemaVersion: 1,
      id: "agent-test",
      name: "Agent test",
      enabled: true,
      trigger: {type: "manual"},
      actions: [{type: "agent", task: $task, can: [$can], timeoutSeconds: 30}],
      cooldownSeconds: 60,
      source: "test"
    }
  ' >"$rules_dir/agent-test.json"
}

printf '%s' '[{"op":"close-window","address":"0xabc"}]' >"$test_root/answer"
write_rule close-window
run_env "$plugin_dir/bin/omaflow-run" agent-test --trigger docked
[[ $(cat "$test_root/dispatches") == "dispatch closewindow address:0xabc" ]]
grep -q 'Close the matching window for docked' "$test_root/prompt"
run_env jq -e '
  .status == "ok"
  and .actions[0].detail == [{"op":"close-window","address":"0xabc","title":"Quarterly plan"}]
' <(tail -1 "$state/log.jsonl") >/dev/null

: >"$test_root/dispatches"
printf '%s' '[{"op":"close-window","address":"0xabc"},{"op":"close-window","address":"0xfabricated"}]' >"$test_root/answer"
if run_env "$plugin_dir/bin/omaflow-run" agent-test; then
  echo "fabricated address unexpectedly ran" >&2
  exit 1
fi
[[ ! -s $test_root/dispatches ]]
run_env jq -e '
  .status == "failed"
  and (.actions[0].detail | test("address was not in the sent window context"))
' <(tail -1 "$state/log.jsonl") >/dev/null

: >"$test_root/dispatches"
printf '%s' '[{"op":"close-window","address":"0xabc"}]' >"$test_root/answer"
write_rule focus-window
if run_env "$plugin_dir/bin/omaflow-run" agent-test; then
  echo "ungranted op unexpectedly ran" >&2
  exit 1
fi
[[ ! -s $test_root/dispatches ]]
run_env jq -e '
  .status == "failed"
  and (.actions[0].detail | test("not allowed by can"))
' <(tail -1 "$state/log.jsonl") >/dev/null

: >"$test_root/dispatches"
printf '%s' '[]' >"$test_root/answer"
write_rule close-window
run_env "$plugin_dir/bin/omaflow-run" agent-test
[[ ! -s $test_root/dispatches ]]
run_env jq -e '.status == "ok" and .actions[0].detail == []' <(tail -1 "$state/log.jsonl") >/dev/null

printf '%s' '[{"op":"close-window","address":"0xdef"}]' >"$test_root/answer"
run_env "$plugin_dir/bin/omaflow-run" agent-test --dry-run >/dev/null
[[ ! -s $test_root/dispatches ]]
run_env jq -e '
  .kind == "dry-run"
  and .status == "ok"
  and .actions[0].plan == [{"op":"close-window","address":"0xdef","title":"Team room"}]
' <(tail -1 "$state/log.jsonl") >/dev/null

bad="$test_root/bad.json"
long_task=$(printf '%0301d' 0)
jq -n --arg task "$long_task" '
  {
    schemaVersion: 1,
    id: "bad-agent",
    name: "Bad agent",
    enabled: true,
    trigger: {type: "manual"},
    actions: [
      {type: "agent", task: "bad can", can: ["delete-file"]},
      {type: "agent", task: $task, can: ["notify"]}
    ],
    cooldownSeconds: 59,
    source: "test"
  }
' >"$bad"
if run_env "$plugin_dir/bin/omaflow-validate" "$bad" >"$test_root/bad.out"; then
  echo "invalid agent rule unexpectedly validated" >&2
  exit 1
fi
grep -q 'error: agent can must be a non-empty subset' "$test_root/bad.out"
grep -q 'error: agent actions need cooldownSeconds of at least 60' "$test_root/bad.out"
grep -q 'error: agent task must be a plain string' "$test_root/bad.out"

echo "test-agent-action: ok"
