# Verification: Godot 4.2 (baseline)

- **Branch:** `godot-4.2` (from `main` @ `08851d0`)
- **Binary:** `~/projects/godot/godot-plugins/.godot-bins/godot-4.2` (4.2.2.stable.official.15073afe3)
- **Date:** 2026-11-01
- **Status:** `awaiting-manual-check`

There are no addon code changes on this branch. It adds the dev project and test harness only.

## What was added

| File | Purpose |
|---|---|
| `project.godot` | Dev project at the repo root (Forward+), with the plugin enabled. Excluded from Asset Library downloads by `.gitattributes`. |
| `.gitignore` | Adds `.godot/`. |
| `tests/run_tests.gd` | Headless `SceneTree` tests: load every addon resource, instantiate the dock scene, MeshDataTool round trip, `get_n_closest_vertices()` regression guard. |
| `tests/check_editor.sh` | Runs a warm-up editor open, a scanned editor open, `run_tests.gd`, a log scan and the GDScript warning lint. |
| `tests/lint_warnings.gd` + `tests/lint_baseline.txt` | Makes GDScript static warnings visible and compares them with a baseline (see below). |
| `tests/depth_probe.tscn` + `.gd` | Rendered smoke test of the `click_raycast2()` depth readback, using the plugin's own SubViewport/MouseCamera3D/ScreenQuad. |
| `tests/manual_test.tscn` + `tests/manual_test_mesh.res` | Scene for the manual check: a 1274-vertex sphere `ArrayMesh` (48×24, white vertex colors), plus a sun, a sky and a camera. |

## Commands and results

```sh
export GODOT=~/projects/godot/godot-plugins/.godot-bins/godot-4.2
tests/check_editor.sh                                              # CHECK PASSED
$GODOT --path . res://tests/depth_probe.tscn --quit-after 300      # DEPTH_PROBE_RESULT PASS
```

`check_editor.sh`, run from a clean `.godot/`:

- warm-up editor open: exit 0 (see "Known baseline noise")
- scanned editor open: exit 0, no addon/test errors or warnings
- `run_tests.gd`: **30 checks, 0 failed**
- GDScript lint: **8 warnings (baseline 8)**, none new

Depth probe (rendered, Vulkan Forward+, NVIDIA GTX 1650 Ti):

```
DEPTH_PROBE expected=7.0 got=6.9184 predicted_8bit=6.9184 normalized=0.000069184 PASS
DEPTH_PROBE expected=30.0 got=29.8766 predicted_8bit=29.8766 normalized=0.000298766 PASS
MISS_PROBE normalized=0.000000000 decoded=-inf -> miss(-INF)
DEPTH_PROBE_RESULT PASS
```

## Findings and deviations from the plan

1. **The depth probe's tolerance isn't a flat ±0.05.** The upstream readback can't reach ±0.05. The SubViewport target is **8-bit sRGB**, and `encode_rg()` divides by `camera_far = 100000`, so at short range the whole value sits in the G channel. The probe reads 6.9184 for 7.0. That is exactly the value predicted by quantizing to 8-bit sRGB (`_predict_8bit()` matches to 4 decimals at both distances). The effective resolution is about 0.08 units at 7 m and about 0.12 at 30 m. A hit now passes if it's within ±0.05 of **either** the true distance **or** the 8-bit prediction. This still catches real breakage (a wrong projection, reversed-Z or a format change), but it doesn't fail on the upstream precision limit. This is an upstream limitation, not a port issue. If brush accuracy ever matters, it could be a Backlog item ("raise depth readback precision").
2. **Miss reference value for Task 2 (reversed-Z):** on 4.2, empty space decodes to normalized `0.0`, which `click_raycast2()` treats as a miss (`-INF`, nothing painted). The 4.3 probe has to keep this result.
3. **Vertex colors round-trip at 8-bit precision**, not exactly. The worst error is 0.00294 (< 1/255). The MDT test tolerance is 1/255.
4. **GDScript warnings are invisible by default.** Headless runs don't print static warnings, and `debug/gdscript/warnings/exclude_addons` (true by default) hides them for this addon even in the editor. So "zero new warnings" means **nothing new compared to `tests/lint_baseline.txt`**, as checked by `check_editor.sh`. When a later port removes warnings, regenerate the baseline with `UPDATE_LINT_BASELINE=1 tests/check_editor.sh` in the same commit. Warning messages can be reworded between Godot versions and then show up as "new". Read the message before changing code.

## Known baseline noise

- **First open of a fresh checkout** logs `Parse Error: Could not find type "VertexPainter"` at `addons/vertex_painter/vertex_painter.gd:7`, plus `Failed to load script`. This happens because the global class cache doesn't exist yet. The second open is clean. `check_editor.sh` therefore does an unscanned warm-up open first. (agent-1 spotted this.) In a real project, the cache already exists when the user enables the plugin.
- Engine warnings that aren't from the addon (ignored by the scanner): `Custom cursor shape not supported by this display server` and `Blend file import is enabled ... no Blender path`.
- The depth probe sometimes prints `ERROR: Pages in use exist at exit in PagedAllocator` at quit. This is engine shutdown noise and doesn't affect the result.

### GDScript warning baseline (upstream code, 8)

- `v2/vertex_painter.gd`: `set_main_screen_editor()` is static but called on an instance
- `v2/vertex_painter_3d.gd`: `get_editor_main_screen()`, `get_editor_viewport_3d()` and `get_selection()` are static but called on an instance
- `v2/vertex_painter_3d.gd`: narrowing conversion float → int (`furthest_dist`, Backlog **B1**)
- `v2/vertex_painter_3d.gd`: unused local `changes`, unused params `event` (`process_move`) and `new_text`

`get_n_closest_vertices()` regression guard: on a mesh whose squared distances are all below 1, it returns `[0, 1]` instead of `[4, 5]`. This is B1, pinned on purpose.

## Manual checklist (user, Godot 4.2 editor)

Open `tests/manual_test.tscn` in the 4.2 editor (`$GODOT --path . -e`), then check:

- [ ] 1. The plugin enables without an error dialog, and the dock appears top-left.
- [ ] 2. Select `PaintMe`, tick **Enable Vertex Painting**. A left-drag on the mesh paints the picked color at the cursor.
- [ ] 3. With **Show Debug Sphere** on, the sphere follows the surface under the cursor, with no offset or lag.
- [ ] 4. Clicking empty space (sky) paints nothing and prints no errors.
- [ ] 5. Save, close and reopen the scene. The painted colors are still there.
- [ ] 6. Untick the checkbox. Normal selection and gizmos work again.

Result: _pending_
