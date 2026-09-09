#!/bin/bash

SHUNT_MODEL="${SHUNT_MODEL:-gpt-5.6-luna}"
SHUNT_TIMEOUT_SECONDS="${SHUNT_TIMEOUT_SECONDS:-180}"
SHUNT_MODES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../modes" && pwd)"

SHUNT_TMPFILES=()
shunt_tmpfile() {
  local f
  f=$(mktemp) || return 1
  SHUNT_TMPFILES+=("$f")
  trap 'rm -f "${SHUNT_TMPFILES[@]}"' EXIT
  printf -v "$1" '%s' "$f"
}

shunt_preflight() {
  local missing=""
  command -v perl >/dev/null 2>&1 || missing=" perl"
  command -v codex >/dev/null 2>&1 || missing="$missing codex"
  if [ -n "$missing" ]; then
    echo "Error: missing required command(s):$missing" >&2
    echo "  codex — npm i -g @openai/codex, then run \`codex login\`" >&2
    return 1
  fi
  return 0
}

shunt_codex() {
  perl -e '$limit = shift; $pid = fork or exec @ARGV; $SIG{ALRM} = sub { $late = 1; kill TERM => $pid }; alarm $limit; waitpid $pid, 0; exit($late ? 124 : $? >> 8)' \
    "$SHUNT_TIMEOUT_SECONDS" codex exec "$@"
}

shunt_invoke() {
  local mode_name="$1" message_file="$2"
  local instructions="$SHUNT_MODES_DIR/$mode_name.md" prompt_file answer_file err rc

  if [ ! -f "$instructions" ]; then
    echo "Error: unknown mode \"$mode_name\" (no $instructions)" >&2
    return 1
  fi

  shunt_tmpfile prompt_file || return 1
  shunt_tmpfile answer_file || return 1
  cat "$instructions" "$message_file" > "$prompt_file"

  err=$(shunt_codex --model "$SHUNT_MODEL" --ephemeral --skip-git-repo-check \
    --ignore-user-config -c project_doc_max_bytes=0 --sandbox read-only --color never \
    --output-last-message "$answer_file" - < "$prompt_file" 2>&1 >/dev/null)
  rc=$?

  if [ "$rc" -eq 124 ]; then
    echo "Error: codex exec exceeded ${SHUNT_TIMEOUT_SECONDS}s. Raise SHUNT_TIMEOUT_SECONDS or split the work into smaller calls." >&2
    return 1
  fi

  if [ "$rc" -ne 0 ]; then
    echo "Error: codex exec failed (exit $rc)" >&2
    printf '%s\n' "$err" | tail -n 10 >&2
    return 1
  fi

  if [ ! -s "$answer_file" ]; then
    echo "Error: codex exec returned no answer" >&2
    printf '%s\n' "$err" | tail -n 10 >&2
    return 1
  fi

  printf '%s\n' "$(cat "$answer_file")"
}
