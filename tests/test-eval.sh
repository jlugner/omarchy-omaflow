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
make_fake hyprctl 'if [[ -n ${TEST_HYPRCTL_FAIL:-} ]]; then exit 1; fi; if [[ $1 == monitors ]]; then cat "$TEST_MONITORS"; elif [[ $1 == clients ]]; then cat "$TEST_CLIENTS"; fi'
make_fake nmcli 'if [[ $1 == -t ]]; then cat "$TEST_WIFI"; fi'
make_fake omarchy 'if [[ $1 == theme && $2 == current ]]; then echo old-theme; elif [[ $1 == theme && $2 == list ]]; then printf "old-theme\nwork-theme\nbroken-theme\n"; fi'
make_fake omarchy-shell 'case "$2" in dndState) echo off ;; status) echo "{\"stayAwake\":false}" ;; fingerprintControlAvailable) echo true ;; *) echo ok ;; esac'
make_fake pactl 'if [[ $1 == get-default-sink ]]; then echo old-sink; elif [[ $* == *"list sinks"* ]]; then echo "[{\"name\":\"dock-sink\",\"description\":\"Dock Audio\"}]"; fi'
make_fake omarchy-notification-send 'true'
make_fake gtk-launch 'true'

export TEST_MONITORS="$test_root/monitors.json"
export TEST_CLIENTS="$test_root/clients.json"
export TEST_WIFI="$test_root/wifi.txt"
echo '[{"name":"eDP-1","description":"Laptop Screen"}]' >"$TEST_MONITORS"
echo '[{"address":"0x1","class":"kitty","title":"Terminal"}]' >"$TEST_CLIENTS"
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

cat >"$rules_dir/custom-deploy.json" <<'EOF'
{
  "schemaVersion": 1, "id": "custom-deploy", "name": "Custom deploy", "enabled": true,
  "trigger": {"type": "custom", "name": "deploy-done"},
  "actions": [{"type": "notify", "message": "deployed {{env}}x{{missing}}end"}], "cooldownSeconds": 0, "source": "test"
}
EOF
: >"$calls"
run_env "$plugin_dir/bin/omaflow" trigger deploy-done env=prod
grep -q 'omarchy-notification-send.*deployed prodxend' "$calls"
[[ $(stat -c '%a' "$state/inbox") == 700 ]]
[[ -z $(find "$state/inbox" -mindepth 1 -maxdepth 1 ! -name '.*' -print -quit) ]]
: >"$calls"
run_env "$plugin_dir/bin/omaflow" trigger another-event env=stage
! grep -q 'omarchy-notification-send.*deployed' "$calls"
[[ -z $(find "$state/inbox" -mindepth 1 -maxdepth 1 ! -name '.*' -print -quit) ]]
printf '{"name":"deploy-done"}' >"$state/inbox/garbage.json"
{
  printf '{"name":"deploy-done","data":{"env":"'
  head -c 20000 /dev/zero | tr '\0' x
  printf '"},"at":"now"}'
} >"$state/inbox/oversize.json"
: >"$calls"
run_env "$plugin_dir/bin/omaflow-eval" test
! grep -q 'omarchy-notification-send.*deployed' "$calls"
[[ -z $(find "$state/inbox" -mindepth 1 -maxdepth 1 ! -name '.*' -print -quit) ]]
if run_env "$plugin_dir/bin/omaflow" trigger Bad-Name env=prod 2>/dev/null; then
  echo "bad custom event name unexpectedly accepted" >&2
  exit 1
fi
if run_env "$plugin_dir/bin/omaflow" trigger deploy-done -env=prod 2>/dev/null; then
  echo "bad custom event data unexpectedly accepted" >&2
  exit 1
fi
reserved_status=0
run_env "$plugin_dir/bin/omaflow" trigger deploy-done name=spoofed >/dev/null 2>&1 || reserved_status=$?
[[ $reserved_status == 2 ]]
[[ -z $(find "$state/inbox" -mindepth 1 -maxdepth 1 ! -name '.*' -print -quit) ]]

