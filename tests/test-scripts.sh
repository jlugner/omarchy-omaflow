#!/bin/bash

set -euo pipefail
trap 'echo "$0: FAILED at line $LINENO" >&2' ERR

plugin_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d "$plugin_dir/.test-scripts.XXXXXX")
trap 'rm -rf "$test_root"' EXIT

fake_bin="$test_root/bin"
script_log="$test_root/script.log"
mkdir -p "$fake_bin" "$test_root/config" "$test_root/state" "$test_root/tools"

printf '#!/bin/bash\ntrue\n' >"$fake_bin/omarchy-notification-send"
cat >"$fake_bin/omarchy-shell" <<'EOF'
#!/bin/bash
if [[ $* == "lock fingerprintControlAvailable" ]]; then
  [[ -z ${OMAFLOW_LOCK_INCOMPATIBLE:-} ]] || exit 1
  echo true
else
  echo ok
fi
EOF
chmod +x "$fake_bin/omarchy-notification-send" "$fake_bin/omarchy-shell"

approved="$test_root/tools/refresh-desk"
cat >"$approved" <<'EOF'
#!/bin/bash
printf 'approved args=%s\n' "$#" >>"$OMAFLOW_TEST_LOG"
EOF
chmod 700 "$approved"

run_env() {
  HOME="$test_root" \
  XDG_CONFIG_HOME="$test_root/config" \
  XDG_STATE_HOME="$test_root/state" \
  OMAFLOW_TEST_LOG="$script_log" \
  PATH="$fake_bin:/usr/bin:/bin" \
    "$@"
}

listing=$(run_env "$plugin_dir/bin/omaflow" scripts list)
grep -q 'lock-fingerprint-enable.*built-in' <<<"$listing"
grep -q 'lock-fingerprint-disable.*built-in' <<<"$listing"

run_env "$plugin_dir/bin/omaflow" scripts add refresh-desk "$approved" "Refresh desk hardware" >/dev/null
scripts_file="$test_root/config/omaflow/scripts.json"
[[ $(stat -c '%a' "$scripts_file") == 600 ]]
run_env jq -e --arg path "$approved" '."refresh-desk".path == $path' "$scripts_file" >/dev/null
run_env "$plugin_dir/bin/omaflow" scripts list | grep -q 'refresh-desk.*user.*Refresh desk hardware'

rules_dir="$test_root/config/omaflow/rules"
mkdir -p "$rules_dir"
cat >"$rules_dir/approved-script.json" <<'EOF'
{
  "schemaVersion": 1, "id": "approved-script", "name": "Approved script", "enabled": true,
  "trigger": {"type": "manual"},
  "actions": [{"type": "script", "name": "refresh-desk"}], "cooldownSeconds": 0, "source": "test"
}
EOF
run_env "$plugin_dir/bin/omaflow-run" approved-script
grep -q '^approved args=0$' "$script_log"

cat >"$test_root/injected.json" <<'EOF'
{
  "schemaVersion": 1, "id": "injected", "name": "Injected", "enabled": true,
  "trigger": {"type": "manual"},
  "actions": [{"type": "script", "name": "refresh-desk", "path": "/bin/sh", "args": ["-c", "false"]}],
  "source": "test"
}
EOF
if run_env "$plugin_dir/bin/omaflow-validate" "$test_root/injected.json" >"$test_root/injected.out"; then
  echo "rule-supplied script command unexpectedly validated" >&2
  exit 1
fi
grep -q 'unknown field in script action: path, args' "$test_root/injected.out"

unsafe="$test_root/tools/unsafe"
printf '#!/bin/bash\ntrue\n' >"$unsafe"
chmod 777 "$unsafe"
if run_env "$plugin_dir/bin/omaflow" scripts add unsafe "$unsafe" 2>/dev/null; then
  echo "world-writable script unexpectedly allowed" >&2
  exit 1
fi
unsafe_dir="$test_root/unsafe-dir"
mkdir "$unsafe_dir"
chmod 777 "$unsafe_dir"
ln "$approved" "$unsafe_dir/hardlink"
if run_env "$plugin_dir/bin/omaflow" scripts add unsafe-parent "$unsafe_dir/hardlink" 2>"$test_root/unsafe-parent.out"; then
  echo "script in a writable directory unexpectedly allowed" >&2
  exit 1
