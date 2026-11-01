#!/usr/bin/env bash
# Paints in a real, WINDOWED editor (the depth readback needs a renderer, so
# this opens a Godot window for a minute) and checks that every click and drag
# paints only near the point under the cursor (tests/editor_paint_probe/).
# Runs three setups: a small plane (Multiply), and a 500 m plane seen from
# 100 m above in Multiply and in Normal mode.
#
# Usage: GODOT=/path/to/godot tests/check_editor_paint.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GODOT="${GODOT:?Set GODOT to a Godot binary}"
LOG_DIR="${LOG_DIR:-$ROOT/.godot/test-logs}"
mkdir -p "$LOG_DIR"
PROJECT_BAK="$LOG_DIR/project.godot.paint.bak"
PROBE_CFG="res://tests/editor_paint_probe/plugin.cfg"
cleanup() {
	[ -f "$PROJECT_BAK" ] && cp "$PROJECT_BAK" "$ROOT/project.godot" && rm -f "$PROJECT_BAK"
}
trap cleanup EXIT
status=0
run() {
	local label="$1"; shift
	local log="$LOG_DIR/editor-paint-$label.log"
	cp "$ROOT/project.godot" "$PROJECT_BAK"
	sed -i "s#^enabled=PackedStringArray(#enabled=PackedStringArray(\"$PROBE_CFG\", #" "$ROOT/project.godot"
	env "$@" "$GODOT" --path "$ROOT" --editor --quit-after 12000 >"$log" 2>&1
	cleanup
	echo "--- $label: $(grep -c 'PASS$' "$log") passed, $(grep -c 'FAIL$' "$log") failed (log: $log)"
	grep -E 'FAIL$|far v|SCRIPT ERROR' "$log"
	grep -q '^PAINT_PROBE_RESULT PASS' "$log" || status=1
}
run small PAINT_PROBE_BIG=0
run big-multiply PAINT_PROBE_BIG=1
run big-normal PAINT_PROBE_BIG=1 PAINT_PROBE_NORMAL=1
[ $status -eq 0 ] && echo "CHECK PASSED" || echo "CHECK FAILED"
exit $status