cat >"$rules_dir/custom-spoofed.json" <<'EOF'
{
  "schemaVersion": 1, "id": "custom-spoofed", "name": "Custom spoofed", "enabled": true,
  "trigger": {"type": "custom", "name": "spoofed"},
  "actions": [{"type": "notify", "message": "spoofed-event-fired"}], "cooldownSeconds": 0, "source": "test"
}
EOF
printf '%s\n' '{"name":"deploy-done","data":{"name":"spoofed","env":"crafted"},"at":"2026-08-24T12:00:00Z"}' \
  >"$state/inbox/envelope.json"
: >"$calls"
run_env "$plugin_dir/bin/omaflow-eval" custom
grep -q 'omarchy-notification-send.*deployed craftedxend' "$calls"
! grep -q 'spoofed-event-fired' "$calls"
run_env jq -e '.trigger | contains("name=deploy-done") and contains("at=2026-08-24T12:00:00Z")' \
  <(grep '"ruleId":"custom-deploy"' "$state/log.jsonl" | tail -1) >/dev/null

for number in $(seq -w 1 25); do
  printf '{"name":"deploy-done","data":{"env":"fair-%s"},"at":"2026-08-24T12:00:00Z"}\n' "$number" \
    >"$state/inbox/fair-$number.json"
done
: >"$calls"
run_env "$plugin_dir/bin/omaflow-eval" custom
[[ $(grep -c 'omarchy-notification-send.*deployed fair-' "$calls") == 20 ]]
[[ $(find "$state/inbox" -mindepth 1 -maxdepth 1 ! -name '.*' -type f | wc -l) == 5 ]]
run_env "$plugin_dir/bin/omaflow-eval" custom
[[ $(grep -c 'omarchy-notification-send.*deployed fair-' "$calls") == 25 ]]
[[ -z $(find "$state/inbox" -mindepth 1 -maxdepth 1 ! -name '.*' -print -quit) ]]

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

cat >"$rules_dir/wifi-hook.json" <<'EOF'
{
  "schemaVersion": 1, "id": "wifi-hook", "name": "WiFi hook", "enabled": true,
  "trigger": {"type": "wifi-connected", "match": {"ssid": "*"}},
  "actions": [{"type": "webhook", "endpoint": "team-slack", "message": "WiFi: {{ssid}}/{{missing}}"}],
  "cooldownSeconds": 0, "source": "test"
}
EOF
echo 'yes:OfficeWifi' >"$TEST_WIFI"
: >"$calls"
run_env "$plugin_dir/bin/omaflow-eval" wifi
grep -q -- '--data-raw {"text":"WiFi: OfficeWifi/"}' "$calls"

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

cat >"$rules_dir/app-opened.json" <<'EOF'
{
  "schemaVersion": 1, "id": "app-opened", "name": "App opened", "enabled": true,
  "trigger": {"type": "app-opened", "match": {"class": "SLACK"}},
  "actions": [{"type": "notify", "message": "opened {{class}} {{title}}"}], "cooldownSeconds": 0, "source": "test"
}
EOF
cat >"$rules_dir/app-closed.json" <<'EOF'
{
  "schemaVersion": 1, "id": "app-closed", "name": "App closed", "enabled": true,
  "trigger": {"type": "app-closed", "match": {"title": "team chat"}},
  "actions": [{"type": "notify", "message": "closed {{class}} {{title}}"}], "cooldownSeconds": 0, "source": "test"
}
EOF
cat >"$rules_dir/class-only-zoom.json" <<'EOF'
{
  "schemaVersion": 1, "id": "class-only-zoom", "name": "Class only zoom", "enabled": true,
  "trigger": {"type": "app-opened", "match": {"class": "zoom"}},
  "actions": [{"type": "notify", "message": "class-only-zoom-fired"}], "cooldownSeconds": 0, "source": "test"
}
EOF
echo '[{"address":"0x1","class":"kitty","title":"Terminal"},{"address":"0x2","class":"com.slack.Slack","title":"Team Chat"},{"address":"0x3","class":"editor","title":"Zoom notes"}]' >"$TEST_CLIENTS"
: >"$calls"
run_env "$plugin_dir/bin/omaflow-eval" windows
grep -q 'omarchy-notification-send.*opened com.slack.Slack Team Chat' "$calls"
! grep -q 'class-only-zoom-fired' "$calls"
run_env jq -e '.windows | length == 3' "$state/domains.json" >/dev/null

