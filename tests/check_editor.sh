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

# The editor runs use --quit-after instead of --quit: Godot 4.3's headless
# editor segfaults when told to --quit on the first frame with this plugin
# enabled (see docs/verification/godot-4.3.md). 200 frames also lets the
# plugin's dock finish entering the tree.
EDITOR_QUIT=(--quit-after 200)

# Warm-up run: on a fresh checkout (no .godot/), the first editor open runs
# before the global class cache exists and logs a spurious
# 'Could not find type "VertexPainter"' parse error. Run once to import and
# build the cache. Its log is reported for information but not scanned.
WARMUP_LOG="$LOG_DIR/editor-warmup.log"
echo "--- editor --headless (warm-up, not scanned)"
"$GODOT" --headless --path "$ROOT" --editor "${EDITOR_QUIT[@]}" >"$WARMUP_LOG" 2>&1
echo "exit code: $? (log: $WARMUP_LOG)"

echo "--- editor --headless"
"$GODOT" --headless --path "$ROOT" --editor "${EDITOR_QUIT[@]}" >"$EDITOR_LOG" 2>&1
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

# Editor probe: in a real headless editor session, disable and re-enable the
# plugin twice and check its dock appears/disappears (tests/editor_probe/).
# The editor ignores override.cfg for editor_plugins, so project.godot is
# edited temporarily and always restored from a backup.
PROBE_LOG="$LOG_DIR/editor-probe.log"
PROJECT_BAK="$LOG_DIR/project.godot.bak"
PROBE_CFG="res://tests/editor_probe/plugin.cfg"
cleanup() {
	[ -f "$PROJECT_BAK" ] && cp "$PROJECT_BAK" "$ROOT/project.godot" && rm -f "$PROJECT_BAK"
	rm -f "$ROOT/override.cfg"
}
trap cleanup EXIT
echo "--- editor probe (plugin disable/enable x2)"
cp "$ROOT/project.godot" "$PROJECT_BAK"
sed -i "s#^enabled=PackedStringArray(#enabled=PackedStringArray(\"$PROBE_CFG\", #" "$ROOT/project.godot"
if grep -q "$PROBE_CFG" "$ROOT/project.godot"; then
	# The probe quits by itself; --quit-after is only a safety net.
	"$GODOT" --headless --path "$ROOT" --editor --quit-after 3000 >"$PROBE_LOG" 2>&1
	rc=$?
	cleanup
	grep '^EDITOR_PROBE' "$PROBE_LOG"
	echo "exit code: $rc (log: $PROBE_LOG)"
	if [ $rc -ne 0 ] || ! grep -q '^EDITOR_PROBE_RESULT PASS' "$PROBE_LOG"; then status=1; fi
else
	cleanup
	echo "could not add the probe to project.godot's editor_plugins/enabled"
	status=1
fi

echo "--- scanning logs for addon/test errors and warnings"
problems="$( { scan "$EDITOR_LOG"; scan "$TESTS_LOG"; scan "$PROBE_LOG"; } )"
if [ -n "$problems" ]; then
	echo "$problems"
	status=1
else
	echo "none"
fi

# GDScript static warnings: headless runs don't print them, and the editor
# hides them for res://addons by default. lint_warnings.gd emits a temporary
# override.cfg that raises them to errors, then re-parses every script. We keep
# "file: message" pairs (deduped, no line numbers, so edits that shift lines
# don't cause churn) and compare them to the committed baseline.
LINT_LOG="$LOG_DIR/lint.log"
LINT_BASELINE="$ROOT/tests/lint_baseline.txt"
LINT_CURRENT="$LOG_DIR/lint_current.txt"
OVERRIDE="$ROOT/override.cfg"
echo "--- GDScript warning lint"
if [ -e "$OVERRIDE" ]; then
	echo "refusing to run: $OVERRIDE already exists (it would be overwritten)"
	echo "CHECK FAILED"
	exit 1
fi
"$GODOT" --headless --path "$ROOT" --script res://tests/lint_warnings.gd -- --emit-override 2>/dev/null \
	| sed -n '/^OVR_BEGIN$/,/^OVR_END$/p' | sed '1d;$d' >"$OVERRIDE"
cp "$OVERRIDE" "$LOG_DIR/lint_override.cfg"
"$GODOT" --headless --path "$ROOT" --script res://tests/lint_warnings.gd >"$LINT_LOG" 2>&1
rm -f "$OVERRIDE"
if ! grep -q 'Warning treated as error\|^gdscript/warnings/' "$LINT_LOG" "$LOG_DIR/lint_override.cfg" >/dev/null; then
	echo "override.cfg came out empty (log: $LOG_DIR/lint_override.cfg)"
	status=1
fi
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
	# Missing warnings fail too: if the lint goes blind (e.g. a Godot version
	# ignores the override), "fewer warnings" must not pass silently. When a
	# code change really removes warnings, update the baseline in that commit.
	if [ -n "$gone" ]; then
		echo "MISSING warnings (fixed by a code change? then rerun with UPDATE_LINT_BASELINE=1;"
		echo "otherwise the lint may not be seeing them on this Godot version):"
		echo "$gone" | sed 's/^/  - /'
		status=1
	fi
	if [ -n "$new" ]; then
		echo "NEW warnings:"
		echo "$new" | sed 's/^/  + /'
		status=1
	fi
fi

if [ $status -eq 0 ]; then echo "CHECK PASSED"; else echo "CHECK FAILED"; fi
exit $status
