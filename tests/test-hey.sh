#!/bin/bash

set -euo pipefail
trap 'echo "$0: FAILED at line $LINENO" >&2' ERR

plugin_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT

fake_bin="$test_root/bin"
hey_log="$test_root/hey.log"
notify_log="$test_root/notify.log"
mkdir -p "$fake_bin" "$test_root/config/omaflow/rules" "$test_root/state"
mkdir "$test_root/empty-bin"

cat >"$fake_bin/hey" <<'SH'
#!/bin/bash
for arg in "$@"; do printf '[%s]' "$arg"; done >>"$HEY_LOG"
printf '\n' >>"$HEY_LOG"
[[ ${HEY_MODE:-} != exit3 ]] || exit 3
case "$*" in
  "timetrack current --json")
    if [[ ${HEY_CURRENT:-inactive} == active ]]; then
      printf '{"ok":true,"data":{"id":42,"starts_at":"2026-08-25T08:00:00Z"}}\n'
    else
      printf '{"ok":true,"summary":"No active time track"}\n'
    fi
    ;;
  "event list "*" --json")
    printf '%s\n' "${HEY_EVENTS:-[]}"
    ;;
  "event list "*" --count")
    printf '%s\n' "${HEY_COUNT:-0}"
    ;;
esac
SH

cat >"$fake_bin/notify-send" <<'SH'
#!/bin/bash
printf '%s\n%s\n' "$1" "$2" >>"$NOTIFY_LOG"
SH

cat >"$fake_bin/omarchy-notification-send" <<'SH'
#!/bin/bash
exec notify-send "$@"
SH

cat >"$fake_bin/hyprctl" <<'SH'
#!/bin/bash
printf '[]\n'
SH

cat >"$fake_bin/nmcli" <<'SH'
#!/bin/bash
true
SH

