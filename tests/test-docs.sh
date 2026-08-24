#!/bin/bash

# The authoring agent only knows what Author::SCHEMA_DOC tells it. This test
# pins the vocabulary constants, the executor's handlers, the validator's
# checks, and the schema doc to one another, so a new type can't ship
# half-wired. The static list below forces a conscious update on any change.

set -euo pipefail
trap 'echo "$0: FAILED at line $LINENO" >&2' ERR
plugin_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT

expected="trigger manual
trigger time
trigger interval
trigger lid-opened
trigger lid-closed
trigger monitor-connected
trigger monitor-disconnected
trigger app-opened
trigger app-closed
trigger wifi-connected
trigger wifi-disconnected
trigger power-source
trigger custom
condition time-between
condition weekday
condition on-power
condition lid-state
condition monitor-present
condition app-running
condition on-ssid
action theme
action dnd
action nightlight
action stay-awake
action launch
action workspace
action audio-output
action script
action webhook
action notify"

actual=$(HOME="$test_root" XDG_CONFIG_HOME="$test_root/config" XDG_STATE_HOME="$test_root/state" \
  "$plugin_dir/bin/omaflow" vocabulary)
if [[ "$actual" != "$expected" ]]; then
  echo "vocabulary drifted from the expected list — update test-docs.sh AND every place below:" >&2
  diff <(echo "$expected") <(echo "$actual") >&2 || true
  exit 1
fi

/usr/bin/ruby -r "$plugin_dir/lib/omaflow" -e '
  vocab = Omaflow::Vocabulary
  abort "executor handlers != vocabulary actions" unless Omaflow::Executor::HANDLERS.keys.sort == vocab::ACTIONS.sort
  abort "executor snapshots reference unknown actions" unless (Omaflow::Executor::SNAPSHOTTED.keys - vocab::ACTIONS).empty?
  abort "validator action checks != vocabulary" unless Omaflow::Validator::ACTION_CHECKS.keys.sort == vocab::ACTIONS.sort
  abort "validator trigger checks != vocabulary" unless Omaflow::Validator::TRIGGER_CHECKS.keys.sort == vocab::TRIGGERS.sort
  abort "validator condition checks != vocabulary" unless Omaflow::Validator::CONDITION_CHECKS.keys.sort == vocab::CONDITIONS.sort
  doc = Omaflow::Author::SCHEMA_DOC
  (vocab::ACTIONS + vocab::TRIGGERS + vocab::CONDITIONS).each do |type|
    abort "#{type} missing from the authoring schema doc" unless doc.include?("\"type\":\"#{type}\"")
  end
'

grep -q 'gdbus.*org.freedesktop.UPower' "$plugin_dir/Service.qml"
! grep -q 'name === "switch"' "$plugin_dir/Service.qml"

echo "test-docs: ok"
