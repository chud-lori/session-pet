#!/usr/bin/env bash
# session-pet classification test — builds the app, arranges the fixture
# transcripts under an isolated fake home, runs one scan, and checks that each
# fixture lands in its expected phase.
#
# Contract with SessionPet: `SESSION_PET_HOME=<dir>` replaces $HOME for
# transcript discovery, and `--scan-once` prints one line per detected session
# (containing the transcript path and its phase) then exits.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "▸ building"
swiftc -O "$ROOT/native/SessionPet.swift" -o "$ROOT/native/SessionPet"

echo "▸ arranging fixtures"
PETHOME="$ROOT/test/home"
rm -rf "$PETHOME"
CLAUDE_DIR="$PETHOME/.claude/projects/p1"
CODEX_DIR="$PETHOME/.codex/sessions/$(date +%Y/%m/%d)"  # scanner only looks in today's dir
mkdir -p "$CLAUDE_DIR" "$CODEX_DIR"
cp "$ROOT"/test/fixtures/end-turn.jsonl \
   "$ROOT"/test/fixtures/ask-user.jsonl \
   "$ROOT"/test/fixtures/bigline.jsonl \
   "$ROOT"/test/fixtures/meta-user.jsonl "$CLAUDE_DIR/"
cp "$ROOT/test/fixtures/rollout-x.jsonl" "$CODEX_DIR/"
# backdate mtimes 45s: past the 3s needs-input debounce AND the 40s
# readyHold window (Claude end_turns younger than readyConfirm+30 are held
# as "working" until they survive 10s of observation), well inside the
# 300s "ready" window
touch -t "$(date -v-45S +%Y%m%d%H%M.%S)" "$CLAUDE_DIR"/*.jsonl "$CODEX_DIR"/*.jsonl

echo "▸ scanning"
OUT="$(SESSION_PET_HOME="$PETHOME" "$ROOT/native/SessionPet" --scan-once)"
echo "$OUT"

fail=0
expect() { # <fixture filename> <expected phase>
  local line
  line="$(grep -F "$1" <<<"$OUT" || true)"
  if [[ -z "$line" ]]; then
    echo "FAIL: $1 not in scan output"; fail=1
  elif ! grep -qw "$2" <<<"$line"; then
    echo "FAIL: $1 — expected phase '$2', got: $line"; fail=1
  else
    echo "  ok: $1 → $2"
  fi
}

expect end-turn.jsonl  ready   # stop_reason end_turn → just finished
expect ask-user.jsonl  input   # AskUserQuestion tool_use → needs your answer
expect bigline.jsonl   ready   # >70KB line after end_turn must not hide it
expect meta-user.jsonl ready   # isMeta user event after end_turn ≠ new turn
expect rollout-x.jsonl ready   # Codex task_complete → just finished

if [[ $fail -ne 0 ]]; then echo "TESTS FAILED"; exit 1; fi
echo "all phases as expected"