echo '[{"address":"0x1","class":"kitty","title":"Terminal"}]' >"$TEST_CLIENTS"
: >"$calls"
TEST_HYPRCTL_FAIL=1 run_env "$plugin_dir/bin/omaflow-eval" windows
! grep -q 'omarchy-notification-send.*closed' "$calls"
run_env jq -e '.windows | length == 3 and .[1].title == "Team Chat"' "$state/domains.json" >/dev/null
run_env "$plugin_dir/bin/omaflow-eval" windows
grep -q 'omarchy-notification-send.*closed com.slack.Slack Team Chat' "$calls"

cat >"$rules_dir/window-storm.json" <<'EOF'
{
  "schemaVersion": 1, "id": "window-storm", "name": "Window storm", "enabled": true,
  "trigger": {"type": "app-opened", "match": {"class": "storm"}},
  "actions": [{"type": "notify", "message": "storm {{title}}"}], "cooldownSeconds": 0, "source": "test"
}
EOF
{
  printf '[{"address":"0x1","class":"kitty","title":"Terminal"}'
  for number in $(seq 1 100); do
    printf ',{"address":"0xstorm%s","class":"storm-app","title":"Storm %s"}' "$number" "$number"
  done
  printf ']\n'
} >"$TEST_CLIENTS"
: >"$calls"
run_env "$plugin_dir/bin/omaflow-eval" windows
! grep -q 'omarchy-notification-send.*storm' "$calls"
run_env jq -e '.windows | length == 1 and .[0].address == "0x1"' "$state/domains.json" >/dev/null

{
  printf '[{"address":"0x1","class":"kitty","title":"Terminal"}'
  for number in $(seq 1 12); do
    printf ',{"address":"0xstorm%s","class":"storm-app","title":"Storm %s"}' "$number" "$number"
  done
  printf ']\n'
} >"$TEST_CLIENTS"
: >"$calls"
run_env "$plugin_dir/bin/omaflow-eval" windows
! grep -q 'omarchy-notification-send.*storm' "$calls"
run_env jq -e '.windows | length == 13' "$state/domains.json" >/dev/null

echo '[{"address":"0x1","class":"kitty","title":"Terminal"}]' >"$TEST_CLIENTS"
run_env "$plugin_dir/bin/omaflow-eval" windows
cat >"$rules_dir/clean-title.json" <<'EOF'
{
  "schemaVersion": 1, "id": "clean-title", "name": "Clean title", "enabled": true,
  "trigger": {"type": "app-opened", "match": {"title": "Alert"}},
  "actions": [{"type": "notify", "message": "clean {{title}}"}], "cooldownSeconds": 0, "source": "test"
}
EOF
printf '%s\n' '[{"address":"0x1","class":"kitty","title":"Terminal"},{"address":"0xescape","class":"safe\u001bclass","title":"Alert\u001b[31m"}]' >"$TEST_CLIENTS"
: >"$calls"
run_env "$plugin_dir/bin/omaflow-eval" windows
grep -q 'omarchy-notification-send.*clean Alert\[31m' "$calls"
run_env jq -e '.windows[1].class == "safeclass" and .windows[1].title == "Alert[31m"' "$state/domains.json" >/dev/null
! grep -Fq '\u001b' "$state/domains.json"
! grep -Fq '\u001b' <(grep '"ruleId":"clean-title"' "$state/log.jsonl")
if LC_ALL=C grep -q $'\033' "$state/domains.json" <(grep '"ruleId":"clean-title"' "$state/log.jsonl"); then
  echo "control byte survived window ingestion" >&2
  exit 1
