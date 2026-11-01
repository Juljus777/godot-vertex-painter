# Verification: Godot 4.6

- **Branch:** `godot-4.6` (from `godot-4.5` @ `4bc8281`)
- **Binary:** `~/projects/godot/godot-plugins/.godot-bins/godot-4.6` (4.6.3.stable.official.7d41c59c4)
- **Date:** 2026-11-01
- **Status:** `awaiting-manual-check`

## Commands and results

```sh
export GODOT=~/projects/godot/godot-plugins/.godot-bins/godot-4.6
$GODOT --headless --path . --editor --quit-after 200                # reimport/resave: no file changes
tests/check_editor.sh                                              # CHECK PASSED
$GODOT --path . res://tests/depth_probe.tscn --quit-after 300      # DEPTH_PROBE_RESULT PASS
```

- **Resave:** opening in 4.6 changed **no** files, so there is no resave commit. The 4.6 format changes (`load_steps` dropped, nodes gain `unique_id=`) only apply when the editor *saves* a scene. A headless open doesn't. These files were **not** force-resaved: agent-1 found that `ResourceSaver.save()` on 4.6 drops the scene's header `uid` and adds no `unique_id`, and the old format still loads.
- `check_editor.sh` from a clean `.godot/`: both editor opens exit 0. `run_tests.gd` gives **30 checks, 0 failed**. The editor probe passes all 5 steps (see below). The log scan finds nothing. Lint: **4 warnings (baseline 4)**, none new.

Editor probe (real headless editor session, new dock API):

```
EDITOR_PROBE initial panels=1 expected=1 PASS
EDITOR_PROBE disable panels=0 expected=0 PASS
EDITOR_PROBE enable panels=1 expected=1 PASS
EDITOR_PROBE disable2 panels=0 expected=0 PASS
EDITOR_PROBE enable2 panels=1 expected=1 PASS
EDITOR_PROBE_RESULT PASS
```

Depth probe (rendered, Vulkan Forward+, NVIDIA GTX 1650 Ti), identical to 4.2–4.5:

```
DEPTH_PROBE expected=7.0 got=6.9184 predicted_8bit=6.9184 normalized=0.000069184 PASS
DEPTH_PROBE expected=30.0 got=29.8766 predicted_8bit=29.8766 normalized=0.000298766 PASS
MISS_PROBE normalized=0.000000000 decoded=-inf -> miss(-INF)
DEPTH_PROBE_RESULT PASS
```

## Changes

| Change | Reason |
|---|---|
| `vertex_painter.gd`: `add_control_to_dock(DOCK_SLOT_LEFT_UR, panel)` / `remove_control_from_docks(panel)` + `panel.free()` → `EditorDock.new()` (`title = "VertexPainter"`, `default_slot = EditorDock.DOCK_SLOT_LEFT_UR`), `dock.add_child(panel)`, `add_dock(dock)`; on exit `remove_dock(dock)` + `dock.queue_free()` | The 4.6 class reference deprecates `add_control_to_dock` ("Use add_dock instead") and `remove_control_from_docks` ("Use remove_dock instead"). `EditorDock` is new in 4.6, so plan step 4 applies here and not earlier. Same slot (value 2, left upper-right). The title matches the old tab name, which came from the panel's node name. `queue_free()` follows the `add_dock`/`remove_dock` docs. The panel is freed with its parent dock. |
| `plugin.cfg` version `2.0-godot4.6`, README tested versions | Plan step 5. |

GDScript prints no warning for the deprecated dock API, so the lint couldn't have caught it. The class reference is the source here.

## Suspected changes from the plan, checked

- **Dock system rework:** migrated (see above). Headless verified by the editor probe: the dock is added on enable and removed on disable, twice, with no errors. Whether it *appears top-left* in the GUI layout is manual check item 1.
- **`unique_id=` in `.tscn`:** written only when the editor saves a scene. There's no churn from a headless open, and nothing was forced.
- **`_input()` + hardcoded 30 px toolbar offset:** can't be tested headless. It needs manual check items 2 and 4b below. The code is unchanged: `VertexPainter3D._input()` still sits inside the dock, and the dock is a normal Control subtree, so it still receives `_input()` before the 3D viewport's GUI input.
- Glow defaults changed in 4.6. That doesn't affect `MouseCamera3D`, whose own `Environment` has glow off, and the depth probe is unchanged.

## Manual checklist (user, Godot 4.6 editor)

Open `tests/manual_test.tscn` with `~/projects/godot/godot-plugins/.godot-bins/godot-4.6 --path . -e`, then check:

- [ ] 1. The plugin enables without an error dialog, and the dock (tab "VertexPainter") appears top-left.
- [ ] 2. Select `PaintMe`, tick **Enable Vertex Painting**. A left-drag on the mesh paints the picked color at the cursor.
- [ ] 3. With **Show Debug Sphere** on, the sphere follows the surface under the cursor, with no offset or lag.
- [ ] 4. Clicking empty space (sky) paints nothing and prints no errors.
- [ ] 4b. (4.6) Clicking on the 3D viewport's toolbar (the top strip with the view menu and transform buttons) works normally and doesn't start painting. A mesh just below the toolbar can still be painted.
- [ ] 5. Save, close and reopen the scene. The painted colors are still there.
- [ ] 6. Untick the checkbox. Normal selection and gizmos work again.
- [ ] 7. Disable and re-enable the plugin in Project Settings → Plugins. The dock disappears and comes back, with no errors.

Saving in 4.6 (item 5) rewrites `manual_test.tscn` in the new format (no `load_steps`, `unique_id=`). Don't commit that churn unless it comes with a fix.

Result: _pending_
