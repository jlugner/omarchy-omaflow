# Shared helpers sourced by every Omaflow script. Not executable on its own.
# shellcheck shell=bash

OMAFLOW_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omaflow"
OMAFLOW_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/omaflow"
OMAFLOW_RULES_DIR="$OMAFLOW_CONFIG_DIR/rules"
OMAFLOW_CONFIG_FILE="$OMAFLOW_CONFIG_DIR/config.json"
OMAFLOW_INDEX_FILE="$OMAFLOW_STATE_DIR/index.json"
OMAFLOW_LOG_FILE="$OMAFLOW_STATE_DIR/log.jsonl"
OMAFLOW_DOMAINS_FILE="$OMAFLOW_STATE_DIR/domains.json"
OMAFLOW_COOLDOWNS_FILE="$OMAFLOW_STATE_DIR/cooldowns.json"
OMAFLOW_SEEN_SSIDS_FILE="$OMAFLOW_STATE_DIR/seen-ssids.json"
OMAFLOW_STAGING_FILE="$OMAFLOW_STATE_DIR/staging.json"
OMAFLOW_WEBHOOKS_FILE="$OMAFLOW_CONFIG_DIR/webhooks.json"
OMAFLOW_SNAPSHOTS_DIR="$OMAFLOW_STATE_DIR/snapshots"

omaflow_init_dirs() {
  mkdir -p "$OMAFLOW_RULES_DIR" "$OMAFLOW_STATE_DIR" "$OMAFLOW_SNAPSHOTS_DIR"
}

omaflow_notify() {
  if command -v omarchy-notification-send >/dev/null; then
    omarchy-notification-send "$@" >/dev/null 2>&1 || true
  elif command -v notify-send >/dev/null; then
    notify-send "$@" >/dev/null 2>&1 || true
  fi
}

# Append one JSON object (arg 1) to the execution log, newest last.
# Serialized so concurrent writers can't interleave with pruning.
omaflow_log_append() {
  omaflow_init_dirs
  (
    flock 7
    printf '%s\n' "$1" >>"$OMAFLOW_LOG_FILE"
    if (( $(wc -l <"$OMAFLOW_LOG_FILE") > 500 )); then
      local tmp
      tmp=$(mktemp "$OMAFLOW_STATE_DIR/.log.XXXXXX")
      tail -n 400 "$OMAFLOW_LOG_FILE" >"$tmp" && mv "$tmp" "$OMAFLOW_LOG_FILE"
    fi
  ) 7>>"$OMAFLOW_STATE_DIR/.log.lock"
}

# Atomic JSON state write: omaflow_write_json <path> <content>
omaflow_write_json() {
  local tmp
  tmp=$(mktemp "$OMAFLOW_STATE_DIR/.write.XXXXXX")
  printf '%s\n' "$2" >"$tmp" && mv "$tmp" "$1"
}

