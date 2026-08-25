# Omaflow

Apple Shortcuts, for [Omarchy](https://omarchy.org). Except you don't build the flows. You describe them, an agent writes the rule, and you review it before anything runs.

> "When I dock my ultrawide on weekday mornings, switch to my work theme and open Slack on workspace 3."

Codex, Claude Code, or Grok turns that into a small JSON rule. Most rules then run without AI; an explicit agent action can instead ask the configured agent to choose window targets at trigger time. All your automations live in one place. Browse them, dry-run them, disable them, and read the timeline that explains every firing. Rules are plain files, so you can inspect, test, and move them to another machine.

![The Omaflow inspector: rules with live status and the activity timeline](preview.jpg)

## Requirements

- Omarchy 4 with `omarchy-shell`
- One agent CLI, signed in: [Codex](https://github.com/openai/codex), [Claude Code](https://claude.com/claude-code), or Grok. Used to write rules and by explicit agent actions.
- `ruby`, `hyprctl`, `gdbus`, `nmcli`, `pactl` (all on stock Omarchy)

## Install

Install Omaflow from the Omarchy plugin manager:

```bash
omarchy plugin add https://github.com/jlugner/omarchy-omaflow.git --enable
```

Then run setup:

```bash
~/.config/omarchy/plugins/jesperlugner.omaflow/bin/omaflow setup
```

After the CLI link exists, the command is `omaflow setup`.

To uninstall, delete the `omaflow` link in `~/.local/bin`, remove the omaflow marker blocks from `~/.config/omarchy/extensions/omarchy-menu.jsonc` and your Hyprland bindings file, then run `omarchy plugin remove jesperlugner.omaflow`. Rules live in `~/.config/omaflow/`; delete that and `~/.local/state/omaflow/` for a full cleanup.

## Use

Open the inspector and describe an automation. A preview shows the exact trigger, conditions, and actions. `Return` installs it, `Esc` throws it away. Nothing runs that you haven't read.

Build rules by hand in the editor: `Ctrl+N` starts a new visual chain, while `e` edits the selected rule. Saving opens the same staged preview for final confirmation.

| Key | Action |
|-----|--------|
| `Return` | Compile the description, or install the previewed rule |
| `Alt+Return` | Run the selected rule now |
| `Ctrl+Return` | Dry-run: log what would execute |
| `Ctrl+E` | Enable / disable |
| `Ctrl+N` | Create a rule in the visual editor |
| `e` | Edit the selected rule |
| `Alt+Delete` | Delete (confirmed) |
| `Up` / `Down` | Move the selection |
| `Esc` | Discard preview / clear / close |

The activity timeline answers "why did my theme just change?" Every firing logs which trigger matched and what ran.

Everything works from the CLI too:

```bash
omaflow setup [--yes]
omaflow author "on battery, enable dnd and dim ambitions"
omaflow stage-file <path> · describe <id>
omaflow stage show|accept|reject
omaflow list · run <id> [--dry-run] · enable|disable|delete <id>
omaflow log · revert <exec-id> · agent [codex|claude|grok|auto] · poke
omaflow trigger <name> [key=value ...]
omaflow scripts [list | add <name> <absolute-path> [description] | remove <name>]
omaflow webhooks [add <name> <url> [format] | remove <name>]
```

## What rules can do

**Triggers:** manual · time of day (+ weekdays) · every N minutes · lid opened/closed · monitor connected/disconnected · app opened/closed · wifi connected (by name, any, or never seen before) / disconnected · switched to AC/battery · file or folder appears in a watched directory · a repo switches branch · named custom events.

**Conditions:** time window · weekday · on AC/battery · lid open/closed · monitor present · app running · repo is on a branch · on a given wifi.

**Actions:** set theme · DND · nightlight · stay-awake · launch app (optionally on a workspace) · switch workspace · set audio output · run an allowed script · send a notification · post to a webhook · ask an agent to choose window targets within a capability envelope.

An agent action sees the current window addresses, classes, titles, and workspaces, then may propose only the verbs granted in the rule: close, focus, move to workspace, or notify. Omaflow validates the whole proposal against that window list and capability envelope before executing anything; one invalid operation rejects all of it.

Webhooks reach anything with an inbox: Slack, Discord, [ntfy](https://ntfy.sh) on your phone, Home Assistant. Rules never contain URLs. They point at named endpoints you add yourself, so a rule can only send where you've allowed:

```bash
omaflow webhooks add team-slack https://hooks.slack.com/services/… slack
omaflow webhooks add phone https://ntfy.sh/your-topic ntfy
```

Formats shape the body per target: `slack`, `discord`, `ntfy`, `raw`, or a default `json` envelope.

Fire a custom event with `omaflow trigger deploy-done env=prod`. Notify and webhook messages can use `{{trigger}}` plus event fields such as `{{class}}`, `{{title}}`, `{{env}}`, `{{ssid}}`, `{{name}}`, `{{source}}`, and `{{at}}`. Unknown placeholders become empty strings.

For example, opening Slack can enable DND, or closing Zoom can send a notification.

File and folder rules react instantly through inotify when available, with the 45-second heartbeat as a fallback. Git HEAD changes ride the same inotify hotline. Dot-files are skipped; browser partial downloads are best filtered with `match.name`, such as `.pdf`.

There is no shell action, on purpose. The agent can only emit typed, allowlisted actions, and every rule is validated against your actual machine (the theme exists, the app is installed) at install time and again before every run.

### Named scripts

A script action contains only a name. It cannot contain a path, arguments, environment values, or shell text. Add one executable to the user allowlist explicitly:

```bash
omaflow scripts add refresh-desk /home/me/.local/bin/refresh-desk "Refresh the desk hardware"
omaflow scripts list
```

Omaflow stores the canonical absolute path in `~/.config/omaflow/scripts.json`. User-approved executables and their containing directories must be owned by you or root and not writable by a group/anyone. Omaflow validates the name and availability again before every run, then executes the file directly with a 30-second timeout. Put fixed arguments in a wrapper script rather than in a rule. Script actions are not revertible; whitelisting a script grants rules that exact capability.

Two packaged scripts, `lock-fingerprint-enable` and `lock-fingerprint-disable`, control fingerprint authentication through the lock service's `setFingerprintEnabled` IPC method. They support lid rules without giving agent-authored JSON access to PAM or privileged files. Validation rejects these actions unless the compatible lock IPC is currently available.

## How it works

- Rules are one JSON file each in `~/.config/omaflow/rules/`, portable config that syncs like your dotfiles. Each rule keeps your original request in its `source` field.
- A small shell service forwards change signals (Hyprland monitor events, UPower lid changes, `nmcli monitor`, power state, and a 45s heartbeat) to `bin/omaflow-eval`, a state-diff engine: it re-reads reality, diffs against its last snapshot, and fires matching rules. Duplicate signals cost nothing. First run stores a hardware baseline and fires no hardware events.
- `bin/omaflow-run` executes actions through existing Omarchy surfaces (`omarchy theme set`, shell IPC, `hyprctl`, `pactl`). An agent action uses the same tool-less agent runner as authoring, then validates its proposed operations before dispatch. Revertible actions are snapshotted first and rolled back after failure. `omaflow revert <exec-id>` rejects runs with nothing revertible and reports mixed reversible/irreversible runs as partial.
- Authoring hands the agent the schema plus your machine's real inventory (themes, monitors, sinks, apps, allowed script names), validates the result, and stages it. `stage accept` is the only way into the rules directory.
- Agent choice: `--agent` flag > `OMAFLOW_AGENT` > `omaflow agent <backend>` > Omarchy's default agent > first installed of codex/claude/grok.

Nothing leaves your machine at trigger time unless a webhook or agent action explicitly says so. Window titles live in `~/.local/state/omaflow/domains.json`, which is written with mode `0600`. Authoring sends your description and the inventory above to your agent; agent actions send their task and bounded window context. Both run with tools, MCP servers, and web access turned off as far as each CLI allows, plus a hard timeout. The validator also rejects option-shaped strings (leading dashes, control characters) in any field that reaches a command line.

## Verify

```bash
omarchy plugin validate ~/.config/omarchy/plugins/jesperlugner.omaflow
~/.config/omarchy/plugins/jesperlugner.omaflow/tests/test-validate.sh
~/.config/omarchy/plugins/jesperlugner.omaflow/tests/test-eval.sh
~/.config/omarchy/plugins/jesperlugner.omaflow/tests/test-author.sh
~/.config/omarchy/plugins/jesperlugner.omaflow/tests/test-editor.sh
~/.config/omarchy/plugins/jesperlugner.omaflow/tests/test-agent-action.sh
~/.config/omarchy/plugins/jesperlugner.omaflow/tests/test-hardening.sh
~/.config/omarchy/plugins/jesperlugner.omaflow/tests/test-setup.sh
~/.config/omarchy/plugins/jesperlugner.omaflow/tests/test-scripts.sh
```

The same checks run in CI on every push. Tests fake every system surface, including the agent, so they run anywhere.

## License

[MIT](LICENSE)
