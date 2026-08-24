#!/bin/bash

# Resource-exhaustion hardening (marketplace review, issue #2146): bounded
# no-follow file reads, rule-count caps, and bounded streaming subprocess
# capture instead of post-capture truncation.

set -euo pipefail
trap 'echo "$0: FAILED at line $LINENO" >&2' ERR

plugin_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT

mkdir -p "$test_root/config/omaflow/rules" "$test_root/state" "$test_root/bin"
rules_dir="$test_root/config/omaflow/rules"

run_ruby() {
  HOME="$test_root" XDG_CONFIG_HOME="$test_root/config" XDG_STATE_HOME="$test_root/state" \
    /usr/bin/ruby -r "$plugin_dir/lib/omaflow" -e "$1"
}

# Subprocess capture stops at the byte cap and reports failure instead of
# buffering unbounded output.
run_ruby '
  out, ok = Omaflow::Sys.capture("sh", "-c", "head -c 5000000 /dev/zero | tr \"\\0\" x")
  abort "capture exceeded cap: #{out.bytesize}" if out.bytesize > Omaflow::Sys::CAPTURE_MAX_BYTES
  abort "oversize capture reported success" if ok
  small, ok2 = Omaflow::Sys.capture("echo", "hello")
  abort "small capture broken" unless ok2 && small.strip == "hello"
'

# Oversize and symlinked JSON files are rejected by safe reads: the rule is
# skipped, listing survives, and load_json! raises instead of parsing.
/usr/bin/ruby -e 'print "{\"id\":\"huge\",", "\"x\":\"" + ("a" * 300_000) + "\"}"' >"$rules_dir/huge.json"
ln -s /etc/hostname "$rules_dir/sneaky.json"
cat >"$rules_dir/tiny.json" <<'EOF'
{"schemaVersion":1,"id":"tiny","name":"Tiny","enabled":false,"trigger":{"type":"manual"},
 "actions":[{"type":"notify","message":"hi"}],"source":"test"}
EOF
listing=$(HOME="$test_root" XDG_CONFIG_HOME="$test_root/config" XDG_STATE_HOME="$test_root/state" \
  PATH="$test_root/bin:/usr/bin:/bin" "$plugin_dir/bin/omaflow" list)
grep -q '○ tiny' <<<"$listing"
! grep -q 'huge' <<<"$listing"
! grep -q 'sneaky' <<<"$listing"
run_ruby '
  begin
    Omaflow::Store.load_json!(File.join(Omaflow::Paths.rules_dir, "sneaky.json"), {})
    abort "load_json! followed a symlink"
  rescue StandardError
  end
'

# The rule enumeration cap holds.
run_ruby '
  abort "rule cap missing" unless Omaflow::Store::MAX_RULE_FILES == 200
  abort "json byte cap missing" unless Omaflow::Store::MAX_JSON_BYTES == 262_144
'



# Second review sweep: the log append must not follow a planted symlink, the
# validator and revert must refuse oversize/symlinked inputs, and log display
# survives a huge log.
victim="$test_root/victim.txt"
: >"$victim"
run_ruby '
  Omaflow::Paths.ensure_dirs
  victim = File.join(Dir.home, "victim.txt")
  File.delete(Omaflow::Paths.log_file) if File.exist?(Omaflow::Paths.log_file)
  File.symlink(victim, Omaflow::Paths.log_file)
  Omaflow::Store.log_append({ "at" => "now", "kind" => "test", "status" => "ok" })
  abort "append followed the symlink" unless File.empty?(victim)
  abort "append did not recover to a regular file" unless File.file?(Omaflow::Paths.log_file) && !File.symlink?(Omaflow::Paths.log_file)
'
[[ ! -s "$victim" ]]

run_ruby '
  Omaflow::Paths.ensure_dirs
  huge = File.join(Omaflow::Paths.snapshots_dir, "huge-snap.json")
  File.write(huge, "{\"theme\":\"" + ("x" * 300_000) + "\"}")
  abort "oversize snapshot was accepted" if Omaflow::Executor.new.revert("huge-snap").zero?
' 2>/dev/null

errors=$(HOME="$test_root" XDG_CONFIG_HOME="$test_root/config" XDG_STATE_HOME="$test_root/state" \
  PATH="$test_root/bin:/usr/bin:/bin" "$plugin_dir/bin/omaflow" validate "$rules_dir/huge.json" || true)
grep -q "not a JSON object" <<<"$errors"

run_ruby '
  Omaflow::Paths.ensure_dirs
  File.delete(Omaflow::Paths.log_file) if File.exist?(Omaflow::Paths.log_file)
  File.write(Omaflow::Paths.log_file, ("{\"at\":\"x\"}\n" * 500_000))
' 
HOME="$test_root" XDG_CONFIG_HOME="$test_root/config" XDG_STATE_HOME="$test_root/state" \
  PATH="$test_root/bin:/usr/bin:/bin" timeout 10 "$plugin_dir/bin/omaflow" log 3 >/dev/null
echo "test-hardening: ok"
