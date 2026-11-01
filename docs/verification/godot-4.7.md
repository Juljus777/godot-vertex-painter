# Verification: Godot 4.7

- **Branch:** `godot-4.7` (from `godot-4.6` @ `d67e243`)
- **Binary:** `~/projects/godot/godot-plugins/.godot-bins/godot-4.7` (4.7.2.stable.official.ed1daf0bf)
- **Date:** 2026-11-01
- **Status:** `awaiting-manual-check`

## Commands and results

```sh
export GODOT=~/projects/godot/godot-plugins/.godot-bins/godot-4.7
$GODOT --headless --path . --editor --quit-after 200                # reimport/resave: no file changes
tests/check_editor.sh                                              # CHECK PASSED
$GODOT --path . res://tests/depth_probe.tscn --quit-after 300      # DEPTH_PROBE_RESULT PASS
```

- **Resave:** opening in 4.7 changed **no** files.
- `check_editor.sh` from a clean `.godot/`: both editor opens exit 0. `run_tests.gd` gives **30 checks, 0 failed**. The editor probe passes all 5 steps (plugin disable/enable ×2, dock added and removed). The log scan finds nothing. Lint: **4 warnings (baseline 4)**, none new.

Depth probe (rendered, Vulkan Forward+, NVIDIA GTX 1650 Ti), identical to 4.2–4.6:

```
DEPTH_PROBE expected=7.0 got=6.9184 predicted_8bit=6.9184 normalized=0.000069184 PASS
DEPTH_PROBE expected=30.0 got=29.8766 predicted_8bit=29.8766 normalized=0.000298766 PASS
MISS_PROBE normalized=0.000000000 decoded=-inf -> miss(-INF)
DEPTH_PROBE_RESULT PASS
```

## Changes

| Change | Reason |
|---|---|
| `plugin.cfg` version `2.0-godot4.7`, README tested versions | Plan step 5. |

There are no code changes. The 4.7 class reference deprecates nothing new compared with 4.6 among the APIs this addon uses. (`get_editor_interface` and the old dock API were already migrated in 4.3 and 4.6.) The 4.6→4.7 migration items don't touch the addon: mouse device IDs (the addon doesn't read `event.device`), typed-return checks on overrides (`_enter_tree`/`_exit_tree`/`_input` return void), and `LinearToSRGB` (visual shaders only). agent-1 researched these.

## Install into `atmosphere`

- Copied (not symlinked) the committed `addons/vertex_painter/` from this branch into `~/projects/godot/atmosphere/addons/vertex_painter/`, using `git archive`, so only tracked files are copied, `.uid` files included.
- **Nothing else in atmosphere was changed.** `game.tscn` and `project.godot` are untouched, so the plugin is **not enabled** there yet. Enable it in Project → Project Settings → Plugins.
- Headless check on a **scratch copy** of atmosphere (so the real project's `.godot/` and files aren't touched), with the plugin enabled in the copy's `project.godot`: two `--headless --editor --quit-after 300` runs on 4.7.2 both exit 0, with no errors or warnings in either log. The plugin initializes (`Vertex painter [INFO]: Brush size = 5`) and `game.tscn` reopens cleanly. There's no first-open class-cache parse error on 4.7.

## Manual checklist (user, Godot 4.7: the App Center editor or `.godot-bins/godot-4.7`)

Open `tests/manual_test.tscn` in this repo, then check:

- [ ] 1. The plugin enables without an error dialog, and the dock (tab "VertexPainter") appears top-left.
- [ ] 2. Select `PaintMe`, tick **Enable Vertex Painting**. A left-drag on the mesh paints the picked color at the cursor.
- [ ] 3. With **Show Debug Sphere** on, the sphere follows the surface under the cursor, with no offset or lag.
- [ ] 4. Clicking empty space (sky) paints nothing and prints no errors.
- [ ] 4b. Clicking the 3D viewport's toolbar doesn't start painting. A mesh just below the toolbar can still be painted.
- [ ] 5. Save, close and reopen the scene. The painted colors are still there.
- [ ] 6. Untick the checkbox. Normal selection and gizmos work again.
- [ ] 7. In `atmosphere`: enable the plugin. The dock appears with no errors.

Result: _pending_
