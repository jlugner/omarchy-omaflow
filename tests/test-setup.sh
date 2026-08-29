#!/bin/bash

set -euo pipefail
trap 'echo "$0: FAILED at line $LINENO" >&2' ERR

plugin_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT
fake_bin="$test_root/bin"
mkdir -p "$fake_bin"

cat >"$fake_bin/hyprctl" <<'SH'
#!/bin/bash
printf '[]\n'
SH

cat >"$fake_bin/notify-send" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$NOTIFY_LOG"
SH

ln -s notify-send "$fake_bin/omarchy-notification-send"
chmod +x "$fake_bin/hyprctl" "$fake_bin/notify-send"
test_path="$fake_bin:/usr/bin:/bin"

same_file_content() { [ "$(md5sum < "$1")" = "$(md5sum < "$2")" ]; }

run_cli() {
  local test_home=$1
  shift
  HOME="$test_home" XDG_CONFIG_HOME="$test_home/.config" XDG_STATE_HOME="$test_home/.local/state" \
    PATH="$test_path" "$plugin_dir/bin/omaflow" "$@"
}

setup_home="$test_root/setup-home"
mkdir -p "$setup_home/.config/hypr"
printf 'bind = SUPER, Return, exec, foot\n' >"$setup_home/.config/hypr/bindings.conf"
run_cli "$setup_home" setup --yes >/dev/null

cli_link="$setup_home/.local/bin/omaflow"
menu_file="$setup_home/.config/omarchy/extensions/omarchy-menu.jsonc"
bindings_file="$setup_home/.config/hypr/bindings.conf"
[[ -L $cli_link ]]
[[ $(readlink -f "$cli_link") == "$plugin_dir/bin/omaflow" ]]
[[ $(grep -c '// omaflow:begin' "$menu_file") == 1 ]]
[[ $(grep -c '// omaflow:end' "$menu_file") == 1 ]]
[[ $(grep -c '# omaflow:begin' "$bindings_file") == 1 ]]
[[ $(grep -c '# omaflow:end' "$bindings_file") == 1 ]]
grep -Fq 'bindd = SUPER SHIFT, U, Toggle Omaflow, exec, omarchy-shell shell toggle jesperlugner.omaflow' "$bindings_file"

cp "$menu_file" "$test_root/menu-before"
cp "$bindings_file" "$test_root/bindings-before"
run_cli "$setup_home" setup --yes >/dev/null
same_file_content "$test_root/menu-before" "$menu_file"
same_file_content "$test_root/bindings-before" "$bindings_file"
[[ $(grep -c '// omaflow:begin' "$menu_file") == 1 ]]
[[ $(grep -c '# omaflow:begin' "$bindings_file") == 1 ]]

lua_home="$test_root/lua-home"
lua_bindings="$lua_home/.config/hypr/bindings.lua"
lua_conf="$lua_home/.config/hypr/bindings.conf"
mkdir -p "$(dirname "$lua_bindings")"
printf 'o.bind("SUPER + RETURN", "Terminal", "foot")\n' >"$lua_bindings"
printf 'bind = SUPER, Return, exec, foot\n' >"$lua_conf"
cp "$lua_conf" "$test_root/lua-conf-before"
run_cli "$lua_home" setup --yes >/dev/null
grep -Fq -- '-- omaflow:begin' "$lua_bindings"
grep -Fq -- '-- omaflow:end' "$lua_bindings"
grep -Fq '  "SUPER + SHIFT + U",' "$lua_bindings"
grep -Fq '  "Automations (Omaflow)",' "$lua_bindings"
grep -Fq '  "$HOME/.config/omarchy/plugins/jesperlugner.omaflow/bin/omaflow"' "$lua_bindings"
same_file_content "$test_root/lua-conf-before" "$lua_conf"
cp "$lua_bindings" "$test_root/lua-before"
run_cli "$lua_home" setup --yes >/dev/null
same_file_content "$test_root/lua-before" "$lua_bindings"
[[ $(grep -c -- '-- omaflow:begin' "$lua_bindings") == 1 ]]

