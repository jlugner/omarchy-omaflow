#!/bin/bash

# End-to-end engine test with fake system commands: baseline, monitor-connect
# event, condition filtering, cooldown, disabled rules, and rollback on failure.

set -euo pipefail
trap 'echo "$0: FAILED at line $LINENO" >&2' ERR

plugin_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT

fake_bin="$test_root/bin"
calls="$test_root/calls.log"
mkdir -p "$fake_bin" "$test_root/config" "$test_root/state" "$test_root/power/AC" "$test_root/lid/LID0"

# Fake system surface. Every fake appends its argv to calls.log.
make_fake() {
  local name="$1" body="$2"
  printf '#!/bin/bash\necho "%s $*" >>"%s"\n%s\n' "$name" "$calls" "$body" >"$fake_bin/$name"
  chmod +x "$fake_bin/$name"
}
make_fake hyprctl 'if [[ -n ${TEST_HYPRCTL_FAIL:-} ]]; then exit 1; fi; if [[ $1 == monitors ]]; then cat "$TEST_MONITORS"; fi'
make_fake nmcli 'if [[ $1 == -t ]]; then cat "$TEST_WIFI"; fi'
make_fake omarchy 'if [[ $1 == theme && $2 == current ]]; then echo old-theme; elif [[ $1 == theme && $2 == list ]]; then printf "old-theme\nwork-theme\nbroken-theme\n"; fi'
make_fake omarchy-shell 'case "$2" in dndState) echo off ;; status) echo "{\"stayAwake\":false}" ;; fingerprintControlAvailable) echo true ;; *) echo ok ;; esac'
make_fake pactl 'if [[ $1 == get-default-sink ]]; then echo old-sink; elif [[ $* == *"list sinks"* ]]; then echo "[{\"name\":\"dock-sink\",\"description\":\"Dock Audio\"}]"; fi'
make_fake omarchy-notification-send 'true'
make_fake gtk-launch 'true'

export TEST_MONITORS="$test_root/monitors.json"
export TEST_WIFI="$test_root/wifi.txt"
echo '[{"name":"eDP-1","description":"Laptop Screen"}]' >"$TEST_MONITORS"
echo 'yes:HomeWifi' >"$TEST_WIFI"
echo Mains >"$test_root/power/AC/type"
echo 1 >"$test_root/power/AC/online"
echo 'state: open' >"$test_root/lid/LID0/state"

