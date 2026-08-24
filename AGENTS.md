# Agent notes

For AI agents (and humans) working on this codebase.

## Shape

All logic lives in bash under `bin/`. The QML is deliberately dumb: `Service.qml` only converts signals into `omaflow-eval` invocations, and `Omaflow.qml` only renders state files and shells out to `bin/omaflow`. Rules (config) live in `~/.config/omaflow/rules/`; everything mutable in `~/.local/state/omaflow/`. The overlay watches `index.json`, `log.jsonl`, and `staging.json`; every CLI mutation ends with `omaflow_reindex`.

## Invariants — do not break

- No shell action type, ever. Agent-generated rules execute only through the typed allowlist in `omaflow-run`.
- `omaflow-validate` is the gate. Every rule is validated at install time and again before every run. Rule values never reach a command line unvalidated, are passed as single argv words, and are never interpolated into shell or jq program text (use `--arg`/`--argjson`).
- Webhook actions reference named endpoints from `webhooks.json`, never URLs.
- The authoring agent runs tool-less with a hard timeout (`omaflow_agent_run`); its output is untrusted until validated. `stage accept` is the only path into the rules directory.
- `omaflow-eval` is a pure state-diff engine under a non-blocking lock. A failed probe keeps the previous domain value; it must never fabricate events.
- Runs are serialized by the run lock. Revertible actions are snapshotted first, fail-closed, and rolled back in-lock on failure.

## Adding a trigger, condition, or action type

Touch all of: `omaflow-validate` (schema checks + the unknown-key list), `omaflow-run` (executor, for actions), `omaflow-eval` (event derivation, for triggers), the schema doc in `omaflow-author`, and the README. `tests/test-docs.sh` pins the first four together — update its expected list, then add behavior tests.

## Testing

`tests/*.sh` fake every system surface (hyprctl, nmcli, omarchy, omarchy-shell, pactl, curl, the agent CLI), so they run anywhere. Before committing, run all test scripts plus `omarchy plugin validate .`. QML changes need `omarchy-restart-shell` to take effect — the shell serves stale cached QML after a hot reload.