# Human-readable one-line summaries for the overlay, built from a rule file.
omaflow_reindex() {
  omaflow_init_dirs
  local tmp cooldowns='{}'
  [[ -f $OMAFLOW_COOLDOWNS_FILE ]] && cooldowns=$(cat "$OMAFLOW_COOLDOWNS_FILE")
  tmp=$(mktemp "$OMAFLOW_STATE_DIR/.index.XXXXXX")
  find "$OMAFLOW_RULES_DIR" -maxdepth 1 -name '*.json' -print0 | xargs -0 -r cat |
    jq -s --argjson cooldowns "$cooldowns" --arg generatedAt "$(date --iso-8601=seconds)" '
      def trig:
        .trigger as $t |
        ($t.type // "?") + (
          if $t.match.description then ": " + $t.match.description
          elif $t.match.name then ": " + $t.match.name
          elif $t.match.ssid then ": " + $t.match.ssid
          elif ($t.match.known == false) then ": unknown network"
          elif $t.at then " " + $t.at
          elif $t.source then ": " + $t.source
          else "" end);
      def acts: [.actions[].type] | join(", ");
      {
        generatedAt: $generatedAt,
        rules: [ .[] | {
          id, name, enabled,
          triggerSummary: trig,
          actionsSummary: acts,
          actionCount: (.actions | length),
          conditionCount: ((.conditions // []) | length),
          source: (.source // ""),
          lastFired: ($cooldowns[.id].lastFiredAt // "")
        } ] | sort_by(.name)
      }' >"$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$OMAFLOW_INDEX_FILE"
}

omaflow_rule_file() {
  local id="$1"
  [[ $id =~ ^[a-z0-9][a-z0-9-]{0,40}$ ]] || return 1
  printf '%s/%s.json' "$OMAFLOW_RULES_DIR" "$id"
}

# Resolve which agent backend to use: flag > env > omaflow config > omarchy
# default agent > first installed of codex/claude/grok.
omaflow_agent() {
  local requested="${1:-}" candidate
  local supported=(codex claude grok)
  for candidate in "$requested" "${OMAFLOW_AGENT:-}" \
    "$(jq -r '.agent // ""' "$OMAFLOW_CONFIG_FILE" 2>/dev/null)" \
    "$(cat "${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/defaults/agent" 2>/dev/null)"; do
    [[ -n $candidate && $candidate != "auto" ]] || continue
    if [[ " ${supported[*]} " == *" $candidate "* ]] && command -v "$candidate" >/dev/null; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  for candidate in "${supported[@]}"; do
    if command -v "$candidate" >/dev/null; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

# Run one single-turn prompt on the chosen backend. stdout: answer (capped).
# Tools, MCP servers, and web access are disabled as far as each CLI allows —
# the task is pure text translation and must stay side-effect free even under
# prompt injection. A wall-clock timeout bounds hung backends.
omaflow_agent_run() {
  local backend="$1" task="$2" out rc=0
  local budget="${OMAFLOW_AGENT_TIMEOUT:-180}"
  case "$backend" in
  codex)
    out=$(mktemp "$OMAFLOW_STATE_DIR/.agent.XXXXXX")
    if timeout "$budget" codex exec \
      --skip-git-repo-check \
      --sandbox read-only \
      --config 'notify=[]' \
      --config 'model_reasoning_effort="low"' \
      --output-last-message "$out" \
      "$task" >/dev/null 2>&1; then
      head -c 65536 "$out"
    else
      rc=1
    fi
    rm -f "$out"
    return "$rc"
    ;;
  claude)
    out=$(timeout "$budget" claude -p "$task" --output-format text \
      --strict-mcp-config \
      --disallowedTools "Bash" "Edit" "Write" "NotebookEdit" "Read" "Glob" "Grep" "Task" "WebFetch" "WebSearch" "TodoWrite" \
      2>/dev/null) || return 1
    head -c 65536 <<<"$out"
    ;;
  grok)
    out=$(timeout "$budget" grok -p "$task" --output-format plain \
      --tools "" --disable-web-search \
      2>/dev/null) || return 1
    head -c 65536 <<<"$out"
    ;;
  *)
    echo "Unknown agent backend: $backend" >&2
    return 1
    ;;
  esac
}

# Pull the first JSON object out of possibly chatty agent output.
omaflow_extract_json() {
  local text="$1" candidate
  if jq -e 'type == "object"' >/dev/null 2>&1 <<<"$text"; then
    printf '%s' "$text"
    return 0
  fi
  candidate=$(sed -n '/^```/,/^```/p' <<<"$text" | sed '1d;$d')
  if jq -e 'type == "object"' >/dev/null 2>&1 <<<"$candidate"; then
    printf '%s' "$candidate"
    return 0
  fi
  candidate=$(tr '\n' ' ' <<<"$text" | grep -o '{.*}' || true)
  if jq -e 'type == "object"' >/dev/null 2>&1 <<<"$candidate"; then
    printf '%s' "$candidate"
    return 0
  fi
  return 1
}