run_env() {
  HOME="$test_root" \
  XDG_CONFIG_HOME="$test_root/config" \
  XDG_STATE_HOME="$test_root/state" \
  OMAFLOW_POWER_DIR="$test_root/power" \
  OMAFLOW_LID_DIR="$test_root/lid" \
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

# 1. First eval stores a baseline, seeds the current SSID as seen, fires nothing.
run_env "$plugin_dir/bin/omaflow-eval" test
[[ -f $state/domains.json ]]
[[ ! -f $state/log.jsonl ]] || ! grep -q '"kind":"run"' "$state/log.jsonl"
run_env jq -e 'index("HomeWifi") != null' "$state/seen-ssids.json" >/dev/null

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
#    The run is honestly labelled "failed"; the rollback logs its own entry.
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
run_env jq -e '.status == "failed"' <(grep '"ruleId":"failing-rule"' "$state/log.jsonl" | grep '"kind":"run"' | tail -1) >/dev/null
run_env jq -e '.kind == "revert" and .status == "ok"' <(grep '"kind":"revert"' "$state/log.jsonl" | tail -1) >/dev/null

# 6. Dry-run: plans logged, nothing executed, no cooldown update.
: >"$calls"
run_env "$plugin_dir/bin/omaflow-run" dock-setup --dry-run >/dev/null
! grep -q 'omarchy theme set' "$calls"
run_env jq -e '.kind == "dry-run"' <(tail -1 "$state/log.jsonl") >/dev/null

# 7. A failed probe fabricates no events: hyprctl dying must not fire
#    monitor-disconnected rules or corrupt the stored monitor state.
cat >"$rules_dir/undock-rule.json" <<'EOF'
{
  "schemaVersion": 1, "id": "undock-rule", "name": "Undock", "enabled": true,
  "trigger": {"type": "monitor-disconnected", "match": {"description": "Dell"}},
  "actions": [{"type": "notify", "message": "undocked"}], "cooldownSeconds": 0, "source": "test"
}
EOF
: >"$calls"
TEST_HYPRCTL_FAIL=1 run_env "$plugin_dir/bin/omaflow-eval" test
! grep -q 'omarchy-notification-send.*undocked' "$calls"
run_env jq -e '.monitors | length == 2' "$state/domains.json" >/dev/null

# 8. webhook: rules reference named endpoints from the user's allowlist;
#    formats shape the body; {{trigger}} is substituted; unknown names fail
#    validation before anything runs.
cat >"$fake_bin/curl" <<'EOF'
#!/bin/bash
echo "curl $*" >>"$TEST_CALLS"
EOF
chmod +x "$fake_bin/curl"
export TEST_CALLS="$calls"
mkdir -p "$test_root/config/omaflow"
cat >"$test_root/config/omaflow/webhooks.json" <<'EOF'
{"team-slack": {"url": "https://hooks.example.com/T/B/x", "format": "slack"},
 "phone": {"url": "https://ntfy.example.com/topic", "format": "ntfy"}}
EOF
# A trigger with & and a message with a leading @ (a file-upload attempt):
# the & must survive literally, and curl must use --data-raw (never
# --data-binary "@…", which would upload a file).
cat >"$rules_dir/hook-rule.json" <<'EOF'
{
  "schemaVersion": 1, "id": "hook-rule", "name": "Ping team", "enabled": true,
  "trigger": {"type": "manual"},
  "actions": [
    {"type": "webhook", "endpoint": "team-slack", "message": "Desktop: {{trigger}}"},
    {"type": "webhook", "endpoint": "phone", "message": "@/etc/passwd"}
  ],
  "cooldownSeconds": 0, "source": "test"
}
EOF
: >"$calls"
run_env "$plugin_dir/bin/omaflow-run" hook-rule --trigger "wifi ssid=R&D"
grep -q 'curl.*https://hooks.example.com/T/B/x' "$calls"
grep -q -- '--data-raw {"text":"Desktop: wifi ssid=R&D"}' "$calls"   # & preserved, not eaten by patsub
grep -q 'Content-Type: text/plain' "$calls"
grep -q -- '--data-raw @/etc/passwd' "$calls"                        # passed as data, not a file ref
! grep -q -- '--data-binary' "$calls"                                # never the @-interpreting flag
run_env jq -e '.status == "ok"' <(grep '"ruleId":"hook-rule"' "$state/log.jsonl" | tail -1) >/dev/null

cat >"$rules_dir/bad-hook.json" <<'EOF'
{
  "schemaVersion": 1, "id": "bad-hook", "name": "Bad", "enabled": true,
  "trigger": {"type": "manual"},
  "actions": [{"type": "webhook", "endpoint": "not-configured", "message": "x"}],
  "cooldownSeconds": 0, "source": "test"
}
EOF
: >"$calls"
if run_env "$plugin_dir/bin/omaflow-run" bad-hook 2>/dev/null; then
  echo "unknown endpoint unexpectedly ran" >&2
  exit 1
fi
! grep -q curl "$calls"

# A malformed stored endpoint (non-http url) is rejected at run time even
# though the rule references a real endpoint name.
cat >"$test_root/config/omaflow/webhooks.json" <<'EOF'
{"evil": {"url": "file:///etc/passwd", "format": "raw"}}
EOF
cat >"$rules_dir/evil-hook.json" <<'EOF'
{
  "schemaVersion": 1, "id": "evil-hook", "name": "Evil", "enabled": true,
  "trigger": {"type": "manual"},
  "actions": [{"type": "webhook", "endpoint": "evil", "message": "x"}],
  "cooldownSeconds": 0, "source": "test"
}
EOF
: >"$calls"
if run_env "$plugin_dir/bin/omaflow-run" evil-hook 2>/dev/null; then
  echo "malformed endpoint unexpectedly ran" >&2
  exit 1
fi
! grep -q curl "$calls"

# 9. Reverting a run whose actions were all non-revertible fails honestly
#    instead of claiming that a no-op restored anything.
cat >"$rules_dir/notify-only.json" <<'EOF'
{
  "schemaVersion": 1, "id": "notify-only", "name": "Notify only", "enabled": true,
  "trigger": {"type": "manual"},
  "actions": [{"type": "notify", "message": "hello"}], "cooldownSeconds": 0, "source": "test"
}
EOF
run_env "$plugin_dir/bin/omaflow-run" notify-only --trigger test
exec_id=$(grep '"ruleId":"notify-only"' "$state/log.jsonl" | tail -1 | jq -r '.execId')
if run_env "$plugin_dir/bin/omaflow-run" --revert "$exec_id" 2>/dev/null; then
  echo "non-revertible execution unexpectedly reported a successful revert" >&2
  exit 1
fi
run_env jq -e '.kind == "revert" and .status == "not-revertible"' \
  <(grep "\"execId\":\"$exec_id\"" "$state/log.jsonl" | tail -1) >/dev/null

# 10. Corrupt domain state quarantines and re-baselines instead of stalling.
echo 'not json' >"$state/domains.json"
run_env "$plugin_dir/bin/omaflow-eval" test
run_env jq -e '.monitors | length == 2' "$state/domains.json" >/dev/null
[[ -f $state/domains.json.corrupt ]]

# 11. Two rules firing from one evaluation get distinct execution ids.
cat >"$rules_dir/twin-a.json" <<'EOF'
{
  "schemaVersion": 1, "id": "twin-a", "name": "Twin A", "enabled": true,
  "trigger": {"type": "monitor-connected", "match": {"description": "Twin Screen"}},
  "actions": [{"type": "notify", "message": "a"}], "cooldownSeconds": 0, "source": "test"
}
EOF
cat >"$rules_dir/twin-b.json" <<'EOF'
{
  "schemaVersion": 1, "id": "twin-b", "name": "Twin B", "enabled": true,
  "trigger": {"type": "monitor-connected", "match": {"description": "Twin Screen"}},
  "actions": [{"type": "notify", "message": "b"}], "cooldownSeconds": 0, "source": "test"
}
EOF
echo '[{"name":"eDP-1","description":"Laptop Screen"},{"name":"DP-3","description":"Dell U3821DW"},{"name":"DP-4","description":"Twin Screen"}]' >"$TEST_MONITORS"
run_env "$plugin_dir/bin/omaflow-eval" test
twin_ids=$(grep -E '"ruleId":"twin-(a|b)"' "$state/log.jsonl" | jq -r '.execId')
[[ $(wc -l <<<"$twin_ids") == 2 ]]
[[ $(sort -u <<<"$twin_ids" | wc -l) == 2 ]]

# 12. A failed probe at baseline time must not fabricate events once the
#     probe recovers: the recovered domain re-baselines silently.
rm -f "$state/domains.json" "$state/domains.json.corrupt"
TEST_HYPRCTL_FAIL=1 run_env "$plugin_dir/bin/omaflow-eval" test
run_env jq -e 'has("monitors") | not' "$state/domains.json" >/dev/null
: >"$calls"
run_env "$plugin_dir/bin/omaflow-eval" test
! grep -qE 'omarchy-notification-send (a|b)' "$calls"
run_env jq -e '.monitors | length == 3' "$state/domains.json" >/dev/null

# 13. Secret-bearing files stay private and a corrupt rule can't be clobbered
#     by an enable/disable read-modify-write.
run_env "$plugin_dir/bin/omaflow" webhooks add perms-check https://example.com/x json >/dev/null
[[ $(stat -c '%a' "$test_root/config/omaflow/webhooks.json") == 600 ]]
echo 'not json' >"$rules_dir/broken.json"
if run_env "$plugin_dir/bin/omaflow" disable broken 2>/dev/null; then
  echo "disable of corrupt rule unexpectedly succeeded" >&2
  exit 1
fi
[[ $(cat "$rules_dir/broken.json") == "not json" ]]

# A structurally invalid rule (valid JSON, wrong shapes) must not crash
# indexing: the list still renders, showing the malformed rule inertly.
echo '{"id":"mangled","actions":"oops","trigger":"nope","enabled":"yes"}' >"$rules_dir/mangled.json"
listing=$(run_env "$plugin_dir/bin/omaflow" list)
grep -q '○ mangled' <<<"$listing"
rm -f "$rules_dir/mangled.json" "$rules_dir/broken.json"

# 14. A vanished mains probe preserves battery state instead of fabricating
#     an AC transition; the state survives in domains.json unchanged.
run_env jq -e '.onAc == false' "$state/domains.json" >/dev/null
mv "$test_root/power/AC/type" "$test_root/power/AC/type.hidden"
: >"$calls"
run_env "$plugin_dir/bin/omaflow-eval" test
! grep -q 'setDnd' "$calls"
run_env jq -e '.onAc == false' "$state/domains.json" >/dev/null
mv "$test_root/power/AC/type.hidden" "$test_root/power/AC/type"

# 15. interval trigger: fires on a minute tick when enough time has passed
#     since the rule last fired, and stays quiet inside the interval. The
#     stored minute is rewound to force tick events without waiting.
cat >"$rules_dir/eye-timer.json" <<'EOF'
{
  "schemaVersion": 1, "id": "eye-timer", "name": "Eye timer", "enabled": true,
  "trigger": {"type": "interval", "minutes": 20},
  "actions": [{"type": "notify", "message": "eyes"}], "cooldownSeconds": 0, "source": "test"
}
EOF
rewind_minute() {
  run_env jq -c '.minute = "00:00"' "$state/domains.json" >"$state/domains.json.tmp"
  mv "$state/domains.json.tmp" "$state/domains.json"
}
: >"$calls"
rewind_minute
run_env "$plugin_dir/bin/omaflow-eval" test
grep -q 'omarchy-notification-send.*eyes' "$calls"
: >"$calls"
rewind_minute
run_env "$plugin_dir/bin/omaflow-eval" test
! grep -q 'omarchy-notification-send.*eyes' "$calls"
run_env jq -c '.["eye-timer"].lastFiredEpoch = (.["eye-timer"].lastFiredEpoch - 1300)' "$state/cooldowns.json" >"$state/cooldowns.json.tmp"
mv "$state/cooldowns.json.tmp" "$state/cooldowns.json"
: >"$calls"
rewind_minute
run_env "$plugin_dir/bin/omaflow-eval" test
grep -q 'omarchy-notification-send.*eyes' "$calls"
run_env "$plugin_dir/bin/omaflow" delete eye-timer >/dev/null

# 16. Lid transitions run only the corresponding allowlisted fingerprint
#     script, and a missing lid probe preserves the last state without firing.
cat >"$rules_dir/lid-close-fingerprint.json" <<'EOF'
{
  "schemaVersion": 1, "id": "lid-close-fingerprint", "name": "Disable fingerprint when closed", "enabled": true,
  "trigger": {"type": "lid-closed"},
  "actions": [{"type": "script", "name": "lock-fingerprint-disable"}], "cooldownSeconds": 0, "source": "test"
}
EOF
cat >"$rules_dir/lid-open-fingerprint.json" <<'EOF'
{
  "schemaVersion": 1, "id": "lid-open-fingerprint", "name": "Enable fingerprint when open", "enabled": true,
  "trigger": {"type": "lid-opened"},
  "actions": [{"type": "script", "name": "lock-fingerprint-enable"}], "cooldownSeconds": 0, "source": "test"
}
EOF
cat >"$rules_dir/lid-condition-match.json" <<'EOF'
{
  "schemaVersion": 1, "id": "lid-condition-match", "name": "Closed lid condition", "enabled": true,
  "trigger": {"type": "lid-closed"}, "conditions": [{"type": "lid-state", "state": "closed"}],
  "actions": [{"type": "notify", "message": "lid-condition-matched"}], "cooldownSeconds": 0, "source": "test"
}
EOF
cat >"$rules_dir/lid-condition-miss.json" <<'EOF'
{
  "schemaVersion": 1, "id": "lid-condition-miss", "name": "Open lid condition", "enabled": true,
  "trigger": {"type": "lid-closed"}, "conditions": [{"type": "lid-state", "state": "open"}],
  "actions": [{"type": "notify", "message": "lid-condition-missed"}], "cooldownSeconds": 0, "source": "test"
}
EOF
: >"$calls"
echo 'state: closed' >"$test_root/lid/LID0/state"
run_env "$plugin_dir/bin/omaflow-eval" lid
grep -q 'omarchy-shell lock setFingerprintEnabled off' "$calls"
! grep -q 'setFingerprintEnabled on' "$calls"
grep -q 'omarchy-notification-send.*lid-condition-matched' "$calls"
! grep -q 'lid-condition-missed' "$calls"
run_env jq -e '.lidClosed == true' "$state/domains.json" >/dev/null
cat >"$rules_dir/mixed-revert.json" <<'EOF'
{
  "schemaVersion": 1, "id": "mixed-revert", "name": "Mixed revert", "enabled": true,
  "trigger": {"type": "manual"},
  "actions": [{"type": "theme", "name": "work-theme"}, {"type": "script", "name": "lock-fingerprint-disable"}],
  "cooldownSeconds": 0, "source": "test"
}
EOF
run_env "$plugin_dir/bin/omaflow-run" mixed-revert
mixed_exec_id=$(grep '"ruleId":"mixed-revert"' "$state/log.jsonl" | tail -1 | jq -r '.execId')
: >"$calls"
if run_env "$plugin_dir/bin/omaflow-run" --revert "$mixed_exec_id" 2>/dev/null; then
  echo "mixed irreversible execution unexpectedly reported a full revert" >&2
  exit 1
fi
grep -q 'omarchy theme set old-theme' "$calls"
! grep -q 'setFingerprintEnabled on' "$calls"
run_env jq -e '.kind == "revert" and .status == "partial" and (.detail | test("script"))' \
  <(grep "\"execId\":\"$mixed_exec_id\"" "$state/log.jsonl" | tail -1) >/dev/null
mv "$test_root/lid/LID0/state" "$test_root/lid/LID0/state.hidden"
: >"$calls"
run_env "$plugin_dir/bin/omaflow-eval" lid
! grep -q 'setFingerprintEnabled' "$calls"
run_env jq -e '.lidClosed == true' "$state/domains.json" >/dev/null
mv "$test_root/lid/LID0/state.hidden" "$test_root/lid/LID0/state"
echo 'state: open' >"$test_root/lid/LID0/state"
: >"$calls"
run_env "$plugin_dir/bin/omaflow-eval" lid
grep -q 'omarchy-shell lock setFingerprintEnabled on' "$calls"
! grep -q 'setFingerprintEnabled off' "$calls"

# 17. Empty XDG variables mean unset, not the filesystem root.
XDG_STATE_HOME="" XDG_CONFIG_HOME="" HOME="$test_root" /usr/bin/ruby -r "$plugin_dir/lib/omaflow" -e '
  abort "empty XDG_STATE_HOME resolved to #{Omaflow::Paths.state_dir}" unless
    Omaflow::Paths.state_dir == File.join(Dir.home, ".local", "state", "omaflow")
  abort "empty XDG_CONFIG_HOME resolved to #{Omaflow::Paths.config_dir}" unless
    Omaflow::Paths.config_dir == File.join(Dir.home, ".config", "omaflow")
'

echo "test-eval: ok"
