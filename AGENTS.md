# Agent notes

For AI agents (and humans) working on this codebase.

## Shape

The brain is Ruby (stdlib only, no gems), targeting the system `/usr/bin/ruby` that ships with Omarchy. It lives in `lib/omaflow/`; the `bin/` entry points are thin wrappers whose paths must not change (the QML and user keybindings reference them). The QML is deliberately dumb: `Service.qml` only converts signals into `omaflow-eval` invocations, and `Omaflow.qml` only renders state files and shells out to `bin/omaflow`. Rules (config) live in `~/.config/omaflow/rules/`; everything mutable in `~/.local/state/omaflow/`. The overlay watches `index.json`, `log.jsonl`, and `staging.json`; every mutation ends with `Store.reindex`.

## Style

RuboCop defaults, plus: endless methods for short methods (including an endless method whose body is a single block call); `it` for single-arg one-line blocks and `_1`/`_2` for multi-arg one-liners; named parameters on anything multi-line. No comments — code must explain itself; this file carries the invariants instead.

## Invariants — do not break

- No shell action type, ever. Agent-generated rules execute only through `Executor::HANDLERS`.
- The `Validator` is the gate. Every rule is validated at install time and again before every run. Rule values are passed as single argv words, never interpolated into shell text.
- Webhook actions reference named endpoints from `webhooks.json`, never URLs. Bodies go through `curl --data-raw` (never `--data-binary` with a variable — a leading `@` would upload a file).
- The authoring agent runs tool-less with a hard timeout (`Agent.run`); its output is untrusted until validated. `stage accept` is the only path into the rules directory.
- The `Evaluator` is a pure state-diff engine under a non-blocking lock. A failed probe keeps the previous domain value; it must never fabricate events.
- Runs are serialized by the run lock. Revertible actions are snapshotted first, fail-closed, and rolled back in-lock on failure.
- `Store.parse_json`/`read_json` return the fallback unless the parse matches the fallback's type — never pass `nil` as the fallback expecting a parse back.

## Adding a trigger, condition, or action type

Touch all of: `Vocabulary`, `Validator::{TRIGGER,CONDITION,ACTION}_CHECKS` (+ a check method), `Executor::HANDLERS` for actions (+ `SNAPSHOTTED` if revertible), `Evaluator` event derivation for triggers, `Author::SCHEMA_DOC`, and the README. `tests/test-docs.sh` pins these together — update its expected list, then add behavior tests.

## Testing

`tests/*.sh` fake every system surface (hyprctl, nmcli, omarchy, omarchy-shell, pactl, curl, the agent CLI) and treat the bins as black boxes, so they survive refactors and run anywhere. Before committing: all test scripts, `ruby -c` on every source file, and `omarchy plugin validate .`. QML changes need `omarchy-restart-shell` to take effect — the shell serves stale cached QML after a hot reload.
