# Verification: Godot 4.3

- **Branch:** `godot-4.3` (from `godot-4.2` @ `95f28e8`)
- **Binary:** `~/projects/godot/godot-plugins/.godot-bins/godot-4.3` (4.3.stable.official.77dcf97d8)
- **Date:** 2026-11-01
- **Status:** `awaiting-manual-check`

## Commands and results

```sh
export GODOT=~/projects/godot/godot-plugins/.godot-bins/godot-4.3
$GODOT --headless --path . --editor --quit-after 200                # reimport/resave: no file changes
tests/check_editor.sh                                              # CHECK PASSED
$GODOT --path . res://tests/depth_probe.tscn --quit-after 300      # DEPTH_PROBE_RESULT PASS
```

- Resave: opening in 4.3 changed **no** files. There are no `.uid` files until 4.4, and the `.tscn`/`.tres` headers are unchanged. So there is no `Resave resources with Godot 4.3` commit.
- `check_editor.sh` from a clean `.godot/`: both editor opens exit 0. `run_tests.gd` gives **30 checks, 0 failed**. The log scan finds nothing. Lint: **4 warnings (baseline 4)**.
- The same checks pass on 4.2 with this branch's code (`4 warnings (baseline 4)`).

Depth probe (rendered, Vulkan Forward+, NVIDIA GTX 1650 Ti):

```
DEPTH_PROBE expected=7.0 got=6.9184 predicted_8bit=6.9184 normalized=0.000069184 PASS
DEPTH_PROBE expected=30.0 got=29.8766 predicted_8bit=29.8766 normalized=0.000298766 PASS
MISS_PROBE normalized=0.000000000 decoded=-inf -> miss(-INF)
DEPTH_PROBE_RESULT PASS
```

## Changes

| Change | Reason |
|---|---|
| `vertex_painter.gd`, `v2/vertex_painter.gd`, `v2/vertex_painter_3d.gd`: removed the `set_interface()` plumbing and call the `EditorInterface` singleton directly (`EditorInterface.get_selection()`, `.get_editor_viewport_3d(0)`, `.get_editor_main_screen()`, `.set_main_screen_editor()`). | The 4.3 class reference deprecates `EditorPlugin.get_editor_interface()`: "EditorInterface is a global singleton and can be accessed directly by its name." The singleton exists since 4.2, so plan step 4 applies. A one-line swap (`set_interface(EditorInterface)`) doesn't parse: the analyzer treats a bare `EditorInterface` as a class (`GDScriptNativeClass`), not as a value. So the calls now go straight to the singleton, as the deprecation note says. |
| `tests/lint_baseline.txt`: 8 → 4 warnings | The change above removes the 4 "static function called from an instance" warnings. Remaining: B1 narrowing, unused `changes`, unused params `event` and `new_text`, all upstream and unchanged since 4.2. |
| `plugin.cfg` version `2.0-godot4.3`, README tested versions | Plan step 5. |

## Suspected changes from the plan, checked

- **Reversed-Z depth (4.3):** **no impact.** The decoded depth is bit-identical to 4.2 at 7.0 and 30.0, and a miss still decodes to normalized `0.0` → `-INF` (nothing painted). That's expected: `gpu_depth.gdshader` goes through `INV_PROJECTION_MATRIX` with the raw depth sample, so the depth convention is handled by the matrix. agent-1 found the same on all of 4.2–4.7, also at 2.5 and 40 units.
- **`get_editor_interface()` deprecation:** migrated (see above). GDScript doesn't print a warning for it. The deprecation is in the class reference only.

## Engine issue found: 4.3 headless editor crash on `--quit` (harness-only)

`godot-4.3 --headless --path . --editor --quit` segfaults on exit (rc 134/139). This happens on `main` too, so the port didn't cause it. **It's an engine bug, not the addon** (agent-1, board card T2a). The minimal repro is a fresh 4.3 project with one PNG and *any* enabled plugin, even a no-op `EditorPlugin`. Remove the PNG or the plugin and it exits 0. 4.2 and 4.4 exit 0. The crash happens before `.godot/` editor state is saved, so it repeats on every run until one run exits cleanly. After one `--quit-after` run, plain `--quit` exits 0 too.

- `check_editor.sh` uses `--quit-after 200` for every editor run, the warm-up included (commit `555422d`).
- Plugin teardown in a real 4.3 editor session is covered by the editor probe (`tests/editor_probe/`, merged from `godot-4.2`): two disable/enable cycles, all PASS, exit 0:

```
EDITOR_PROBE initial panels=1 expected=1 PASS
EDITOR_PROBE disable panels=0 expected=0 PASS
EDITOR_PROBE enable panels=1 expected=1 PASS
EDITOR_PROBE disable2 panels=0 expected=0 PASS
EDITOR_PROBE enable2 panels=1 expected=1 PASS
EDITOR_PROBE_RESULT PASS
```

Manual check item 7 still confirms it in the GUI editor.

## Manual checklist (user, Godot 4.3 editor)

Open `tests/manual_test.tscn` with `~/projects/godot/godot-plugins/.godot-bins/godot-4.3 --path . -e`, then check:

- [ ] 1. The plugin enables without an error dialog, and the dock appears top-left.
- [ ] 2. Select `PaintMe`, tick **Enable Vertex Painting**. A left-drag on the mesh paints the picked color at the cursor.
- [ ] 3. With **Show Debug Sphere** on, the sphere follows the surface under the cursor, with no offset or lag.
- [ ] 4. Clicking empty space (sky) paints nothing and prints no errors.
- [ ] 5. Save, close and reopen the scene. The painted colors are still there.
- [ ] 6. Untick the checkbox. Normal selection and gizmos work again.
- [ ] 7. (4.3 only) Disable and re-enable the plugin in Project Settings → Plugins, then quit the editor. There's no crash on either.

Result: _pending_