chmod +x "$fake_bin"/*

run_env() {
  HOME="$test_root" \
  XDG_CONFIG_HOME="$test_root/config" \
  XDG_STATE_HOME="$test_root/state" \
  HEY_LOG="$hey_log" \
  NOTIFY_LOG="$notify_log" \
  PATH="$fake_bin:/usr/bin:/bin" \
    "$@"
}

rules_dir="$test_root/config/omaflow/rules"
state_dir="$test_root/state/omaflow"
repo="$test_root/project"
git init -q -b feature/alpha "$repo"

cat >"$rules_dir/start-idle.json" <<EOF
{"schemaVersion":1,"id":"start-idle","name":"Start idle","enabled":true,"trigger":{"type":"manual"},"actions":[{"type":"hey-timetrack","mode":"start","categoryFromRepo":"$repo"}],"cooldownSeconds":0,"source":"test"}
EOF

: >"$hey_log"
run_env env HEY_CURRENT=inactive "$plugin_dir/bin/omaflow-run" start-idle
[[ $(sed -n '1p' "$hey_log") == '[timetrack][current][--json]' ]]
[[ $(sed -n '2p' "$hey_log") == '[timetrack][start]' ]]
run_env jq -e '.category == "feature/alpha" and (.startedAt | type == "string")' "$state_dir/timetrack.json" >/dev/null
[[ $(stat -c '%a' "$state_dir/timetrack.json") == 600 ]]

before=$(sha256sum "$state_dir/timetrack.json")
: >"$hey_log"
run_env env HEY_CURRENT=active "$plugin_dir/bin/omaflow-run" start-idle
[[ $(wc -l <"$hey_log") == 1 ]]
[[ $(<"$hey_log") == '[timetrack][current][--json]' ]]
[[ $(sha256sum "$state_dir/timetrack.json") == "$before" ]]
run_env jq -e '.actions[0].detail == "already tracking"' "$state_dir/log.jsonl" >/dev/null

cat >"$rules_dir/switch-track.json" <<'EOF'
{"schemaVersion":1,"id":"switch-track","name":"Switch track","enabled":true,"trigger":{"type":"manual"},"actions":[{"type":"hey-timetrack","mode":"switch","category":"new category"}],"cooldownSeconds":0,"source":"test"}
EOF

: >"$hey_log"
run_env env HEY_CURRENT=active "$plugin_dir/bin/omaflow-run" switch-track
[[ $(sed -n '1p' "$hey_log") == '[timetrack][current][--json]' ]]
[[ $(sed -n '2p' "$hey_log") == '[timetrack][stop][--category][feature/alpha]' ]]
[[ $(sed -n '3p' "$hey_log") == '[timetrack][start]' ]]
run_env jq -e '.category == "new category"' "$state_dir/timetrack.json" >/dev/null

cat >"$rules_dir/stop-track.json" <<'EOF'
{"schemaVersion":1,"id":"stop-track","name":"Stop track","enabled":true,"trigger":{"type":"manual"},"actions":[{"type":"hey-timetrack","mode":"stop","category":"fallback"}],"cooldownSeconds":0,"source":"test"}
EOF

: >"$hey_log"
run_env env HEY_CURRENT=active "$plugin_dir/bin/omaflow-run" stop-track
[[ $(sed -n '2p' "$hey_log") == '[timetrack][stop][--category][new category]' ]]
[[ ! -e $state_dir/timetrack.json ]]

cat >"$rules_dir/template-track.json" <<'EOF'
{"schemaVersion":1,"id":"template-track","name":"Template track","enabled":true,"trigger":{"type":"manual"},"actions":[{"type":"hey-timetrack","mode":"start","category":"{{branch}}"}],"cooldownSeconds":0,"source":"test"}
EOF

: >"$hey_log"
run_env env HEY_CURRENT=inactive /usr/bin/ruby -r "$plugin_dir/lib/omaflow" \
  -e 'exit Omaflow::Executor.run("template-track", trigger_data: { "branch" => "--unsafe\nteam" })'
run_env jq -e '.category == "unsafeteam"' "$state_dir/timetrack.json" >/dev/null
: >"$hey_log"
run_env env HEY_CURRENT=active "$plugin_dir/bin/omaflow-run" stop-track
[[ $(sed -n '2p' "$hey_log") == '[timetrack][stop][--category][unsafeteam]' ]]
[[ ! -e $state_dir/timetrack.json ]]

: >"$hey_log"
if run_env env HEY_MODE=exit3 "$plugin_dir/bin/omaflow-run" start-idle; then
  echo 'logged-out HEY action unexpectedly succeeded' >&2
  exit 1
fi
run_env jq -e '.actions[0].detail == "hey is not logged in; run: hey auth login" and .status == "failed"' \
  "$state_dir/log.jsonl" >/dev/null

cat >"$rules_dir/agenda.json" <<'EOF'
{"schemaVersion":1,"id":"agenda","name":"Agenda","enabled":true,"trigger":{"type":"manual"},"actions":[{"type":"hey-agenda","title":"Today"}],"cooldownSeconds":0,"source":"test"}
EOF

events='[{"start":"2026-08-25T09:30:00+02:00","summary":"Standup"},{"starts_at":"2026-08-25T13:15:00+02:00","title":"Planning"},{"startsAt":"not-an-iso-time-value","name":"Raw time"}]'
: >"$notify_log"
: >"$hey_log"
run_env env HEY_EVENTS="$events" "$plugin_dir/bin/omaflow-run" agenda
grep -Eq '^\[event\]\[list\]\[--starts-on\]\[[0-9]{4}-[0-9]{2}-[0-9]{2}\]\[--ends-on\]\[[0-9]{4}-[0-9]{2}-[0-9]{2}\]\[--json\]$' "$hey_log"
grep -Fq '09:30  Standup' "$notify_log"
grep -Fq '13:15  Planning' "$notify_log"
grep -Fq 'not-an-iso-time-  Raw time' "$notify_log"

: >"$notify_log"
run_env env HEY_EVENTS='[]' "$plugin_dir/bin/omaflow-run" agenda
[[ ! -s $notify_log ]]
run_env jq -e '.actions[0].detail == "no events today"' "$state_dir/log.jsonl" >/dev/null

cat >"$rules_dir/agenda-empty.json" <<'EOF'
{"schemaVersion":1,"id":"agenda-empty","name":"Empty agenda","enabled":true,"trigger":{"type":"manual"},"actions":[{"type":"hey-agenda","skipWhenEmpty":false}],"cooldownSeconds":0,"source":"test"}
EOF

run_env env HEY_EVENTS='[]' "$plugin_dir/bin/omaflow-run" agenda-empty
grep -Fq 'No events today' "$notify_log"

cat >"$rules_dir/event-gate.json" <<'EOF'
{"schemaVersion":1,"id":"event-gate","name":"Event gate","enabled":true,"trigger":{"type":"custom","name":"check-events"},"conditions":[{"type":"hey-events","atLeast":2}],"actions":[{"type":"notify","message":"events passed"}],"cooldownSeconds":0,"source":"test"}
EOF

: >"$notify_log"
run_env env HEY_COUNT=2 "$plugin_dir/bin/omaflow" trigger check-events
grep -Fq 'events passed' "$notify_log"
: >"$notify_log"
run_env env HEY_COUNT=1 "$plugin_dir/bin/omaflow" trigger check-events
[[ ! -s $notify_log ]]
: >"$notify_log"
HOME="$test_root" XDG_CONFIG_HOME="$test_root/config" XDG_STATE_HOME="$test_root/state" \
  PATH="$test_root/empty-bin" "$plugin_dir/bin/omaflow" trigger check-events
[[ ! -s $notify_log ]]

if HOME="$test_root" XDG_CONFIG_HOME="$test_root/config" XDG_STATE_HOME="$test_root/state" \
  PATH="$test_root/empty-bin" "$plugin_dir/bin/omaflow-run" agenda; then
  echo 'missing HEY CLI action unexpectedly succeeded' >&2
  exit 1
fi
jq -e '.actions[0].detail == "hey CLI is not installed" and .status == "failed"' "$state_dir/log.jsonl" >/dev/null

run_env /usr/bin/ruby -r "$plugin_dir/lib/omaflow" <<'RUBY'
base = {
  'schemaVersion' => 1, 'id' => 'hey-check', 'name' => 'HEY check', 'enabled' => true,
  'trigger' => { 'type' => 'manual' }, 'actions' => [{ 'type' => 'notify', 'message' => 'ok' }], 'source' => 'test'
}
cases = [
  [base.merge('actions' => [{ 'type' => 'hey-timetrack' }]), 'hey-timetrack needs mode'],
  [base.merge('actions' => [{ 'type' => 'hey-timetrack', 'mode' => 'pause' }]), 'hey-timetrack needs mode'],
  [base.merge('actions' => [{ 'type' => 'hey-timetrack', 'mode' => 'start', 'category' => '' }]), 'category must be'],
  [base.merge('actions' => [{ 'type' => 'hey-timetrack', 'mode' => 'start', 'category' => 'x' * 101 }]), 'category must be'],
  [base.merge('actions' => [{ 'type' => 'hey-timetrack', 'mode' => 'start', 'category' => '-option' }]), 'category must be'],
  [base.merge('actions' => [{ 'type' => 'hey-timetrack', 'mode' => 'start', 'categoryFromRepo' => 'relative' }]), 'categoryFromRepo must start'],
  [base.merge('actions' => [{ 'type' => 'hey-timetrack', 'mode' => 'start', 'categoryFromRepo' => '/tmp/../secret' }]), 'categoryFromRepo must start'],
  [base.merge('actions' => [{ 'type' => 'hey-timetrack', 'mode' => 'start', 'category' => 'work', 'categoryFromRepo' => '/tmp/repo' }]), 'mutually exclusive'],
  [base.merge('actions' => [{ 'type' => 'hey-timetrack', 'mode' => 'start', 'extra' => true }]), 'unknown field in hey-timetrack action'],
  [base.merge('actions' => [{ 'type' => 'hey-agenda', 'title' => '-option' }]), 'hey-agenda title must be'],
  [base.merge('actions' => [{ 'type' => 'hey-agenda', 'title' => 'x' * 81 }]), 'hey-agenda title must be'],
  [base.merge('actions' => [{ 'type' => 'hey-agenda', 'skipWhenEmpty' => 'yes' }]), 'skipWhenEmpty must be a boolean'],
  [base.merge('actions' => [{ 'type' => 'hey-agenda', 'extra' => true }]), 'unknown field in hey-agenda action'],
  [base.merge('conditions' => [{ 'type' => 'hey-events', 'atLeast' => 0 }]), 'atLeast as an integer 1..50'],
  [base.merge('conditions' => [{ 'type' => 'hey-events', 'atLeast' => 51 }]), 'atLeast as an integer 1..50'],
  [base.merge('conditions' => [{ 'type' => 'hey-events', 'atLeast' => 1.5 }]), 'atLeast as an integer 1..50'],
  [base.merge('conditions' => [{ 'type' => 'hey-events', 'atLeast' => 1, 'extra' => true }]), 'unknown field in hey-events condition']
]
cases.each do |rule, expected|
  errors, = Omaflow::Validator.new(rule).validate
  abort "missing validator rejection: #{expected}: #{errors.inspect}" unless errors.any? { it.include?(expected) }
end
RUBY

HOME="$test_root" XDG_CONFIG_HOME="$test_root/config" XDG_STATE_HOME="$test_root/state" PATH="$test_root/empty-bin" \
  /usr/bin/ruby -r "$plugin_dir/lib/omaflow" <<'RUBY'
rule = {
  'schemaVersion' => 1, 'id' => 'hey-warning', 'name' => 'HEY warning', 'enabled' => true,
  'trigger' => { 'type' => 'manual' }, 'conditions' => [{ 'type' => 'hey-events', 'atLeast' => 1 }],
  'actions' => [{ 'type' => 'hey-agenda' }, { 'type' => 'hey-timetrack', 'mode' => 'start' }], 'source' => 'test'
}
errors, warnings = Omaflow::Validator.new(rule).validate
abort errors.inspect unless errors.empty?
expected = 'hey CLI is not installed; this rule will fail until it is'
abort warnings.inspect unless warnings == [expected]
RUBY

echo 'test-hey: ok'
