#!/bin/bash
# Transport evals for scripts/lib/codex.sh.
#
# Runs against a stubbed codex, so these need no login and no tokens.
#
# Prints one PASS/FAIL line per check plus a machine-readable "## <pass> <fail>"
# trailer for run.sh.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

WORKDIR="$(mktemp -d)"
CAPTURED_PROMPT="$WORKDIR/captured-prompt.txt"
CAPTURED_ARGS="$WORKDIR/captured-args"

# shellcheck source=../scripts/lib/codex.sh
. "$PLUGIN_DIR/scripts/lib/codex.sh"

# Stub the transport: record the prompt and flags, write a canned answer to the
# --output-last-message file, and print transcript noise to stdout like codex.
shunt_codex() {
  local out="" want_out=false arg
  printf '%s\n' "$@" > "$CAPTURED_ARGS"
  for arg in "$@"; do
    if [ "$want_out" = true ]; then out="$arg"; want_out=false; continue; fi
    case "$arg" in
      --output-last-message) want_out=true ;;
    esac
  done
  cat > "$CAPTURED_PROMPT"
  echo "transcript noise that must not be treated as the answer"
  printf -- '- first line\n- second line\n' > "$out"
}

PASSED=0
FAILED=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    printf "  \033[32mPASS\033[0m  %-32s %s\n" "$name" "$4"
    PASSED=$((PASSED + 1))
  else
    printf "  \033[31mFAIL\033[0m  %-32s expected=[%s] got=[%s]\n" "$name" "$expected" "$actual"
    FAILED=$((FAILED + 1))
  fi
}

flag_value() { grep -x -A1 -- "$1" "$CAPTURED_ARGS" | grep -vx -- "$1" | grep -v '^--$' | paste -sd' ' -; }
has_flag() { grep -qx -- "$1" "$CAPTURED_ARGS" && echo y || echo n; }

# ── Invocation ──

message_file="$WORKDIR/message.txt"
printf 'line one\nline two\n' > "$message_file"

check "answer-text-extracted" "- first line
- second line" "$(shunt_invoke bulk-reader "$message_file")" \
  "reads the last-message file instead of scraping stdout"
check "instructions-prepended" "$(cat "$PLUGIN_DIR/modes/bulk-reader.md" "$message_file")" "$(cat "$CAPTURED_PROMPT")" \
  "prompt is the mode instructions followed by the message verbatim"
check "reader-model" "gpt-5.6-luna" "$(flag_value --model)" "bulk-reader uses the read model"
check "reader-effort" "model_reasoning_effort=medium project_doc_max_bytes=0" "$(flag_value -c)" "bulk-reader runs at medium effort"
check "ephemeral" "y" "$(has_flag --ephemeral)" "no session files left behind"
check "read-only-sandbox" "read-only" "$(flag_value --sandbox)" "the worker cannot write"
check "prompt-on-stdin" "-" "$(tail -1 "$CAPTURED_ARGS")" "the corpus never touches argv"
check "user-config-ignored" "y" "$(has_flag --ignore-user-config)" "no MCP servers or plugins from ~/.codex reach the worker"

SHUNT_READ_MODEL="other-model" SHUNT_READ_EFFORT="low" shunt_invoke bulk-reader "$message_file" >/dev/null
check "reader-overridable" "other-model low" "$(flag_value --model) $(flag_value -c | cut -d= -f2 | cut -d' ' -f1)" \
  "SHUNT_READ_MODEL and SHUNT_READ_EFFORT pick the reader"

shunt_invoke code-writer "$message_file" >/dev/null
check "code-writer-instructions" "$(cat "$PLUGIN_DIR/modes/code-writer.md" "$message_file")" "$(cat "$CAPTURED_PROMPT")" \
  "each mode has its own instructions"
check "writer-model" "gpt-5.6-terra" "$(flag_value --model)" "code-writer uses the write model"
check "writer-effort" "model_reasoning_effort=high project_doc_max_bytes=0" "$(flag_value -c)" "code-writer runs at high effort"

# ── Failures ──

( shunt_invoke no-such-mode "$message_file" >/dev/null 2>&1 ) && rc=0 || rc=$?
check "unknown-mode-fails" "1" "$rc" "a mode without instructions is an error"

( shunt_codex() { echo 'auth failed' >&2; return 2; }
  guard=$(shunt_invoke bulk-reader "$message_file" 2>&1 >/dev/null) && exit 1
  case "$guard" in *"exit 2"*"auth failed"*) exit 0 ;; *) exit 1 ;; esac ) && rc=0 || rc=$?
check "nonzero-exit-fails" "0" "$rc" "codex's exit code and stderr surface"

( shunt_codex() { cat >/dev/null; }
  shunt_invoke bulk-reader "$message_file" >/dev/null 2>&1 ) && rc=0 || rc=$?
check "empty-answer-fails" "1" "$rc" "an answer with no text is an error"

( shunt_codex() { cat >/dev/null; seq 1 50 >&2; return 1; }
  guard=$(shunt_invoke bulk-reader "$message_file" 2>&1 >/dev/null)
  [ "$(printf '%s\n' "$guard" | wc -l | tr -d ' ')" -le 12 ] ) && rc=0 || rc=$?
check "stderr-trimmed" "0" "$rc" "codex echoes the prompt to stderr; a failure must not dump the corpus"

( shunt_codex() { cat >/dev/null; return 124; }
  guard=$(shunt_invoke bulk-reader "$message_file" 2>&1 >/dev/null) && exit 1
  case "$guard" in *"exceeded 180s"*) exit 0 ;; *) exit 1 ;; esac ) && rc=0 || rc=$?
check "timeout-explained" "0" "$rc" "a killed worker names the timeout knob"

rm -rf "$WORKDIR"

echo "## $PASSED $FAILED"
[ "$FAILED" -gt 0 ] && exit 1
exit 0
