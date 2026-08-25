# Agent notes

For AI agents (and humans) working on this codebase.

## Shape

The brain is Ruby (stdlib only, no gems), targeting the system `/usr/bin/ruby` that ships with Omarchy. It lives in `lib/omaflow/`; the `bin/` entry points are thin wrappers whose paths must not change (the QML and user keybindings reference them). The QML is deliberately dumb: `Service.qml` only converts signals into `omaflow-eval` invocations, and `Omaflow.qml` only renders state files and shells out to `bin/omaflow`. The visual editor funnels its JSON through `stage-file` and the existing preview/accept flow, so the validator remains the only gate. Rules (config) live in `~/.config/omaflow/rules/`; everything mutable in `~/.local/state/omaflow/`. The overlay watches `index.json`, `log.jsonl`, and `staging.json`; every mutation ends with `Store.reindex`.

## Style

RuboCop (config in .rubocop.yml, enforced in CI), plus: endless methods for short methods (including an endless method whose body is a single block call); `it` for single-arg one-line blocks and `_1`/`_2` for multi-arg one-liners; named parameters on anything multi-line. No comments — code must explain itself; this file carries the invariants instead.

## Invariants — do not break

- No shell action type, ever. Agent-generated rules execute only through `Executor::HANDLERS`. A script action names one packaged or user-whitelisted executable; rule JSON can never supply its path, arguments, or shell text.
- The `Validator` is the gate. Every rule is validated at install time and again before every run. Rule values are passed as single argv words, never interpolated into shell text.
- Webhook actions reference named endpoints from `webhooks.json`, never URLs. Bodies go through `curl --data-raw` (never `--data-binary` with a variable — a leading `@` would upload a file).
- HEY timetrack state lives in the `0600` `timetrack.json` file as `{"category": <resolved>, "startedAt": <ISO timestamp>}`, HEY event conditions fail closed whenever the CLI or service is unavailable, and categories are sanitized before becoming single argv words.
- The authoring agent runs with tools/MCP/web disabled as far as each CLI allows, from an empty scratch directory, with a hard timeout (`Agent.run`); its output is untrusted until validated. `stage accept` is the only path into the rules directory. Accepted residual risk: these are agent CLIs, not raw model calls — a prompt-injected request could still make the agent read files its sandbox permits and echo them into its response. The validator stops that output from *doing* anything, but not from having been read. A raw no-tools API call would close this; it would also require API keys, which the subscription-CLI design deliberately avoids.
- Agent-action proposals are untrusted until validated against the sent window context and the rule's `can` list. They fail closed and never expose a shell.
- The `Evaluator` is a pure state-diff engine under a non-blocking lock. A failed probe keeps the previous domain value; it must never fabricate events.
- Window diffs larger than the event limit advance the snapshot without emitting window events; arbitrary subsets must never fire during bulk changes.
- Watched-directory diffs larger than 10 additions advance that directory's snapshot without emitting file events; probes with more than 512 children fail and preserve the prior snapshot, and only the first 8 expanded sorted enabled-rule paths are watched.
- Git branch probes resolve `.git` directories or one-hop `gitdir:` files, fail and preserve the prior state when HEAD is unreadable, and watch only the first 8 expanded sorted enabled-rule repositories.
- `watched-dirs.json` contains the union of the separately capped 8 file-trigger directories and resolved Git directories, capped at 16, and is rewritten on every reindex; evaluator ticks rewrite it only when that list changes so the shell's inotify process follows enable and disable changes.
- Runs are serialized by the run lock. Revertible actions are snapshotted first, fail-closed, and rolled back in-lock on failure. Reverts must report irreversible actions honestly; an empty snapshot is never a successful revert.
- `Store.parse_json`/`read_json` return the fallback unless the parse matches the fallback's type — never pass `nil` as the fallback expecting a parse back.

## Adding a trigger, condition, or action type

Touch all of: `Vocabulary`, `Validator::{TRIGGER,CONDITION,ACTION}_CHECKS` (+ a check method), `Executor::HANDLERS` for actions (+ `SNAPSHOTTED` if revertible), `Evaluator` event derivation for triggers, `Author::SCHEMA_DOC`, and the README. `tests/test-docs.sh` pins these together — update its expected list, then add behavior tests.

## Testing

`tests/*.sh` fake every system surface (hyprctl, nmcli, omarchy, omarchy-shell, pactl, curl, the agent CLI) and treat the bins as black boxes, so they survive refactors and run anywhere. Before committing: all test scripts, `ruby -c` on every source file, and `omarchy plugin validate .`. QML changes need `omarchy-restart-shell` to take effect — the shell serves stale cached QML after a hot reload.