symlink_home="$test_root/symlink-home"
symlink_targets="$test_root/symlink-targets"
symlink_menu="$symlink_home/.config/omarchy/extensions/omarchy-menu.jsonc"
symlink_bindings="$symlink_home/.config/hypr/bindings.conf"
mkdir -p "$(dirname "$symlink_menu")" "$(dirname "$symlink_bindings")" "$symlink_targets"
printf '{\n  "existing": {"label": "Keep"}\n}\n' >"$symlink_targets/menu.jsonc"
printf 'bind = SUPER, Return, exec, foot\n' >"$symlink_targets/bindings.conf"
ln -s "$symlink_targets/menu.jsonc" "$symlink_menu"
ln -s "$symlink_targets/bindings.conf" "$symlink_bindings"
run_cli "$symlink_home" setup --yes >/dev/null
[[ -L $symlink_menu ]]
[[ -L $symlink_bindings ]]
grep -q '// omaflow:begin' "$symlink_targets/menu.jsonc"
grep -q '# omaflow:begin' "$symlink_targets/bindings.conf"

collision_home="$test_root/collision-home"
collision_menu="$collision_home/.config/omarchy/extensions/omarchy-menu.jsonc"
mkdir -p "$(dirname "$collision_menu")"
printf '{\n  "automations": {"label": "Existing", "action": "keep-me"}\n}\n' >"$collision_menu"
cp "$collision_menu" "$test_root/collision-before"
if run_cli "$collision_home" setup --yes >"$test_root/collision.out" 2>&1; then
  echo 'existing automations menu entry was accepted' >&2
  exit 1
fi
grep -q 'already has an unmarked automations entry; refusing to overwrite' "$test_root/collision.out"
same_file_content "$test_root/collision-before" "$collision_menu"

foreign_home="$test_root/foreign-home"
mkdir -p "$foreign_home/.local/bin"
ln -s /usr/bin/true "$foreign_home/.local/bin/omaflow"
if run_cli "$foreign_home" setup --yes >"$test_root/foreign.out" 2>&1; then
  echo 'foreign Omaflow link was accepted' >&2
  exit 1
fi
grep -q 'refusing to overwrite' "$test_root/foreign.out"
[[ $(readlink "$foreign_home/.local/bin/omaflow") == /usr/bin/true ]]

preserve_home="$test_root/preserve-home"
preserve_menu="$preserve_home/.config/omarchy/extensions/omarchy-menu.jsonc"
mkdir -p "$(dirname "$preserve_menu")"
cat >"$preserve_menu" <<'JSONC'
{
  "existing": {"label": "Keep this exactly"},
}
JSONC
chmod 0640 "$preserve_menu"
cp "$preserve_menu" "$test_root/preserve-original"
run_cli "$preserve_home" setup --yes >/dev/null
/usr/bin/ruby -e '
  original = File.binread(ARGV[0])
  updated = File.binread(ARGV[1])
  start_at = updated.index("  // omaflow:begin") or abort "missing menu block"
  marker_end = updated.index("  // omaflow:end", start_at) or abort "missing menu end"
  after = updated.index("\n", marker_end) or abort "missing block newline"
  outside = updated[0...start_at] + updated[(after + 1)..]
  abort "content outside marker block changed" unless outside == original
' "$test_root/preserve-original" "$preserve_menu"
[[ $(stat -c %a "$preserve_menu") == 640 ]]

utf8_home="$test_root/utf8-home"
utf8_menu="$utf8_home/.config/omarchy/extensions/omarchy-menu.jsonc"
mkdir -p "$(dirname "$utf8_menu")"
cat >"$utf8_menu" <<'JSONC'
{
  // append ✓ when it succeeds
  "existing": {"label": "Keep ✓ this"},
}
JSONC
run_cli "$utf8_home" setup --yes >"$test_root/utf8.out" 2>&1
grep -Fq '✓ installed' "$test_root/utf8.out"
grep -Fq '"automations"' "$utf8_menu"
grep -Fq 'Keep ✓ this' "$utf8_menu"

