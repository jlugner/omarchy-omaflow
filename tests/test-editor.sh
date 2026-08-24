#!/bin/bash

set -euo pipefail
trap 'echo "$0: FAILED at line $LINENO" >&2' ERR

plugin_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT

mkdir -p "$test_root/config/omaflow/rules" "$test_root/state" "$test_root/bin"

printf '#!/bin/bash\nif [[ "$*" == *"theme list"* ]]; then echo tokyo-night; fi\n' >"$test_root/bin/omarchy"
chmod +x "$test_root/bin/omarchy"

run_env() {
  HOME="$test_root" \
  XDG_CONFIG_HOME="$test_root/config" \
  XDG_STATE_HOME="$test_root/state" \
  PATH="$test_root/bin:/usr/bin:/bin" \
    "$@"
}

valid="$test_root/valid.json"
cat >"$valid" <<'EOF'
{"schemaVersion":1,"id":"manual-rule","name":"Manual rule","enabled":true,"trigger":{"type":"manual"},"conditions":[],"actions":[{"type":"notify","message":"hello"}],"cooldownSeconds":60,"source":"manual editor","createdBy":"manual"}
EOF

run_env "$plugin_dir/bin/omaflow" stage-file "$valid" | grep -q 'Staged rule: Manual rule'
run_env jq -e '.status == "ready" and .agent == "manual" and .request == "Manual rule" and .rule.id == "manual-rule"' \
  "$test_root/state/omaflow/staging.json" >/dev/null
run_env "$plugin_dir/bin/omaflow" stage accept | grep -q 'Installed rule: manual-rule'

run_env "$plugin_dir/bin/omaflow" describe manual-rule >"$test_root/described.json"
jq -e '.id == "manual-rule" and .actions[0].message == "hello"' "$test_root/described.json" >/dev/null
jq '.name = "Edited rule" | .actions[0].message = "updated" | .createdBy = "manual"' \
  "$test_root/described.json" >"$test_root/edited.json"
run_env "$plugin_dir/bin/omaflow" stage-file "$test_root/edited.json" >/dev/null
run_env "$plugin_dir/bin/omaflow" stage accept | grep -q 'Updated rule: manual-rule'
run_env jq -e '.name == "Edited rule" and .actions[0].message == "updated"' \
  "$test_root/config/omaflow/rules/manual-rule.json" >/dev/null
[[ $(find "$test_root/config/omaflow/rules" -name '*.json' | wc -l) == 1 ]]
if run_env "$plugin_dir/bin/omaflow" describe missing >"$test_root/missing.out" 2>&1; then
  echo 'unknown rule unexpectedly described' >&2
  exit 1
fi
grep -q 'No such rule: missing' "$test_root/missing.out"

invalid="$test_root/invalid.json"
cat >"$invalid" <<'EOF'
{"schemaVersion":1,"id":"manual-rule","name":"Broken","enabled":true,"trigger":{"type":"impossible"},"actions":[{"type":"notify","message":"hello"}]}
EOF
if run_env "$plugin_dir/bin/omaflow" stage-file "$invalid" >"$test_root/invalid.out"; then
  echo 'invalid rule unexpectedly staged' >&2
  exit 1
fi
grep -q 'error: unknown trigger type: impossible' "$test_root/invalid.out"
run_env jq -e '.status == "error" and .agent == "manual" and (.error | contains("unknown trigger type: impossible"))' \
  "$test_root/state/omaflow/staging.json" >/dev/null

oversize="$test_root/oversize.json"
/usr/bin/ruby -e 'print "{\"name\":\"", "x" * 300000, "\"}"' >"$oversize"
if run_env "$plugin_dir/bin/omaflow" stage-file "$oversize" >"$test_root/oversize.out"; then
  echo 'oversize rule unexpectedly staged' >&2
  exit 1
fi
grep -q 'error: not a JSON object' "$test_root/oversize.out"

ln -s "$valid" "$test_root/symlink.json"
if run_env "$plugin_dir/bin/omaflow" stage-file "$test_root/symlink.json" >"$test_root/symlink.out"; then
  echo 'symlinked rule unexpectedly staged' >&2
  exit 1
fi
grep -q 'error: not a JSON object' "$test_root/symlink.out"

echo 'test-editor: ok'
