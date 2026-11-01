#!/usr/bin/env bash
# Opens the dev project in the editor headless (import + plugin load), then runs
# tests/run_tests.gd. Fails if either step fails or if the logs contain errors or
# warnings that come from res://addons/ or res://tests/.
#
# Usage: GODOT=/path/to/godot tests/check_editor.sh
#   Logs are written to $LOG_DIR (default: .godot/test-logs/).
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:?Set GODOT to a Godot binary, e.g. ~/projects/godot/godot-plugins/.godot-bins/godot-4.2}"
LOG_DIR="${LOG_DIR:-$ROOT/.godot/test-logs}"
mkdir -p "$LOG_DIR"
EDITOR_LOG="$LOG_DIR/editor.log"
TESTS_LOG="$LOG_DIR/tests.log"

echo "Godot: $("$GODOT" --version 2>/dev/null | tail -n1)"

status=0

# Warm-up run: on a fresh checkout (no .godot/), the first editor open runs
# before the global class cache exists and logs a spurious
# 'Could not find type "VertexPainter"' parse error. Run once to import and
# build the cache. Its log is reported for information but not scanned.
WARMUP_LOG="$LOG_DIR/editor-warmup.log"
echo "--- editor --headless --quit (warm-up, not scanned)"
"$GODOT" --headless --path "$ROOT" --editor --quit >"$WARMUP_LOG" 2>&1
echo "exit code: $? (log: $WARMUP_LOG)"

echo "--- editor --headless --quit"
"$GODOT" --headless --path "$ROOT" --editor --quit >"$EDITOR_LOG" 2>&1
rc=$?
echo "exit code: $rc (log: $EDITOR_LOG)"
[ $rc -eq 0 ] || status=1

echo "--- run_tests.gd"
"$GODOT" --headless --path "$ROOT" --script res://tests/run_tests.gd >"$TESTS_LOG" 2>&1
rc=$?
grep -E '^(==|\[|  ok|  FAIL|TESTS)' "$TESTS_LOG"
echo "exit code: $rc (log: $TESTS_LOG)"
[ $rc -eq 0 ] || status=1

# Godot prints the error/warning line, then an indented "at: ..." line with the
# source location. Pair them up and keep only those pointing at our code.
scan() {
	awk '
		/(SCRIPT ERROR|Parse Error|ERROR:|WARNING:)/ { msg = $0; hit = (msg ~ /res:\/\/(addons|tests)\//); if (hit) print msg; next }
		msg != "" && /^[[:space:]]+at:/ { if (!hit && $0 ~ /res:\/\/(addons|tests)\//) print msg " | " $0; msg = ""; next }
		{ msg = "" }
	' "$1"
}

echo "--- scanning logs for addon/test errors and warnings"
problems="$( { scan "$EDITOR_LOG"; scan "$TESTS_LOG"; } )"
if [ -n "$problems" ]; then
	echo "$problems"
	status=1
else
	echo "none"
fi

# GDScript static warnings: headless runs don't print them, and the editor
# hides them for res://addons by default. lint_warnings.gd raises them to
# errors; we keep "file: message" pairs (deduped, no line numbers, so edits
# that shift lines don't cause churn) and compare them to the committed baseline.
LINT_LOG="$LOG_DIR/lint.log"
LINT_BASELINE="$ROOT/tests/lint_baseline.txt"
LINT_CURRENT="$LOG_DIR/lint_current.txt"
echo "--- GDScript warning lint"
"$GODOT" --headless --path "$ROOT" --script res://tests/lint_warnings.gd >"$LINT_LOG" 2>&1
awk '
	/\(Warning treated as error\.\)/ { msg = $0; sub(/^.*Parse Error: /, "", msg); sub(/ \(Warning treated as error\.\)$/, "", msg); next }
	msg != "" && /^[[:space:]]+at:/ { if (match($0, /res:\/\/[^:)]+/)) print substr($0, RSTART, RLENGTH) ": " msg; msg = ""; next }
	{ msg = "" }
' "$LINT_LOG" | LC_ALL=C sort -u >"$LINT_CURRENT"
if ! grep -q '^LINT_DONE' "$LINT_LOG"; then
	echo "lint script did not finish (log: $LINT_LOG)"
	status=1
elif [ "${UPDATE_LINT_BASELINE:-0}" = 1 ]; then
	cp "$LINT_CURRENT" "$LINT_BASELINE"
	echo "baseline updated: $(wc -l <"$LINT_BASELINE") warnings -> $LINT_BASELINE"
else
	[ -f "$LINT_BASELINE" ] || : >"$LINT_BASELINE"
	new="$(LC_ALL=C comm -13 "$LINT_BASELINE" "$LINT_CURRENT")"
	gone="$(LC_ALL=C comm -23 "$LINT_BASELINE" "$LINT_CURRENT")"
	echo "$(wc -l <"$LINT_CURRENT") warnings (baseline $(wc -l <"$LINT_BASELINE"))"
	if [ -n "$gone" ]; then
		echo "no longer reported (update the baseline with UPDATE_LINT_BASELINE=1):"
		echo "$gone" | sed 's/^/  - /'
	fi
	if [ -n "$new" ]; then
		echo "NEW warnings:"
		echo "$new" | sed 's/^/  + /'
		status=1
	fi
fi

if [ $status -eq 0 ]; then echo "CHECK PASSED"; else echo "CHECK FAILED"; fi
exit $status
