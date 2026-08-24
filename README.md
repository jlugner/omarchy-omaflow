# Omaflow

Agent-authored desktop automations for [Omarchy](https://omarchy.org) — described in English, compiled once into inspectable rules, executed deterministically forever.

> "When I dock my ultrawide on weekday mornings, switch to my work theme and open Slack on workspace 3."

Your agent (Codex, Claude Code, or Grok) compiles that into a small, validated JSON rule. Omaflow shows you exactly what it will do before you install it, then runs it with no model in the loop: instant, offline, and identical every time. Every automation lives in one inspectable place — browse them, dry-run them, read the "why did that happen" timeline, disable or delete them cleanly.

**The test Omaflow holds itself to:** you can inspect, test, disable, roll back, and move any automation to another machine — without reopening an agent.

## Requirements

- Omarchy 4 with `omarchy-shell`
- One agent CLI for authoring: [Codex](https://github.com/openai/codex), [Claude Code](https://claude.com/claude-code), or Grok — signed in. (Only used to *compile* rules; never at trigger time.)
- `jq`, `hyprctl`, `nmcli`, `pactl` (all on stock Omarchy)

## Install

```bash
omarchy plugin add https://github.com/jlugner/omarchy-omaflow.git --enable
```

Restart the shell once so the engine service mounts (`omarchy-restart-shell`), then bind the inspector in `~/.config/hypr/bindings.lua` and run `hyprctl reload`:

```lua
o.bind(
  "SUPER + SHIFT + U",
  "Automations (Omaflow)",
  "$HOME/.config/omarchy/plugins/jesperlugner.omaflow/bin/omaflow"
)
```

To uninstall: remove the keybinding, `omarchy plugin remove jesperlugner.omaflow`. Your rules stay in `~/.config/omaflow/`; delete that and `~/.local/state/omaflow/` for a full cleanup.

## Use

Open the inspector and describe an automation. The agent compiles it, and a preview card shows the exact trigger, conditions, and actions — `Return` installs it, `Esc` discards it. Nothing runs that you haven't read.

| Key | Action |
|-----|--------|
| `Return` | Compile the description — or install the previewed rule |
| `Alt+Return` | Run the selected rule now |
| `Ctrl+Return` | Dry-run: log exactly what would execute |
| `Ctrl+E` | Enable / disable the selected rule |
| `Alt+Delete` | Delete it (confirmed) |
| `Up` / `Down` | Move the selection |
| `Esc` | Discard preview / clear / close |

The **Recent activity** timeline answers "why did my theme just change?" — every firing records which trigger matched and which actions ran.

Everything is also a CLI:

```bash
omaflow author "on battery, enable dnd and dim ambitions"
omaflow stage show|accept|reject
omaflow list · run <id> [--dry-run] · enable|disable|delete <id>
omaflow log · revert <exec-id> · agent [codex|claude|grok|auto] · poke
```

## What rules can do (v0.1)

**Triggers:** manual · time of day (+ weekdays) · monitor connected/disconnected · wifi connected (by name, any, or *never seen before*) / disconnected · switched to AC/battery.

**Conditions:** time window · weekday · on AC/battery · monitor present · on a given wifi.

**Actions:** set theme · DND on/off · nightlight on/off · stay-awake on/off · launch app (optionally on a workspace) · switch workspace · set audio output · send a notification · **message a Grok bot**.

The `grok-message` action sends one-way messages to persistent, named Grok bot sessions — *"whenever I switch to battery, tell my bot sentry"*. Each bot is a durable conversation: the first send creates it, later sends continue it, and `{{trigger}}` in the message expands to the firing event. Sends run tool-less (`--tools ""`), so bots never get access to this machine. `omaflow bots` lists your bots with the `grok --resume <id>` command to chat with any of them directly — the bot has the full history of everything your desktop ever told it.

There is deliberately **no shell action**: the agent can only emit typed, allowlisted actions, and `omaflow-validate` gates every rule — schema-checked and referentially checked against your machine (the theme exists, the app has a desktop entry) — both at install time and again before every run.

## How it works

- Rules are one JSON file each in `~/.config/omaflow/rules/` — portable config that syncs like your dotfiles. Each rule keeps the original English request in its `source` field.
- A small shell service forwards change signals (Hyprland monitor events, `nmcli monitor`, power state, a 45s heartbeat) to `bin/omaflow-eval` — a pure state-diff engine: it re-reads reality, diffs against its last snapshot, derives events, and fires matching rules. Redundant signals are free; the heartbeat caps worst-case latency even if a signal source dies. First run stores a baseline and fires nothing.
- `bin/omaflow-run` executes actions through existing Omarchy surfaces (`omarchy theme set`, shell IPC for DND/nightlight/idle, `hyprctl`, `pactl`). Revertible actions (theme, DND, nightlight, stay-awake, audio) are snapshotted first; a failed action rolls the applied ones back, and `omaflow revert <exec-id>` restores any run by hand.
- Authoring (`bin/omaflow-author`) hands the agent the schema plus your machine's real inventory (themes, monitors, sinks, apps), validates the result, retries once with the validator's errors on failure, and stages it — `stage accept` is the only path into the rules directory.
- Agent choice: `--agent` flag > `OMAFLOW_AGENT` > `omaflow agent <backend>` > **Omarchy's default agent** (`omarchy-default-agent`) > first installed of codex/claude/grok.

Nothing leaves your machine at trigger time. Authoring sends your description and the inventory lists above to your chosen agent, only when you ask — with the agent's tools, MCP servers, and web access disabled as far as each CLI allows (`codex --sandbox read-only`, `claude --strict-mcp-config --disallowedTools …`, `grok --tools "" --disable-web-search`) and a hard timeout. The validator additionally rejects option-shaped strings (leading dashes, control characters) in every field that reaches a command line, so a prompt-injected rule can't smuggle flags — for example into notification exec hints.

## Verify

```bash
omarchy plugin validate ~/.config/omarchy/plugins/jesperlugner.omaflow
~/.config/omarchy/plugins/jesperlugner.omaflow/tests/test-validate.sh
~/.config/omarchy/plugins/jesperlugner.omaflow/tests/test-eval.sh
~/.config/omarchy/plugins/jesperlugner.omaflow/tests/test-author.sh
```

The same checks run in CI on every push. Tests fake every system surface (including the agent), so they run anywhere.

## License

[MIT](LICENSE)