fi
grep -q 'chmod go-w' "$test_root/unsafe-parent.out"
unsafe_ancestor="$test_root/unsafe-ancestor"
mkdir -p "$unsafe_ancestor/safe-child"
cp "$approved" "$unsafe_ancestor/safe-child/script"
chmod 700 "$unsafe_ancestor/safe-child" "$unsafe_ancestor/safe-child/script"
chmod 775 "$unsafe_ancestor"
if run_env "$plugin_dir/bin/omaflow" scripts add unsafe-ancestor "$unsafe_ancestor/safe-child/script" 2>/dev/null; then
  echo "script below a writable ancestor unexpectedly allowed" >&2
  exit 1
fi
sticky_ancestor="$test_root/sticky-ancestor"
mkdir -p "$sticky_ancestor/safe-child"
cp "$approved" "$sticky_ancestor/safe-child/script"
chmod 700 "$sticky_ancestor/safe-child" "$sticky_ancestor/safe-child/script"
chmod 1777 "$sticky_ancestor"
run_env "$plugin_dir/bin/omaflow" scripts add sticky-ok "$sticky_ancestor/safe-child/script" >/dev/null
run_env "$plugin_dir/bin/omaflow" scripts remove sticky-ok >/dev/null
if run_env "$plugin_dir/bin/omaflow" scripts add relative refresh-desk 2>/dev/null; then
  echo "relative script path unexpectedly allowed" >&2
  exit 1
fi
if run_env "$plugin_dir/bin/omaflow" scripts remove lock-fingerprint-enable 2>/dev/null; then
  echo "built-in script unexpectedly removed" >&2
  exit 1
fi

if run_env "$plugin_dir/bin/omaflow" scripts remove refresh-dsek 2>/dev/null; then
  echo "misspelled script removal unexpectedly succeeded" >&2
  exit 1
fi
run_env jq -e 'has("refresh-desk")' "$scripts_file" >/dev/null
run_env "$plugin_dir/bin/omaflow" scripts remove refresh-desk >/dev/null
if run_env "$plugin_dir/bin/omaflow-run" approved-script 2>/dev/null; then
  echo "removed script unexpectedly ran" >&2
  exit 1
fi

compat_rule="$test_root/fingerprint.json"
cat >"$compat_rule" <<'EOF'
{
  "schemaVersion": 1, "id": "fingerprint", "name": "Fingerprint", "enabled": true,
  "trigger": {"type": "manual"},
  "actions": [{"type": "script", "name": "lock-fingerprint-enable"}], "source": "test"
}
EOF
if run_env env OMAFLOW_LOCK_INCOMPATIBLE=1 "$plugin_dir/bin/omaflow-validate" "$compat_rule" >"$test_root/compat.out"; then
  echo "incompatible fingerprint service unexpectedly validated" >&2
  exit 1
fi
grep -q 'requires a compatible service' "$test_root/compat.out"
run_env env OMAFLOW_LOCK_INCOMPATIBLE=1 /usr/bin/ruby -r "$plugin_dir/lib/omaflow" -e '
  abort "unavailable built-in leaked into inventory" if
    Omaflow::ScriptRegistry.inventory.any? { it["name"] == "lock-fingerprint-enable" }
'

group_plugin="$test_root/group-plugin"
mkdir "$group_plugin"
cp -a "$plugin_dir/bin" "$plugin_dir/lib" "$plugin_dir/scripts" "$group_plugin/"
chmod 775 "$group_plugin/scripts" "$group_plugin/scripts/lock-fingerprint-enable" "$group_plugin/scripts/lock-fingerprint-disable"
run_env "$group_plugin/bin/omaflow" scripts list | grep -q '^! lock-fingerprint-enable'

echo 'not json' >"$scripts_file"
if run_env "$plugin_dir/bin/omaflow" scripts add another "$approved" 2>/dev/null; then
  echo "corrupt script config unexpectedly overwritten" >&2
  exit 1
fi
[[ $(<"$scripts_file") == 'not json' ]]

echo "test-scripts: ok"