fi

cat >"$rules_dir/app-running-interval.json" <<'EOF'
{
  "schemaVersion": 1, "id": "app-running-interval", "name": "App running interval", "enabled": true,
  "trigger": {"type": "interval", "minutes": 1},
  "conditions": [{"type": "app-running", "match": {"title": "Project Focus"}}],
  "actions": [{"type": "notify", "message": "focus-app-running"}], "cooldownSeconds": 0, "source": "test"
}
EOF
echo '[{"address":"0x1","class":"kitty","title":"Terminal"}]' >"$TEST_CLIENTS"
: >"$calls"
rewind_minute
run_env "$plugin_dir/bin/omaflow-eval" windows
! grep -q 'focus-app-running' "$calls"
echo '[{"address":"0x1","class":"kitty","title":"Terminal"},{"address":"0xfocus","class":"editor","title":"Project Focus"}]' >"$TEST_CLIENTS"
rewind_minute
run_env "$plugin_dir/bin/omaflow-eval" windows
grep -q 'omarchy-notification-send.*focus-app-running' "$calls"
run_env jq -c '.["app-running-interval"].lastFiredEpoch -= 120' "$state/cooldowns.json" >"$state/cooldowns.json.tmp"
mv "$state/cooldowns.json.tmp" "$state/cooldowns.json"
: >"$calls"
rewind_minute
TEST_HYPRCTL_FAIL=1 run_env "$plugin_dir/bin/omaflow-eval" windows
! grep -q 'focus-app-running' "$calls"
run_env jq -e '.windows | any(.title == "Project Focus")' "$state/domains.json" >/dev/null
echo '[{"address":"0x1","class":"kitty","title":"Terminal"}]' >"$TEST_CLIENTS"
: >"$calls"
rewind_minute
run_env "$plugin_dir/bin/omaflow-eval" windows
! grep -q 'focus-app-running' "$calls"

monitors_before=$(run_env jq -c '.monitors' "$state/domains.json")
/usr/bin/ruby -r json -e 'puts JSON.generate(17.times.map { |number| { "name" => "DP-#{number}", "description" => "Monitor #{number}" } })' \
  >"$TEST_MONITORS"
: >"$calls"
run_env "$plugin_dir/bin/omaflow-eval" monitors
[[ $(run_env jq -c '.monitors' "$state/domains.json") == "$monitors_before" ]]
printf '%s\n' '[{"name":"DP-1","description":42}]' >"$TEST_MONITORS"
run_env "$plugin_dir/bin/omaflow-eval" monitors
[[ $(run_env jq -c '.monitors' "$state/domains.json") == "$monitors_before" ]]
/usr/bin/ruby -r json -e 'puts JSON.generate([{ "name" => "DP-\e1", "description" => ("d" * 130) + "\n" }])' \
  >"$TEST_MONITORS"
run_env "$plugin_dir/bin/omaflow-eval" monitors
run_env jq -e '.monitors[0].name == "DP-1" and (.monitors[0].description | length) == 120' "$state/domains.json" >/dev/null
! grep -Fq '\u001b' "$state/domains.json"

# 18. A watched directory is baselined before a new file fires with name and
#     path template values.
watched_dir="$test_root/watched"
mkdir -p "$watched_dir"
cat >"$rules_dir/file-created.json" <<'EOF'
{
  "schemaVersion": 1, "id": "file-created", "name": "File created", "enabled": true,
  "trigger": {"type": "file-created", "path": "~/watched"},
  "actions": [{"type": "notify", "message": "file {{name}} at {{path}}"}], "cooldownSeconds": 0, "source": "test"
}
EOF
cat >"$rules_dir/folder-created.json" <<'EOF'
{
  "schemaVersion": 1, "id": "folder-created", "name": "Folder created", "enabled": true,
  "trigger": {"type": "folder-created", "path": "~/watched"},
  "actions": [{"type": "notify", "message": "folder {{name}} at {{path}}"}], "cooldownSeconds": 0, "source": "test"
}
EOF
run_env "$plugin_dir/bin/omaflow-eval" files
run_env jq -e --arg dir "$watched_dir" '.dirs == [$dir]' "$state/watched-dirs.json" >/dev/null
: >"$calls"
touch "$watched_dir/report.txt"
run_env "$plugin_dir/bin/omaflow-eval" files
grep -q "omarchy-notification-send.*file report.txt at $watched_dir" "$calls"

