# Omaflow

Apple Shortcuts, for [Omarchy](https://omarchy.org). Except you don't build the flows. You describe them, an agent writes the rule, and you review it before anything runs.

> "When I dock my ultrawide on weekday mornings, switch to my work theme and open Slack on workspace 3."

Codex, Claude Code, or Grok turns that into a small JSON rule. From then on no AI is involved: a tiny Ruby engine runs the rule instantly, offline, the same way every time. All your automations live in one place. Browse them, dry-run them, disable them, and read the timeline that explains every firing. Rules are plain files, so you can inspect, test, and move them to another machine without ever reopening an agent.

![The Omaflow inspector: rules with live status and the activity timeline](preview.jpg)

## Requirements

- Omarchy 4 with `omarchy-shell`
- One agent CLI, signed in: [Codex](https://github.com/openai/codex), [Claude Code](https://claude.com/claude-code), or Grok. Used to write rules, never to run them.
- `ruby`, `hyprctl`, `nmcli`, `pactl` (all on stock Omarchy)

## Install

```bash
omarchy plugin add https://github.com/jlugner/omarchy-omaflow.git --enable
```

Restart the shell once so the engine starts (`omarchy-restart-shell`), then bind the inspector in `~/.config/hypr/bindings.lua` and run `hyprctl reload`:

```lua
o.bind(
  "SUPER + SHIFT + U",
  "Automations (Omaflow)",
  "$HOME/.config/omarchy/plugins/jesperlugner.omaflow/bin/omaflow"
)
```

To uninstall, remove the keybinding and run `omarchy plugin remove jesperlugner.omaflow`. Rules live in `~/.config/omaflow/`; delete that and `~/.local/state/omaflow/` for a full cleanup.

## Use

Open the inspector and describe an automation. A preview shows the exact trigger, conditions, and actions. `Return` installs it, `Esc` throws it away. Nothing runs that you haven't read.

| Key | Action |
|-----|--------|
| `Return` | Compile the description, or install the previewed rule |
| `Alt+Return` | Run the selected rule now |
| `Ctrl+Return` | Dry-run: log what would execute |
| `Ctrl+E` | Enable / disable |
| `Alt+Delete` | Delete (confirmed) |
| `Up` / `Down` | Move the selection |
| `Esc` | Discard preview / clear / close |

The activity timeline answers "why did my theme just change?" Every firing logs which trigger matched and what ran.

Everything works from the CLI too:

```bash
omaflow author "on battery, enable dnd and dim ambitions"
omaflow stage show|accept|reject
omaflow list · run <id> [--dry-run] · enable|disable|delete <id>
omaflow log · revert <exec-id> · agent [codex|claude|grok|auto] · poke
omaflow webhooks [add <name> <url> [format] | remove <name>]
```

## What rules can do

**Triggers:** manual · time of day (+ weekdays) · monitor connected/disconnected · wifi connected (by name, any, or never seen before) / disconnected · switched to AC/battery.

**Conditions:** time window · weekday · on AC/battery · monitor present · on a given wifi.

**Actions:** set theme · DND · nightlight · stay-awake · launch app (optionally on a workspace) · switch workspace · set audio output · send a notification · post to a webhook.

Webhooks reach anything with an inbox: Slack, Discord, [ntfy](https://ntfy.sh) on your phone, Home Assistant. Rules never contain URLs. They point at named endpoints you add yourself, so a rule can only send where you've allowed:

```bash
omaflow webhooks add team-slack https://hooks.slack.com/services/… slack
omaflow webhooks add phone https://ntfy.sh/your-topic ntfy
```

Formats shape the body per target: `slack`, `discord`, `ntfy`, `raw`, or a default `json` envelope. `{{trigger}}` in a message expands to the firing event.

There is no shell action, on purpose. The agent can only emit typed, allowlisted actions, and every rule is validated against your actual machine (the theme exists, the app is installed) at install time and again before every run.

## How it works

- Rules are one JSON file each in `~/.config/omaflow/rules/`, portable config that syncs like your dotfiles. Each rule keeps your original request in its `source` field.
- A small shell service forwards change signals (Hyprland monitor events, `nmcli monitor`, power state, a 45s heartbeat) to `bin/omaflow-eval`, a state-diff engine: it re-reads reality, diffs against its last snapshot, and fires matching rules. Duplicate signals cost nothing. First run stores a baseline and fires nothing.
- `bin/omaflow-run` executes actions through existing Omarchy surfaces (`omarchy theme set`, shell IPC, `hyprctl`, `pactl`). Revertible actions are snapshotted first; a failed action rolls the applied ones back, and `omaflow revert <exec-id>` restores any run by hand.
- Authoring hands the agent the schema plus your machine's real inventory (themes, monitors, sinks, apps), validates the result, and stages it. `stage accept` is the only way into the rules directory.
- Agent choice: `--agent` flag > `OMAFLOW_AGENT` > `omaflow agent <backend>` > Omarchy's default agent > first installed of codex/claude/grok.

Nothing leaves your machine at trigger time, except what a webhook action posts to endpoints you added. Authoring sends your description and the inventory above to your agent, with tools, MCP servers, and web access turned off as far as each CLI allows, plus a hard timeout. The validator also rejects option-shaped strings (leading dashes, control characters) in any field that reaches a command line.

## Verify

```bash
omarchy plugin validate ~/.config/omarchy/plugins/jesperlugner.omaflow
~/.config/omarchy/plugins/jesperlugner.omaflow/tests/test-validate.sh
~/.config/omarchy/plugins/jesperlugner.omaflow/tests/test-eval.sh
~/.config/omarchy/plugins/jesperlugner.omaflow/tests/test-author.sh
```

The same checks run in CI on every push. Tests fake every system surface, including the agent, so they run anywhere.

## License

[MIT](LICENSE)
