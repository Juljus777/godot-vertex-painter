# Vertex Painter: incremental Godot upgrade plan (4.2 → 4.7)

## Goal

Port `addons/vertex_painter` from Godot 4.2 (its last supported version) to Godot 4.7, one minor version at a time.
Each version lives on its own branch, cut from the previous version's branch:

```
main (upstream 2.0, untouched)
 └─ godot-4.2   baseline + test harness, verified on 4.2
     └─ godot-4.3
         └─ godot-4.4
             └─ godot-4.5
                 └─ godot-4.6
                     └─ godot-4.7
                         └─ feature/*   (optional, see "Backlog")
```

Repo: `~/projects/godot/godot-plugins/godot-vertex-painter`. Remote: `origin` = `git@github.com:Juljus777/godot-vertex-painter.git`.

---

## Rules for every agent

1. **Scope:** only make changes needed for the branch's target Godot version to load and run the plugin with **zero errors and zero new warnings**. Do not add features or refactor. Feature work goes in the Backlog section.
2. **Branching:** create `godot-4.X` from the *tip* of `godot-4.(X-1)`, and only after that task is marked done. Never rebase a pushed branch.
3. **Fix-forward:** if a bug is found in an earlier branch, fix it on the **earliest affected branch**, then `git merge` that branch forward into each later branch in order, re-running that branch's checks after each merge.
4. **Resaving is expected:** opening the project in a newer editor rewrites `.tscn`/`.tres` headers and may generate `.uid` files (4.4+). Commit these changes in a separate commit titled `Resave resources with Godot 4.X`, apart from the code fixes, so diffs stay reviewable.
5. **Sources of truth:** for each version, read the official migration guide *"Upgrading from Godot 4.(X-1) to 4.X"* (docs.godotengine.org → Migrating to a new version), plus the release notes. The "Suspected changes" listed under each task are leads to verify, not confirmed facts.
6. **Commits** end with the attribution line required by the agent's environment. Push each branch to `origin` when its task is done.
7. **Manual check:** the user must verify painting in the editor by hand (an agent can't click in the editor). Every version task ends by writing a short result to `docs/verification/godot-4.X.md` and marking it `awaiting-manual-check`.

---

## Task 0: Godot binaries (DONE, 2026-11-01)

The official standard Linux x86_64 builds are installed and checksum-verified against each release's `SHA512-SUMS.txt`, in `~/projects/godot/godot-plugins/.godot-bins/`:

| Binary | Version |
|---|---|
| `godot-4.2` | 4.2.2-stable |
| `godot-4.3` | 4.3-stable |
| `godot-4.4` | 4.4.1-stable |
| `godot-4.5` | 4.5.2-stable |
| `godot-4.6` | 4.6.3-stable |
| `godot-4.7` | 4.7.2-stable |

Every later task uses `GODOT=~/projects/godot/godot-plugins/.godot-bins/godot-4.X`. Always pass `--headless` unless a step needs rendering.
Do not use the user's App Center (snap) Godot (`godot-4`, 4.7.2) in automated steps. It runs sandboxed and is the user's own editor. The user will use it for the 4.7 manual check.

---

## Task 1: `godot-4.2` baseline + test harness

Depends on: Task 0. Branch from `main`.

The repo only contains `addons/`, so there's nothing to run. Add a dev project at the repo root. The existing `.gitattributes` export-ignores everything outside `addons/`, so none of this ships to the Asset Library.

1. Add `project.godot` at the repo root (Forward+ renderer). Enable the plugin with `[editor_plugins] enabled=PackedStringArray("res://addons/vertex_painter/plugin.cfg")`.
2. Update `.gitignore`: add `.godot/`. The current file only has Godot 3's `.import/`.
3. Add `tests/run_tests.gd`, a `SceneTree` script run with `$GODOT --headless --path . --script res://tests/run_tests.gd`. It exits with code 0 on pass and 1 on fail, and covers:
   - loading every `.gd`, `.gdshader`, `.tscn` and `.tres` under `addons/vertex_painter/` without errors
   - instantiating `v2/vertex_painter.tscn`
   - **MeshDataTool round trip:** build an `ArrayMesh` from `SphereMesh.get_mesh_arrays()`, then run `create_from_surface` → `set_vertex_color` → `commit_to_surface` on a new `ArrayMesh` (the same flow as `start_paint()`/`paint()`), and assert that the colors read back correctly
   - `get_n_closest_vertices()` on a small known mesh (call it on a `vertex_painter_3d.gd` instance that isn't in the tree). Use expected values that match the **current** behavior, including known bugs (see Backlog B1). This is a regression guard, not a correctness spec.
4. Add `tests/check_editor.sh`. It runs `$GODOT --headless --path . --editor --quit`, then `run_tests.gd`. It saves both logs and fails if the output contains `SCRIPT ERROR`, `Parse Error`, `ERROR:` or `WARNING:` lines coming from `res://addons/` or `res://tests/`.
5. Add `tests/depth_probe.tscn` + `tests/depth_probe.gd`, a **rendered** (not headless) smoke test of the depth-readback ray cast in `click_raycast2()`/`gpu_depth.gdshader`.
   - It reuses the plugin's `SubViewport` + `MouseCamera3D` + `ScreenQuad` setup and places a plane at a known distance (for example, 7.0 units).
   - It reads the decoded depth the same way `click_raycast2()` does, prints `DEPTH_PROBE expected=7.0 got=<value>`, and quits. The pass tolerance is ±0.05.
   - Run it with `$GODOT --path . res://tests/depth_probe.tscn --quit-after 30`. It needs a display or GPU. If none is available, record `SKIPPED (no display)` and leave it to the manual check.
6. Add `tests/manual_test.tscn`: a MeshInstance3D with a subdivided `ArrayMesh` saved as a resource, plus a light and a camera, for the user's manual check.
7. Run everything on 4.2 and record the results in `docs/verification/godot-4.2.md`. The baseline may contain known warnings from upstream code. List them there; later versions must not add new ones.
8. Commit, then push `godot-4.2`.

**Done when:** `check_editor.sh` passes on 4.2, the depth probe passes or is recorded as skipped, and the branch is pushed.

---

## Version tasks (Tasks 2–6): the same procedure for each

For each target `4.X`, in order 4.3 → 4.4 → 4.5 → 4.6 → 4.7:

1. `git switch godot-4.(X-1) && git switch -c godot-4.X`
2. Open the project in the editor once to reimport and resave: `$GODOT --headless --path . --editor --quit`. Commit the resource churn separately (Rule 4).
3. Run `tests/check_editor.sh` and the depth probe. Fix every error and new warning, guided by the migration guide.
4. Remove deprecated API usage that the new version reports as deprecated, **only if** the replacement exists in this version. Don't jump ahead to APIs from later versions.
5. Bump `plugin.cfg` `version` to `2.0-godot4.X`. Update the README's "Godot Versions Tested" list.
6. Write `docs/verification/godot-4.X.md`. Include the commands run, pass/fail results, each change with its reason, the depth probe output, and a copy of the manual checklist below.
7. Commit, push, and mark the task `awaiting-manual-check`.

### Task 2: `godot-4.3` (depends on Task 1)
Suspected changes to verify:
- **Reversed-Z depth buffer (4.3).** This is the highest risk in this port. `gpu_depth.gdshader` builds NDC from `SCREEN_UV` + depth and goes through `INV_PROJECTION_MATRIX`. That pattern should survive the change, but the sky-or-miss handling in `click_raycast2()` (`is_zero_approx(normalized_distance)`, `> 0.9999`) depends on what an empty pixel decodes to. The depth probe must pass, and you should also probe a miss with no geometry behind the cursor.
- `EditorPlugin.get_editor_interface()` has been deprecated since 4.2 in favor of the `EditorInterface` singleton. Migrate `vertex_painter.gd`/`set_interface()` only if 4.3 warns about it.

### Task 3: `godot-4.4` (depends on Task 2)
Suspected changes to verify:
- **`.uid` files** are generated for scripts and shaders, and `ext_resource` entries gain `uid=`. Commit all `.uid` files.
- GDScript checks are stricter. The narrowing assignment in `get_n_closest_vertices()` (`var furthest_dist := 0` is an int, but it's assigned a float) may now warn. If it does, only change the declaration to `0.0`. That also fixes Backlog B1, so update the regression test's expected values in the same commit and say so in the verification doc.

### Task 4: `godot-4.5` (depends on Task 3)
Suspected changes to verify:
- The scene or resource file format headers change (for example, `load_steps` is no longer written). This is resave churn only.
- `ColorPicker` properties changed. The scene sets `color_mode`, `sampler_visible`, `color_modes_visible`, `sliders_visible` and `presets_visible`. Check that each one still exists and that the dock looks the same.

### Task 5: `godot-4.6` (depends on Task 4)
Suspected changes to verify:
- **The editor dock system was reworked.** `add_control_to_dock(DOCK_SLOT_LEFT_UR, …)` / `remove_control_from_docks()` may be deprecated in favor of a new dock API. If it is, migrate `vertex_painter.gd` to it, keeping the same left-upper placement.
- Nodes in `.tscn` files gain `unique_id=` (resave churn).
- The plugin reads 3D viewport input through `_input()` on a dock control and does a bounds check that hardcodes 30 px (`evnp.y > s_pos.y + 30`) for the viewport toolbar. Check that clicks in the 3D viewport still reach `_input()` and aren't consumed first, and that the 30 px offset still matches the toolbar height.

### Task 6: `godot-4.7` (depends on Task 5)
This is the user's target version (the `atmosphere` project runs 4.7).
- Follow the 4.6→4.7 migration guide and release notes.
- Also install the addon into `~/projects/godot/atmosphere/addons/vertex_painter/` (copy it, don't symlink). Confirm that the `atmosphere` project opens headless with no addon errors. **Do not modify `game.tscn` or other atmosphere files.**

---

## Manual checklist (the user runs this for each branch)

In `tests/manual_test.tscn`, using the matching editor version:

1. The plugin enables without an error dialog, and the dock appears top-left.
2. Select the MeshInstance3D and tick **Enable Vertex Painting**. A left-drag on the mesh paints the picked color at the cursor.
3. With **Show Debug Sphere** on, the sphere follows the surface under the cursor, with no offset or lag (this confirms the depth readback).
4. Clicking empty space (sky) paints nothing and prints no errors.
5. Save, close and reopen the scene. The painted colors are still there.
6. Untick the checkbox. Normal selection and gizmos work again.

The user records pass/fail in `docs/verification/godot-4.X.md`. If anything fails, a fix task is opened on that branch and merged forward (Rule 3).

---

## Backlog (not part of the port; optional `feature/*` branches from `godot-4.7`)

These are existing bugs or limits in the upstream code. They matter for using the plugin to hand-paint AO on placed rocks in `atmosphere`.

- **B1:** `get_n_closest_vertices()` declares `furthest_dist := 0` as an int, so squared distances below 1 truncate to 0 and the "closest N" selection breaks on small meshes. (This may already be fixed in Task 3.)
- **B2:** Vertex positions use `mdt.get_vertex(v) + mesh_i.global_position`, which ignores **rotation and scale**. The README says "scale must be applied", but placed rocks are rotated and scaled. Fix: transform the hit point with `mesh_i.global_transform.affine_inverse()`.
- **B3:** The material swap isn't undone. `start_paint()` replaces surface 0's override with the vertex color debug shader, and `stop_paint()` only restores when `pre_mat == null`, which leaves the debug shader on. For AO, the original material must stay and only vertex color should change.
- **B4:** Only surface 0 is read or painted. Multi-material meshes lose their other surfaces when `mesh_i.mesh = ArrayMesh.new()` runs.
- **B5:** The brush size is a **vertex count**, not a radius, and there's no falloff or strength. For AO, use a world-space radius with falloff and paint a grayscale value with a multiply or blend amount.
- **B6:** `commit_to_surface()` runs once per vertex inside the loop in `paint()`/`legacy_paint()`. Move it after the loop.
- **B7:** Painting doesn't support undo. Wrap each stroke in `EditorUndoRedoManager`.
- **B8:** Clean out dead code: `v2/button.gd`, `v2/main_screen.tscn`, and the legacy physics ray path.
- **Note:** painting a MeshInstance3D inside an instanced `.glb` stores a new `ArrayMesh` override **in the parent scene**, one per instance. That's exactly what per-placement AO needs, but it grows the `.tscn` size and detaches those instances from later `.glb` re-exports. Document this in the README.