# 19. A newly created directory emits only folder-created.
: >"$calls"
mkdir "$watched_dir/project"
run_env "$plugin_dir/bin/omaflow-eval" files
grep -q "omarchy-notification-send.*folder project at $watched_dir" "$calls"
! grep -Fq "omarchy-notification-send file project" "$calls"

# 20. Dot-files never enter the directory snapshot or emit events.
: >"$calls"
touch "$watched_dir/.partial"
run_env "$plugin_dir/bin/omaflow-eval" files
! grep -q 'omarchy-notification-send.*partial' "$calls"
run_env jq -e --arg key "files:$watched_dir" '.[$key] | all(.name != ".partial")' "$state/domains.json" >/dev/null

# 21. A bulk addition advances the snapshot without firing, then a later
#     single addition fires normally.
: >"$calls"
for number in $(seq 1 12); do
  touch "$watched_dir/bulk-$number"
done
run_env "$plugin_dir/bin/omaflow-eval" files
! grep -q 'omarchy-notification-send.*bulk-' "$calls"
run_env jq -e --arg key "files:$watched_dir" '.[$key] | map(select(.name | startswith("bulk-"))) | length == 12' \
  "$state/domains.json" >/dev/null
: >"$calls"
touch "$watched_dir/after-bulk.txt"
run_env "$plugin_dir/bin/omaflow-eval" files
grep -q "omarchy-notification-send.*file after-bulk.txt at $watched_dir" "$calls"

# 22. match.name filters case-insensitively by substring.
cat >"$rules_dir/pdf-created.json" <<'EOF'
{
  "schemaVersion": 1, "id": "pdf-created", "name": "PDF created", "enabled": true,
  "trigger": {"type": "file-created", "path": "~/watched", "match": {"name": ".pdf"}},
  "actions": [{"type": "notify", "message": "matched {{name}}"}], "cooldownSeconds": 0, "source": "test"
}
EOF
: >"$calls"
touch "$watched_dir/ignored.txt"
run_env "$plugin_dir/bin/omaflow-eval" files
! grep -q 'omarchy-notification-send.*matched' "$calls"
: >"$calls"
touch "$watched_dir/Invoice.PDF"
run_env "$plugin_dir/bin/omaflow-eval" files
grep -q 'omarchy-notification-send.*matched Invoice.PDF' "$calls"

# 23. Only the first eight sorted unique enabled-rule paths are watched.
rm -f "$rules_dir/file-created.json" "$rules_dir/folder-created.json" "$rules_dir/pdf-created.json"
for number in $(seq 1 9); do
  mkdir -p "$test_root/limit-$number"
  cat >"$rules_dir/limit-$number.json" <<EOF
{
  "schemaVersion": 1, "id": "limit-$number", "name": "Limit $number", "enabled": true,
  "trigger": {"type": "file-created", "path": "~/limit-$number"},
  "actions": [{"type": "notify", "message": "limit-$number {{name}}"}], "cooldownSeconds": 0, "source": "test"
}
EOF
done
run_env "$plugin_dir/bin/omaflow-eval" files
run_env jq -e --arg ninth "$test_root/limit-9" '.dirs | length == 8 and index($ninth) == null' \
  "$state/watched-dirs.json" >/dev/null
: >"$calls"
touch "$test_root/limit-9/not-watched.txt"
run_env "$plugin_dir/bin/omaflow-eval" files
! grep -q 'omarchy-notification-send.*limit-9' "$calls"
run_env jq -e --arg key "files:$test_root/limit-9" 'has($key) | not' "$state/domains.json" >/dev/null