comma_home="$test_root/comma-home"
comma_menu="$comma_home/.config/omarchy/extensions/omarchy-menu.jsonc"
mkdir -p "$(dirname "$comma_menu")"
cat >"$comma_menu" <<'JSONC'
{
  "existing": {"label": "No trailing comma"}
}
JSONC
run_cli "$comma_home" setup --yes >/dev/null
/usr/bin/ruby -r json -e '
  stripped = File.read(ARGV[0]).gsub(%r{^\s*//[^\n]*\n?}, "").gsub(/,(\s*[}\]])/, "\\1")
  parsed = JSON.parse(stripped)
  abort "menu block missing" unless parsed.key?("automations")
  abort "existing entry lost" unless parsed.key?("existing")
' "$comma_menu"

marker_text_home="$test_root/marker-text-home"
marker_text_menu="$marker_text_home/.config/omarchy/extensions/omarchy-menu.jsonc"
mkdir -p "$(dirname "$marker_text_menu")"
cat >"$marker_text_menu" <<'JSONC'
{
  "note": "// omaflow:begin"
}
JSONC
run_cli "$marker_text_home" setup --yes >/dev/null
/usr/bin/ruby -r json -e '
  stripped = File.read(ARGV[0]).gsub(%r{^\s*//[^\n]*(\n|$)}, "").gsub(/,(\s*[}\]])/, "\\1")
  parsed = JSON.parse(stripped)
  abort "marker-like string changed" unless parsed["note"] == "// omaflow:begin"
  abort "menu block missing" unless parsed.key?("automations")
' "$marker_text_menu"

comment_brace_home="$test_root/comment-brace-home"
comment_brace_menu="$comment_brace_home/.config/omarchy/extensions/omarchy-menu.jsonc"
mkdir -p "$(dirname "$comment_brace_menu")"
cat >"$comment_brace_menu" <<'JSONC'
{
  "existing": {"label": "Keep"}
}
// trailing comment }
JSONC
run_cli "$comment_brace_home" setup --yes >/dev/null
/usr/bin/ruby -r json -e '
  stripped = File.read(ARGV[0]).gsub(%r{^\s*//[^\n]*(\n|$)}, "").gsub(/,(\s*[}\]])/, "\\1")
  parsed = JSON.parse(stripped)
  abort "menu block missing" unless parsed.key?("automations")
  abort "existing entry lost" unless parsed.key?("existing")
' "$comment_brace_menu"

invalid_home="$test_root/invalid-home"
invalid_menu="$invalid_home/.config/omarchy/extensions/omarchy-menu.jsonc"
mkdir -p "$(dirname "$invalid_menu")"
printf '{\n  "broken":\n}\n' >"$invalid_menu"
cp "$invalid_menu" "$test_root/invalid-original"
if run_cli "$invalid_home" setup --yes >"$test_root/invalid.out" 2>&1; then
  echo 'invalid menu was accepted' >&2
  exit 1
fi
grep -q 'needs manual attention' "$test_root/invalid.out"
same_file_content "$test_root/invalid-original" "$invalid_menu"

lone_home="$test_root/lone-home"
lone_menu="$lone_home/.config/omarchy/extensions/omarchy-menu.jsonc"
mkdir -p "$(dirname "$lone_menu")"
printf '{\n  // omaflow:begin\n}\n' >"$lone_menu"
cp "$lone_menu" "$test_root/lone-original"
if run_cli "$lone_home" setup --yes >"$test_root/lone.out" 2>&1; then
  echo 'lone menu marker was accepted' >&2
  exit 1
fi
grep -q 'needs manual attention' "$test_root/lone.out"
same_file_content "$test_root/lone-original" "$lone_menu"

non_tty_home="$test_root/non-tty-home"
if run_cli "$non_tty_home" setup </dev/null >"$test_root/non-tty.out" 2>&1; then
  echo 'non-tty setup without --yes succeeded' >&2
  exit 1
fi
grep -q 'complete these steps manually' "$test_root/non-tty.out"
grep -Fq 'o.bind(' "$test_root/non-tty.out"

first_run_home="$test_root/first-run-home"
notify_log="$test_root/notify.log"
first_output=$(NOTIFY_LOG="$notify_log" run_cli "$first_run_home" first-run 2>&1)
second_output=$(NOTIFY_LOG="$notify_log" run_cli "$first_run_home" first-run 2>&1)
[[ -z $first_output ]]
[[ -z $second_output ]]
[[ $(wc -l <"$notify_log") == 1 ]]
grep -Fq "Omaflow Installed and running. For the Super+Shift+U hotkey and the Automations menu entry, run: $plugin_dir/bin/omaflow setup" "$notify_log"
[[ $(stat -c %a "$first_run_home/.local/state/omaflow/first_run_done") == 600 ]]

echo 'test-setup: ok'
