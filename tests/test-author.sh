#!/bin/bash

# Authoring pipeline with a fake agent: backend resolution order, JSON
# extraction from chatty output, the self-repair retry, and stage accept.

set -euo pipefail
trap 'echo "$0: FAILED at line $LINENO" >&2' ERR

plugin_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT

fake_bin="$test_root/bin"
mkdir -p "$fake_bin" "$test_root/config/omarchy/defaults" "$test_root/state"

# Fake codex: first call returns an INVALID rule wrapped in prose, second call
# (the self-repair retry) returns a valid one. Counts calls and records its
# working directory so the empty-scratch isolation guarantee is verifiable.
cat >"$fake_bin/codex" <<'EOF'
#!/bin/bash
count_file="$TEST_ROOT/codex-calls"
count=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 ))
echo "$count" >"$count_file"
echo "cwd=$PWD files=$(ls -A | wc -l)" >>"$TEST_ROOT/codex-cwd.log"
out=""
prev=""
for arg in "$@"; do
  [[ $prev == "--output-last-message" ]] && out=$arg
  prev=$arg
done
if (( count == 1 )); then
  answer='Sure! Here is the rule: {"id":"quiet-mode","name":"Quiet mode","enabled":true,"trigger":{"type":"nonsense"},"actions":[{"type":"dnd","state":"on"}]}'
else
  answer='{"id":"quiet-mode","name":"Quiet mode","enabled":true,"trigger":{"type":"wifi-connected","match":{"known":false}},"actions":[{"type":"dnd","state":"on"},{"type":"notify","message":"New network - DND enabled"}],"cooldownSeconds":120}'
fi
[[ -n $out ]] && printf '%s' "$answer" >"$out"
EOF
chmod +x "$fake_bin/codex"

# Fakes for inventory gathering.
for cmd in hyprctl nmcli pactl omarchy omarchy-shell omarchy-notification-send; do
  printf '#!/bin/bash\nif [[ "$*" == *"theme list"* ]]; then echo default-theme; elif [[ "$*" == *"-j"* || "$*" == *json* ]]; then echo "[]"; fi\n' >"$fake_bin/$cmd"
  chmod +x "$fake_bin/$cmd"
done

echo codex >"$test_root/config/omarchy/defaults/agent"

run_env() {
  TEST_ROOT="$test_root" \
  HOME="$test_root" \
  XDG_CONFIG_HOME="$test_root/config" \
  XDG_STATE_HOME="$test_root/state" \
  PATH="$fake_bin:/usr/bin:/bin" \
    "$@"
}

state="$test_root/state/omaflow"

# Author: invalid first output triggers exactly one retry, then stages ready.
run_env "$plugin_dir/bin/omaflow-author" "when I join an unknown wifi, enable dnd"
[[ $(cat "$test_root/codex-calls") == 2 ]]
run_env jq -e '
  .status == "ready"
  and .agent == "codex"
  and .rule.trigger.type == "wifi-connected"
  and .rule.schemaVersion == 1
  and .rule.createdBy == "codex"
  and .rule.source == "when I join an unknown wifi, enable dnd"
' "$state/staging.json" >/dev/null

# Each agent invocation ran in its own empty scratch directory under the
# state dir, and the directories are gone afterwards.
[[ $(wc -l <"$test_root/codex-cwd.log") == 2 ]]
[[ $(grep -c 'files=0' "$test_root/codex-cwd.log") == 2 ]]
[[ $(grep -oE 'cwd=[^ ]+' "$test_root/codex-cwd.log" | sort -u | wc -l) == 2 ]]
grep -qE "cwd=$test_root/state/omaflow/.agent-cwd" "$test_root/codex-cwd.log"
[[ -z $(find "$test_root/state/omaflow" -maxdepth 1 -type d -name '.agent-cwd*' 2>/dev/null) ]]

# Accept installs the rule and reindexes.
run_env "$plugin_dir/bin/omaflow" stage accept | grep -q "Installed rule: quiet-mode"
[[ -f $test_root/config/omaflow/rules/quiet-mode.json ]]
[[ ! -f $state/staging.json ]]
run_env jq -e '.rules | length == 1 and .[0].id == "quiet-mode"' "$state/index.json" >/dev/null

# CLI surface: list, disable, enable.
run_env "$plugin_dir/bin/omaflow" list | grep -q "quiet-mode"
run_env "$plugin_dir/bin/omaflow" disable quiet-mode >/dev/null
run_env jq -e '.enabled == false' "$test_root/config/omaflow/rules/quiet-mode.json" >/dev/null
run_env "$plugin_dir/bin/omaflow" enable quiet-mode >/dev/null

# Agent resolution: omaflow config beats the omarchy default.
printf '#!/bin/bash\nif [[ $1 == -p ]]; then printf "%%s" "$2" >/dev/null; echo "{}"; fi\n' >"$fake_bin/grok"
chmod +x "$fake_bin/grok"
run_env "$plugin_dir/bin/omaflow" agent grok >/dev/null
out=$(run_env "$plugin_dir/bin/omaflow" agent)
grep -q "resolved: grok" <<<"$out"
run_env "$plugin_dir/bin/omaflow" agent auto >/dev/null
out=$(run_env "$plugin_dir/bin/omaflow" agent)
grep -q "resolved: codex" <<<"$out"

echo "test-author: ok"