# 24. Exactly 512 children can baseline through bulk suppression; the 513th
#     makes that directory probe fail and preserves its prior snapshot.
: >"$calls"
for number in $(seq 1 512); do
  touch "$test_root/limit-1/entry-$number"
done
run_env "$plugin_dir/bin/omaflow-eval" files
run_env jq -e --arg key "files:$test_root/limit-1" '.[$key] | length == 512' "$state/domains.json" >/dev/null
touch "$test_root/limit-1/entry-513"
run_env "$plugin_dir/bin/omaflow-eval" files
! grep -q 'omarchy-notification-send.*limit-1' "$calls"
run_env jq -e --arg key "files:$test_root/limit-1" '.[$key] | length == 512' "$state/domains.json" >/dev/null

for number in $(seq 1 9); do
  rm -f "$rules_dir/limit-$number.json"
done

git_repo="$test_root/repo"
git_file_watch="$test_root/git-file-watch"
mkdir -p "$git_file_watch"
git init -q "$git_repo"
printf 'baseline\n' >"$git_repo/tracked.txt"
git -C "$git_repo" add tracked.txt
git -C "$git_repo" -c user.name=Omaflow -c user.email=omaflow@example.com commit -qm baseline
base_branch=$(git -C "$git_repo" branch --show-current)
cat >"$rules_dir/git-branch.json" <<'EOF'
{
  "schemaVersion": 1, "id": "git-branch", "name": "Git branch", "enabled": true,
  "trigger": {"type": "git-branch-changed", "repo": "~/repo"},
  "actions": [{"type": "notify", "message": "branch {{branch}} from {{from}} repo {{repo}}"}],
  "cooldownSeconds": 0, "source": "test"
}
EOF
cat >"$rules_dir/git-branch-match.json" <<'EOF'
{
  "schemaVersion": 1, "id": "git-branch-match", "name": "Git branch match", "enabled": true,
  "trigger": {"type": "git-branch-changed", "repo": "~/repo", "match": {"branch": "FEATURE"}},
  "actions": [{"type": "notify", "message": "matched {{branch}}"}], "cooldownSeconds": 0, "source": "test"
}
EOF
cat >"$rules_dir/on-branch-manual.json" <<'EOF'
{
  "schemaVersion": 1, "id": "on-branch-manual", "name": "On branch manual", "enabled": true,
  "trigger": {"type": "manual"},
  "conditions": [{"type": "on-branch", "repo": "~/repo", "branch": "FEATURE"}],
  "actions": [{"type": "notify", "message": "manual feature"}], "cooldownSeconds": 0, "source": "test"
}
EOF
cat >"$rules_dir/git-file-created.json" <<'EOF'
{
  "schemaVersion": 1, "id": "git-file-created", "name": "Git file created", "enabled": true,
  "trigger": {"type": "file-created", "path": "~/git-file-watch"},
  "actions": [{"type": "notify", "message": "git file {{name}}"}], "cooldownSeconds": 0, "source": "test"
}
EOF
: >"$calls"
run_env "$plugin_dir/bin/omaflow-eval" files
! grep -q 'omarchy-notification-send.*branch' "$calls"
run_env jq -e --arg git_dir "$git_repo/.git" --arg file_dir "$git_file_watch" \
  '.dirs | index($git_dir) != null and index($file_dir) != null' "$state/watched-dirs.json" >/dev/null
run_env jq -e --arg key "files:$git_repo/.git" 'has($key) | not' "$state/domains.json" >/dev/null

