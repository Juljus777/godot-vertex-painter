# Verification: Godot 4.5

- **Branch:** `godot-4.5` (from `godot-4.4` @ `7c0e844`)
- **Binary:** `~/projects/godot/godot-plugins/.godot-bins/godot-4.5` (4.5.2.stable.official.6ce3de25a)
- **Date:** 2026-11-01
- **Status:** `awaiting-manual-check`

## Commands and results

```sh
export GODOT=~/projects/godot/godot-plugins/.godot-bins/godot-4.5
$GODOT --headless --path . --editor --quit-after 200                # reimport/resave
tests/check_editor.sh                                              # CHECK PASSED
$GODOT --path . res://tests/depth_probe.tscn --quit-after 300      # DEPTH_PROBE_RESULT PASS
```

- **Resave:** only `addons/vertex_painter/icon.png.import` changed. It gained the 4.5 importer keys `compress/uastc_level`, `compress/rdo_quality_loss` and `process/channel_remap/*`, all at defaults. That's committed separately as `Resave resources with Godot 4.5`. No `.tscn`/`.tres` changes.
- `check_editor.sh` from a clean `.godot/`: both editor opens exit 0. `run_tests.gd` gives **30 checks, 0 failed**. The log scan finds nothing. Lint: **4 warnings (baseline 4)**, none new.

Depth probe (rendered, Vulkan Forward+, NVIDIA GTX 1650 Ti), identical to 4.2–4.4:

```
DEPTH_PROBE expected=7.0 got=6.9184 predicted_8bit=6.9184 normalized=0.000069184 PASS
DEPTH_PROBE expected=30.0 got=29.8766 predicted_8bit=29.8766 normalized=0.000298766 PASS
MISS_PROBE normalized=0.000000000 decoded=-inf -> miss(-INF)
DEPTH_PROBE_RESULT PASS
```

## Changes

| Change | Reason |
|---|---|
| `icon.png.import` new keys | Resave churn (Rule 4). |
| `plugin.cfg` version `2.0-godot4.5`, README tested versions | Plan step 5. |

There are no code changes.

## Suspected changes from the plan, checked

- **Scene format headers / `load_steps`:** not a 4.5 change. `load_steps` removal comes in 4.6 (and only when the editor saves a scene). On 4.5 no `.tscn`/`.tres` changed.
- **ColorPicker properties:** `edit_alpha`, `color_mode`, `sampler_visible`, `color_modes_visible`, `sliders_visible` and `presets_visible` all exist in the 4.5.2 class reference, none deprecated, and the dock scene loads and instantiates without errors. 4.5 deprecates `ColorPicker.MODE_RAW` (value 2, replaced by `MODE_LINEAR`), but the scene uses `color_mode = 1` (`MODE_HSV`), so it's unaffected. Whether the dock *looks* the same is manual check item 1.

## Manual checklist (user, Godot 4.5 editor)

Open `tests/manual_test.tscn` with `~/projects/godot/godot-plugins/.godot-bins/godot-4.5 --path . -e`, then check:

- [ ] 1. The plugin enables without an error dialog, and the dock appears top-left. The color picker shows an HSV wheel/square with no sampler, mode buttons, sliders or presets, the same as on 4.2.
- [ ] 2. Select `PaintMe`, tick **Enable Vertex Painting**. A left-drag on the mesh paints the picked color at the cursor.
- [ ] 3. With **Show Debug Sphere** on, the sphere follows the surface under the cursor, with no offset or lag.
- [ ] 4. Clicking empty space (sky) paints nothing and prints no errors.
- [ ] 5. Save, close and reopen the scene. The painted colors are still there.
- [ ] 6. Untick the checkbox. Normal selection and gizmos work again.

Result: _pending_
