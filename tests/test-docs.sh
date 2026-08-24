#!/bin/bash

# The authoring agent only knows what omaflow-author's schema doc tells it.
# This test pins the executor, the validator, and that schema doc to one
# vocabulary, so a new type can't ship half-wired (runnable but unknown to
# the agent, or advertised but rejected).

set -euo pipefail
plugin_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

expected_actions="theme dnd nightlight stay-awake launch workspace audio-output webhook notify"
expected_triggers="manual time monitor-connected monitor-disconnected wifi-connected wifi-disconnected power-source"
expected_conditions="time-between weekday on-power monitor-present on-ssid"

# The executor's case labels are the ground truth for what actually runs.
run_actions=$(grep -oE '^  [a-z][a-z-]*( \| [a-z][a-z-]*)*\)$' "$plugin_dir/bin/omaflow-run" |
  tr -d ') ' | tr '|' '\n' | sort)
if [[ "$(tr ' ' '\n' <<<"$expected_actions" | sort)" != "$run_actions" ]]; then
  echo "executor action types drifted from the expected list — update test-docs.sh AND every file below:" >&2
  diff <(tr ' ' '\n' <<<"$expected_actions" | sort) <(printf '%s\n' "$run_actions") >&2 || true
  exit 1
fi

check_everywhere() { # kind, types...
  local kind="$1" t
  shift
  for t in "$@"; do
    grep -q "\"type\":\"$t\"" "$plugin_dir/bin/omaflow-author" ||
      { echo "$kind '$t' missing from the authoring schema doc (omaflow-author)" >&2; exit 1; }
    grep -qE "(^|[ |])$t( \||\))" "$plugin_dir/bin/omaflow-validate" ||
      { echo "$kind '$t' missing from the validator (omaflow-validate)" >&2; exit 1; }
  done
}
# shellcheck disable=SC2086
check_everywhere action $expected_actions
# shellcheck disable=SC2086
check_everywhere trigger $expected_triggers
# shellcheck disable=SC2086
check_everywhere condition $expected_conditions

echo "test-docs: ok"