git -C "$git_repo" checkout -qb feature
: >"$calls"
run_env "$plugin_dir/bin/omaflow-eval" files
grep -q "omarchy-notification-send.*branch feature from $base_branch repo $git_repo" "$calls"
grep -q 'omarchy-notification-send.*matched feature' "$calls"
: >"$calls"
run_env /usr/bin/ruby -r "$plugin_dir/lib/omaflow" -e '
  rule = Omaflow::Store.rules.find { it["id"] == "on-branch-manual" }
  evaluator = Omaflow::Evaluator.new("test")
  evaluator.instance_variable_set(:@rules, [rule])
  evaluator.instance_variable_set(:@current, Omaflow::Store.read_json(Omaflow::Paths.domains_file, {}))
  evaluator.send(:fire_matching_rules, { "type" => "manual", "data" => {} })
'
grep -q 'omarchy-notification-send.*manual feature' "$calls"

git -C "$git_repo" checkout -q "$base_branch"
: >"$calls"
run_env "$plugin_dir/bin/omaflow-eval" files
grep -q "omarchy-notification-send.*branch $base_branch from feature repo $git_repo" "$calls"
! grep -q 'omarchy-notification-send.*matched' "$calls"
: >"$calls"
run_env /usr/bin/ruby -r "$plugin_dir/lib/omaflow" -e '
  rule = Omaflow::Store.rules.find { it["id"] == "on-branch-manual" }
  evaluator = Omaflow::Evaluator.new("test")
  evaluator.instance_variable_set(:@rules, [rule])
  evaluator.instance_variable_set(:@current, Omaflow::Store.read_json(Omaflow::Paths.domains_file, {}))
  evaluator.send(:fire_matching_rules, { "type" => "manual", "data" => {} })
'
! grep -q 'omarchy-notification-send.*manual feature' "$calls"

git -C "$git_repo" checkout -q --detach HEAD
: >"$calls"
run_env "$plugin_dir/bin/omaflow-eval" files
grep -q "omarchy-notification-send.*branch detached from $base_branch repo $git_repo" "$calls"
run_env jq -e --arg key "git:$git_repo" '.[$key].branch == "detached"' "$state/domains.json" >/dev/null

cp "$git_repo/.git/HEAD" "$test_root/main-head"
head -c 5000 /dev/zero | tr '\0' x >"$git_repo/.git/HEAD"
: >"$calls"
run_env "$plugin_dir/bin/omaflow-eval" files
! grep -q 'omarchy-notification-send.*branch' "$calls"
run_env jq -e --arg key "git:$git_repo" '.[$key].branch == "detached"' "$state/domains.json" >/dev/null
mv "$test_root/main-head" "$git_repo/.git/HEAD"

git_worktree="$test_root/worktree"
git -C "$git_repo" worktree add -qb worktree-base "$git_worktree" "$base_branch"
cat >"$rules_dir/git-worktree.json" <<'EOF'
{
  "schemaVersion": 1, "id": "git-worktree", "name": "Git worktree", "enabled": true,
  "trigger": {"type": "git-branch-changed", "repo": "~/worktree"},
  "actions": [{"type": "notify", "message": "worktree {{branch}} from {{from}}"}],
  "cooldownSeconds": 0, "source": "test"
}
EOF
worktree_git_dir=$(sed -n 's/^gitdir: //p' "$git_worktree/.git")
: >"$calls"
run_env "$plugin_dir/bin/omaflow-eval" files
! grep -q 'omarchy-notification-send.*worktree' "$calls"
run_env jq -e --arg git_dir "$worktree_git_dir" '.dirs | index($git_dir) != null' "$state/watched-dirs.json" >/dev/null
run_env jq -e --arg key "files:$worktree_git_dir" 'has($key) | not' "$state/domains.json" >/dev/null

git -C "$git_worktree" checkout -qb worktree-feature
: >"$calls"
run_env "$plugin_dir/bin/omaflow-eval" files
grep -q 'omarchy-notification-send.*worktree worktree-feature from worktree-base' "$calls"

: >"$calls"
touch "$git_file_watch/report.txt"
run_env "$plugin_dir/bin/omaflow-eval" files
grep -q 'omarchy-notification-send.*git file report.txt' "$calls"
! grep -q 'omarchy-notification-send.*branch' "$calls"

echo "test-eval: ok"
