extends SceneTree
## Headless regression tests for the vertex_painter addon.
## Run: $GODOT --headless --path . --script res://tests/run_tests.gd
## Exits 0 when every check passes, 1 otherwise.

const ADDON_DIR := "res://addons/vertex_painter/"
const LOADABLE_EXTS := ["gd", "gdshader", "tscn", "tres"]
const PAINTER_SCENE := "res://addons/vertex_painter/v2/vertex_painter.tscn"
const PAINTER_3D_SCRIPT := "res://addons/vertex_painter/v2/vertex_painter_3d.gd"

var _failures := 0
var _checks := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	print("== vertex_painter tests (Godot %s) ==" % Engine.get_version_info().string)
	test_load_all_resources()
	await test_instantiate_painter_scene()
	test_mdt_round_trip()
	test_get_n_closest_vertices()
	print("== %d checks, %d failed ==" % [_checks, _failures])
	print("TESTS %s" % ("FAILED" if _failures > 0 else "PASSED"))
	quit(1 if _failures > 0 else 0)


func check(cond: bool, what: String) -> void:
	_checks += 1
	if cond:
		print("  ok   ", what)
	else:
		_failures += 1
		printerr("  FAIL ", what)


# --- 1. every addon resource loads -----------------------------------------

func _collect_files(dir_path: String, out: Array[String]) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	for sub in dir.get_directories():
		_collect_files(dir_path.path_join(sub), out)
	for f in dir.get_files():
		if f.get_extension() in LOADABLE_EXTS:
			out.append(dir_path.path_join(f))


func test_load_all_resources() -> void:
	print("[load all addon resources]")
	var files: Array[String] = []
	_collect_files(ADDON_DIR, files)
	files.sort()
	check(files.size() > 0, "found addon files to load")
	for path in files:
		var res := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
		var ok := res != null
		if ok and res is GDScript:
			ok = (res as GDScript).can_instantiate()
		if ok and res is PackedScene:
			ok = (res as PackedScene).can_instantiate()
		check(ok, "load " + path)
	# The test scenes themselves must load too (they're used by the rendered
	# probe and the manual check).
	for path in ["res://tests/manual_test.tscn", "res://tests/depth_probe.tscn",
			"res://tests/instanced_rock.tscn", "res://tests/manual_test_instanced.tscn"]:
		var ps := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
		check(ps != null and ps.can_instantiate(), "load " + path)


# --- 2. the dock scene instantiates and enters the tree --------------------

func test_instantiate_painter_scene() -> void:
	print("[instantiate dock scene]")
	var packed: PackedScene = load(PAINTER_SCENE)
	check(packed != null, "load vertex_painter.tscn")
	if packed == null:
		return
	var inst := packed.instantiate()
	check(inst != null, "instantiate vertex_painter.tscn")
	if inst == null:
		return
	root.add_child(inst)
	await process_frame
	var p3d := inst.get_node_or_null("VertexPainter3D")
	check(p3d != null, "VertexPainter3D child exists")
	check(inst.get_node_or_null("SubViewport/MouseCamera3D/ScreenQuad") != null,
		"SubViewport/MouseCamera3D/ScreenQuad exists")
	if p3d != null:
		check(p3d.brush_size == 5, "brush size parsed from BrushLineEdit (5)")
		test_forward_3d_input(p3d)
		await test_paint_lock(p3d)
		test_paint_material(p3d)
		test_brush_controls(p3d)
		test_ctrl_select(p3d)
	inst.queue_free()
	await process_frame


func _mouse_button(button: MouseButton, pressed: bool) -> InputEventMouseButton:
	var ev := InputEventMouseButton.new()
	ev.button_index = button
	ev.pressed = pressed
	ev.position = Vector2(10, 10)
	return ev


func _mouse_motion(left_held: bool) -> InputEventMouseMotion:
	var ev := InputEventMouseMotion.new()
	ev.position = Vector2(12, 10)
	ev.button_mask = MOUSE_BUTTON_MASK_LEFT if left_held else 0
	return ev


# F3: painting input arrives through EditorPlugin._forward_3d_gui_input().
# forward_3d_input() returns true when the editor must NOT also handle the
# event (select/transform). Headless has no depth image, so every press is a
# miss here; routing and consumption are what's under test.
func test_forward_3d_input(p3d: Node) -> void:
	var cam := Camera3D.new()
	root.add_child(cam)
	var mi := MeshInstance3D.new()
	mi.mesh = BoxMesh.new()
	root.add_child(mi)
	var enable: CheckBox = p3d.get_node("../VBoxContainer/EnableCheckBox")

	enable.button_pressed = false
	p3d.set_target(mi)
	check(not p3d.forward_3d_input(cam, _mouse_button(MOUSE_BUTTON_LEFT, true)),
		"F3: painting disabled -> left click passes through to the editor")

	enable.button_pressed = true
	p3d.set_target(null)
	check(not p3d.forward_3d_input(cam, _mouse_button(MOUSE_BUTTON_LEFT, true)),
		"F3: no MeshInstance3D edited -> left click passes through")

	p3d.set_target(mi)
	check(not p3d.forward_3d_input(cam, _mouse_button(MOUSE_BUTTON_RIGHT, true)),
		"F3: right button passes through (camera navigation)")
	check(not p3d.forward_3d_input(cam, _mouse_motion(false)),
		"F3: hover without a stroke passes through")
	check(p3d.forward_3d_input(cam, _mouse_button(MOUSE_BUTTON_LEFT, true)),
		"F3: left press is consumed while painting is enabled")
	check(p3d.forward_3d_input(cam, _mouse_button(MOUSE_BUTTON_LEFT, false)),
		"F3: left release is consumed")
	check(not p3d.click_active, "F3: release ends the stroke")

	# F5: a press that misses the mesh still owns the drag until release, so the
	# editor never sees a left-held drag without its press.
	p3d.forward_3d_input(cam, _mouse_button(MOUSE_BUTTON_LEFT, true))
	check(p3d.forward_3d_input(cam, _mouse_motion(true)),
		"F5: drag after a (missed) press is consumed")
	p3d.forward_3d_input(cam, _mouse_button(MOUSE_BUTTON_LEFT, false))
	check(not p3d.forward_3d_input(cam, _mouse_motion(false)),
		"F5: hover after release passes through again")

	# A stroke whose release happened outside the viewport ends on the next
	# motion event without the left button held.
	p3d.click_active = true
	check(not p3d.forward_3d_input(cam, _mouse_motion(false)),
		"F3: motion after an outside release passes through")
	check(not p3d.click_active, "F3: motion after an outside release ends the stroke")

	enable.button_pressed = false
	p3d.set_target(null)
	cam.free()
	mi.free()


# F4: while "Enable Vertex Painting" is on, the edited mesh carries the
# _edit_lock_ meta (hides its transform gizmo). It must be REMOVED (not set to
# false, see B9) whenever painting stops applying to that mesh, must never be
# saved into a scene, and a lock the user set must never be touched.
func test_paint_lock(p3d: Node) -> void:
	var a := MeshInstance3D.new()
	var b := MeshInstance3D.new()
	root.add_child(a)
	root.add_child(b)
	var enable: CheckBox = p3d.get_node("../VBoxContainer/EnableCheckBox")
	enable.button_pressed = false
	p3d.set_target(a)
	check(not a.has_meta("_edit_lock_"), "F4: toggle off -> no lock")
	enable.button_pressed = true
	check(a.get_meta("_edit_lock_", false) == true, "F4: toggle on -> edited mesh locked (gizmo hidden)")
	enable.button_pressed = false
	check(not a.has_meta("_edit_lock_"), "F4: toggle off -> lock meta removed, not just false")

	enable.button_pressed = true
	p3d.set_target(b)
	check(not a.has_meta("_edit_lock_") and b.has_meta("_edit_lock_"),
		"F4: selecting another mesh moves the lock to it")
	p3d.set_target(null)
	check(not b.has_meta("_edit_lock_"), "F4: deselecting releases the lock")

	# Save: the editor calls _apply_changes() -> before_save() right before
	# writing the scene; the lock must be gone then and come back afterwards.
	p3d.set_target(a)
	p3d.before_save()
	check(not a.has_meta("_edit_lock_"), "F4: lock lifted for saving")
	var packed := PackedScene.new()
	var holder := Node3D.new()
	var copy := MeshInstance3D.new()
	holder.add_child(copy)
	copy.owner = holder
	for m in a.get_meta_list():
		copy.set_meta(m, a.get_meta(m))
	packed.pack(holder)
	var saved_path := "user://f4_lock_save_test.tscn"
	ResourceSaver.save(packed, saved_path)
	check(not FileAccess.get_file_as_string(saved_path).contains("_edit_lock_"),
		"F4: saved scene contains no _edit_lock_")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(saved_path))
	holder.free()
	await process_frame
	check(a.has_meta("_edit_lock_"), "F4: lock restored on the next frame after saving")

	# A lock the user set is never removed by us.
	enable.button_pressed = false
	b.set_meta("_edit_lock_", true)
	enable.button_pressed = true
	p3d.set_target(b)
	enable.button_pressed = false
	check(b.get_meta("_edit_lock_", false) == true, "F4: a user's own lock is left alone")

	# Leaving the tree (plugin disabled / dock removed) releases our lock.
	enable.button_pressed = true
	p3d.set_target(a)
	var parent := p3d.get_parent()
	parent.remove_child(p3d)
	check(not a.has_meta("_edit_lock_"), "F4: painter leaving the tree releases the lock")
	parent.add_child(p3d)
	check(a.has_meta("_edit_lock_"), "F4: painter re-entering the tree re-applies it")

	enable.button_pressed = false
	p3d.set_target(null)
	a.free()
	b.free()


# --- 3. MeshDataTool round trip (same flow as start_paint()/paint()) --------

func _color_for(i: int) -> Color:
	return Color((i % 7) / 6.0, (i % 5) / 4.0, (i % 3) / 2.0, 1.0)


func test_mdt_round_trip() -> void:
	print("[MeshDataTool round trip]")
	var src := ArrayMesh.new()
	src.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, SphereMesh.new().get_mesh_arrays())

	var mdt := MeshDataTool.new()
	check(mdt.create_from_surface(src, 0) == OK, "create_from_surface on sphere")
	var n := mdt.get_vertex_count()
	check(n > 0, "sphere has vertices (%d)" % n)

	# start_paint(): copy into a fresh ArrayMesh
	var painted := ArrayMesh.new()
	check(mdt.commit_to_surface(painted) == OK, "initial commit_to_surface")

	# paint(): set colors, clear, recommit
	for i in n:
		mdt.set_vertex_color(i, _color_for(i))
	painted.clear_surfaces()
	check(mdt.commit_to_surface(painted) == OK, "commit_to_surface after painting")
	check(painted.get_surface_count() == 1, "painted mesh has one surface")

	var back := MeshDataTool.new()
	check(back.create_from_surface(painted, 0) == OK, "create_from_surface on painted mesh")
	check(back.get_vertex_count() == n, "vertex count preserved")
	# Vertex colors are stored as 8 bits per channel (the encoder doesn't round
	# to nearest), so allow one full 8-bit step of error.
	const TOL := 1.0 / 255.0 + 1e-6
	var mismatches := 0
	var worst := 0.0
	for i in back.get_vertex_count():
		var got := back.get_vertex_color(i)
		var want := _color_for(i)
		var err := maxf(maxf(absf(got.r - want.r), absf(got.g - want.g)),
			maxf(absf(got.b - want.b), absf(got.a - want.a)))
		worst = maxf(worst, err)
		if err > TOL:
			mismatches += 1
	check(mismatches == 0, "all vertex colors read back within 8-bit precision (%d mismatches, worst error %.5f)" % [mismatches, worst])


# --- 4. get_n_closest_vertices regression guard ----------------------------

## Builds a mesh whose vertices lie on the X axis at the given coordinates.
func _line_mdt(xs: Array) -> MeshDataTool:
	var verts := PackedVector3Array()
	for x in xs:
		verts.append(Vector3(x, 0, 0))
	# Two triangles: 0-1-2 and 3-4-5 (vertices are spread along X, so these
	# are degenerate but MeshDataTool only needs valid indices).
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 3, 4, 5])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mdt := MeshDataTool.new()
	mdt.create_from_surface(mesh, 0)
	return mdt


func _sorted(a: Array[int]) -> Array[int]:
	var b := a.duplicate()
	b.sort()
	return b


func test_get_n_closest_vertices() -> void:
	print("[get_n_closest_vertices]")
	var script: GDScript = load(PAINTER_3D_SCRIPT)
	var painter: Node3D = script.new()  # not in tree; @onready vars stay null

	# Large spacing: squared distances >= 1, selection is correct.
	var big := _line_mdt([0.0, 10.0, 20.0, 30.0, 40.0, 50.0])
	var r1: Array[int] = painter.get_n_closest_vertices(big, Transform3D.IDENTITY, Vector3(50, 0, 0), 2)
	check(_sorted(r1) == [4, 5], "large mesh, n=2, hit at x=50 -> [4, 5] (got %s)" % [r1])

	var r2: Array[int] = painter.get_n_closest_vertices(big, Transform3D(Basis(), Vector3(-50, 0, 0)), Vector3.ZERO, 3)
	check(_sorted(r2) == [3, 4, 5], "large mesh, mesh_pos offset, n=3 -> [3, 4, 5] (got %s)" % [r2])

	# Small spacing: squared distances < 1. Before the B1 fix (`furthest_dist`
	# was an int) these truncated to 0 and this returned [0, 1].
	var small := _line_mdt([0.0, 0.1, 0.2, 0.3, 0.4, 0.5])
	var r3: Array[int] = painter.get_n_closest_vertices(small, Transform3D.IDENTITY, Vector3(0.5, 0, 0), 2)
	check(_sorted(r3) == [4, 5], "small mesh, n=2, hit at x=0.5 -> [4, 5] (B1 fixed, got %s)" % [r3])

	# The manual-test sphere (radius 1): with brush size 5, the painted vertices
	# must include the true closest one and stay near the cursor. Before the B1
	# fix they sat near the top cap, up to ~1 unit away.
	var sphere := MeshDataTool.new()
	sphere.create_from_surface(load("res://tests/manual_test_mesh.res"), 0)
	for hit in [Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(0, -1, 0), Vector3(0.6, 0.0, -0.8)]:
		var picked: Array[int] = painter.get_n_closest_vertices(sphere, Transform3D.IDENTITY, hit, 5)
		var closest: int = painter.get_closest_vertex(sphere, Transform3D.IDENTITY, hit)
		var far := 0.0
		for i in picked:
			far = maxf(far, sphere.get_vertex(i).distance_to(hit))
		check(picked.size() == 5 and closest in picked and far < 0.3,
			"sphere hit %s: 5 vertices incl. closest, max dist %.3f < 0.3" % [hit, far])

	# n >= vertex count returns everything.
	var r4: Array[int] = painter.get_n_closest_vertices(small, Transform3D.IDENTITY, Vector3.ZERO, 10)
	check(_sorted(r4) == [0, 1, 2, 3, 4, 5], "n > vertex count returns all (got %s)" % [r4])

	# get_closest_vertex never had B1.
	check(painter.get_closest_vertex(small, Transform3D.IDENTITY, Vector3(0.31, 0, 0)) == 3,
		"get_closest_vertex small mesh -> 3")

	# B2: a rotated, non-uniformly scaled, moved mesh (like the atmosphere
	# rocks). Hit = the world position of a known vertex; the brush must pick
	# it and stay near it. The old code (vertex + position only) picked
	# vertices far away.
	var xf := Transform3D(Basis(Vector3(0.3, 1, 0.2).normalized(), 1.1).scaled(Vector3(3.0, 0.7, 1.8)),
		Vector3(12, -4, 7))
	for v in [0, 300, 1000]:
		var world_hit: Vector3 = xf * sphere.get_vertex(v)
		var picked2: Array[int] = painter.get_n_closest_vertices(sphere, xf, world_hit, 5)
		var far2 := 0.0
		for i in picked2:
			far2 = maxf(far2, (xf * sphere.get_vertex(i)).distance_to(world_hit))
		check(painter.get_closest_vertex(sphere, xf, world_hit) == v and far2 < 0.6,
			"B2: rotated+scaled mesh, hit on vertex %d -> picked near it (max %.3f < 0.6)" % [v, far2])
	painter.free()

	# F6: meshes without vertex colors start white, not black.
	var plain := ArrayMesh.new()
	plain.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, SphereMesh.new().get_mesh_arrays())
	var mdt := MeshDataTool.new()
	mdt.create_from_surface(plain, 0)
	var painter2: Node3D = script.new()
	painter2.ensure_vertex_colors(mdt)
	mdt.set_vertex_color(0, Color.RED)
	var out := ArrayMesh.new()
	mdt.commit_to_surface(out)
	var cols: PackedColorArray = out.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
	check(cols[0] == Color.RED and cols[1] == Color.WHITE and cols[cols.size() - 1] == Color.WHITE,
		"F6: colorless mesh -> unpainted vertices stay white (not MeshDataTool's black)")
	painter2.free()


# F8: the plugin now receives ALL 3D viewport input (so Ctrl+click works with
# nothing selected). With painting off, nothing may be swallowed. Plus the
# Ctrl+click ray picking helpers (the full flow runs in the editor probe).
func test_ctrl_select(p3d: Node) -> void:
	var enable: CheckBox = p3d.get_node("../VBoxContainer/EnableCheckBox")
	var cam := Camera3D.new()
	root.add_child(cam)
	var mi := MeshInstance3D.new()
	mi.mesh = BoxMesh.new()
	root.add_child(mi)
	enable.button_pressed = false
	for t in [null, mi]:
		p3d.set_target(t)
		var events: Array[InputEvent] = [_mouse_button(MOUSE_BUTTON_LEFT, true),
			_mouse_button(MOUSE_BUTTON_LEFT, false), _mouse_button(MOUSE_BUTTON_RIGHT, true),
			_mouse_motion(true), _mouse_motion(false)]
		var ctrl_click := _mouse_button(MOUSE_BUTTON_LEFT, true)
		ctrl_click.ctrl_pressed = true
		events.append(ctrl_click)
		var alt_click := _mouse_button(MOUSE_BUTTON_LEFT, true)
		alt_click.alt_pressed = true
		events.append(alt_click)
		var swallowed := 0
		for ev in events:
			if p3d.forward_3d_input(cam, ev):
				swallowed += 1
		check(swallowed == 0, "F8: painting off, target=%s -> all %d events pass to the editor" % [t, events.size()])
	p3d.set_target(null)

	# Ray picking: nearest of two meshes along the ray; triangles, not just boxes.
	var scene := Node3D.new()
	root.add_child(scene)
	var near := MeshInstance3D.new()
	near.name = "Near"
	near.mesh = SphereMesh.new()
	near.position = Vector3(0, 0, -3)
	var far := MeshInstance3D.new()
	far.name = "Far"
	far.mesh = SphereMesh.new()
	far.position = Vector3(0, 0, -6)
	far.scale = Vector3(3, 3, 3)
	scene.add_child(near)
	scene.add_child(far)
	var o := Vector3.ZERO
	check(p3d.mesh_under_ray(scene, o, Vector3(0, 0, -1)) == near, "F8: ray picks the nearer mesh")
	# Through the near sphere's bounding-box corner (outside the sphere itself)
	# and on into the big far sphere: only an exact triangle test gets this right.
	check(p3d.mesh_under_ray(scene, o, Vector3(0.45, 0.45, -3).normalized()) == far,
		"F8: a ray through the near sphere's box corner (missing the sphere) hits the far one")
	check(p3d.mesh_under_ray(scene, o, Vector3(0, 1, 0)) == null, "F8: ray into empty space -> nothing")
	near.hide()
	check(p3d.mesh_under_ray(scene, o, Vector3(0, 0, -1)) == far, "F8: hidden meshes are ignored")
	scene.free()

	# Selectable node: instanced scene root unless its children are editable.
	var level: Node3D = Node3D.new()
	root.add_child(level)
	var rock: Node = load("res://tests/instanced_rock.tscn").instantiate()
	level.add_child(rock)
	rock.owner = level
	var rock_mesh: Node = rock.get_node("RockMesh")
	check(p3d.selectable_node_for(rock_mesh, level) == rock, "F8: mesh in a non-editable instance -> selects the instance")
	level.set_editable_instance(rock, true)
	check(p3d.selectable_node_for(rock_mesh, level) == rock_mesh, "F8: editable instance -> selects the mesh itself")
	level.free()
	cam.free()
	mi.free()


func _color_close(a: Color, b: Color) -> bool:
	return absf(a.r - b.r) < 0.006 and absf(a.g - b.g) < 0.006 and absf(a.b - b.b) < 0.006


# F7: full color picker, opacity (blends from the pre-stroke colors), and
# pick-from-mesh.
func test_brush_controls(p3d: Node) -> void:
	var box := p3d.get_node("../VBoxContainer")
	var picker: ColorPicker = box.get_node("ColorPicker")
	check(picker.sliders_visible and picker.color_modes_visible and picker.presets_visible
		and picker.sampler_visible, "F7: color picker shows sliders, modes, presets and eyedropper")
	var slider: HSlider = box.get_node_or_null("OpacityRow/OpacitySlider")
	var hint: Label = box.get_node_or_null("ShortcutHint")
	check(slider != null and hint != null and hint.text.contains("Alt") and hint.text.contains("Ctrl")
		and box.get_node_or_null("PickColorButton") == null,
		"F9: opacity slider + shortcut hint (Ctrl/Alt), no pick toggle button")
	if slider == null:
		return

	# Opacity: 50 % twice within ONE stroke stays at 50 %; a new stroke builds on it.
	var mi := MeshInstance3D.new()
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, SphereMesh.new().get_mesh_arrays())
	mi.mesh = mesh
	root.add_child(mi)
	p3d.mesh_i = mi
	p3d.active_mdt.create_from_surface(mesh, 0)
	p3d.ensure_vertex_colors(p3d.active_mdt)
	p3d.begin_stroke_colors()
	picker.color = Color.BLACK
	slider.value = 50
	var v0: Array[int] = [0]
	p3d.apply_brush(v0)
	p3d.apply_brush(v0)
	check(p3d.active_mdt.get_vertex_color(0).is_equal_approx(Color(0.5, 0.5, 0.5)),
		"F7: 50%% opacity, same spot twice in one stroke -> 0.5 grey (got %s)" % p3d.active_mdt.get_vertex_color(0))
	p3d.begin_stroke_colors()
	p3d.apply_brush(v0)
	check(p3d.active_mdt.get_vertex_color(0).is_equal_approx(Color(0.25, 0.25, 0.25)),
		"F7: a second stroke builds on the first -> 0.25 grey")
	check(p3d.active_mdt.get_vertex_color(1) == Color.WHITE, "F7: untouched vertices keep their color")
	var committed: PackedColorArray = mi.mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
	# Meshes store vertex colors as 8 bits per channel: compare within ~1/255.
	check(_color_close(committed[0], Color(0.25, 0.25, 0.25)), "F7: the mesh is rebuilt with the blended color (got %s)" % committed[0])
	slider.value = 100

	# Pick from mesh: color of the vertex nearest a world point.
	mi.global_transform = Transform3D(Basis().scaled(Vector3(2, 1, 3)), Vector3(5, 0, 0))
	var world_v0: Vector3 = mi.global_transform * p3d.active_mdt.get_vertex(0)
	check(_color_close(p3d.color_at(mi, world_v0), Color(0.25, 0.25, 0.25)),
		"F7: color_at() returns the nearest vertex's color on a moved/scaled mesh")
	var bare := MeshInstance3D.new()
	var bare_mesh := ArrayMesh.new()
	bare_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, SphereMesh.new().get_mesh_arrays())
	bare.mesh = bare_mesh
	root.add_child(bare)
	check(p3d.color_at(bare, Vector3.ZERO) == Color.WHITE, "F7: a mesh without vertex colors picks white")

	# F9: Alt+click / Alt+drag picks while painting is enabled; never paints.
	var enable: CheckBox = box.get_node("EnableCheckBox")
	enable.button_pressed = true
	var cam := Camera3D.new()
	root.add_child(cam)
	p3d.set_target(mi)
	mi.global_transform = Transform3D(Basis(), Vector3(0, 0, -4))  # in front of the camera
	var on_mesh := cam.unproject_position(mi.global_position)
	var before: PackedColorArray = mi.mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR]

	# F10: Alt+click off the selected mesh goes to the editor, whole drag
	# included ("Emulate 3 Button Mouse" orbit), and starts no stroke.
	var alt_off := _mouse_button(MOUSE_BUTTON_LEFT, true)
	alt_off.alt_pressed = true
	alt_off.position = Vector2(1, 1)
	check(not p3d.forward_3d_input(cam, alt_off), "F10: Alt+click off the mesh passes through (orbit)")
	check(not p3d.forward_3d_input(cam, _mouse_motion(true)), "F10: ... and its drag passes through")
	check(not p3d.forward_3d_input(cam, _mouse_button(MOUSE_BUTTON_LEFT, false)), "F10: ... and its release")
	check(not p3d._stroke_down and not p3d.click_active, "F10: no paint stroke from an Alt-orbit")

	var alt_press := _mouse_button(MOUSE_BUTTON_LEFT, true)
	alt_press.alt_pressed = true
	alt_press.position = on_mesh
	check(p3d.forward_3d_input(cam, alt_press), "F9/F10: Alt+click on the selected mesh is consumed (picks)")
	check(not p3d._stroke_down, "F9: Alt+click doesn't start a paint stroke")
	check(p3d.forward_3d_input(cam, _mouse_motion(true)), "F9: Alt+drag is consumed (keeps picking)")
	check(p3d.forward_3d_input(cam, _mouse_button(MOUSE_BUTTON_LEFT, false)), "F9: its release is consumed")
	check(not p3d.click_active and mi.mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR] == before,
		"F9: picking doesn't paint")
	var alt_rmb := _mouse_button(MOUSE_BUTTON_RIGHT, true)
	alt_rmb.alt_pressed = true
	check(not p3d.forward_3d_input(cam, alt_rmb), "F9: Alt+right-click passes through (editor's select-from-list)")
	check(p3d.forward_3d_input(cam, _mouse_button(MOUSE_BUTTON_LEFT, true)) and p3d._stroke_down,
		"F9: a plain click still paints (starts a stroke)")
	p3d.forward_3d_input(cam, _mouse_button(MOUSE_BUTTON_LEFT, false))
	enable.button_pressed = false
	p3d._pick_busy = false  # headless: the pick's depth readback never completes
	p3d.set_target(null)
	cam.free()
	mi.free()
	bare.free()


# F6 (B3): painting shows on the mesh's own material instead of replacing it.
func test_paint_material(p3d: Node) -> void:
	var tex := GradientTexture2D.new()
	var original := StandardMaterial3D.new()
	original.albedo_texture = tex
	original.albedo_color = Color(0.8, 0.5, 0.2)
	var mi := MeshInstance3D.new()
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, SphereMesh.new().get_mesh_arrays())
	mesh.surface_set_material(0, original)
	mi.mesh = mesh
	root.add_child(mi)

	check(p3d.prepare_paint_material(mi), "F6: StandardMaterial3D is handled")
	var used := mi.get_surface_override_material(0) as StandardMaterial3D
	check(used != null and used != original and used.vertex_color_use_as_albedo
		and used.albedo_texture == tex and used.albedo_color == original.albedo_color,
		"F6: paint shows on a copy of the mesh's material (texture and color kept)")
	check(not original.vertex_color_use_as_albedo, "F6: the original material is not modified")
	p3d.prepare_paint_material(mi)
	check(mi.get_surface_override_material(0) == used, "F6: later strokes reuse the same copy")

	var bare := MeshInstance3D.new()
	var bare_mesh := ArrayMesh.new()
	bare_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, SphereMesh.new().get_mesh_arrays())
	bare.mesh = bare_mesh
	root.add_child(bare)
	p3d.prepare_paint_material(bare)
	var bare_used := bare.get_surface_override_material(0) as BaseMaterial3D
	check(bare_used != null and bare_used.vertex_color_use_as_albedo, "F6: mesh without a material gets a vertex-color material")

	var shader_mi := MeshInstance3D.new()
	var shader_mesh := ArrayMesh.new()
	shader_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, SphereMesh.new().get_mesh_arrays())
	shader_mi.mesh = shader_mesh
	var custom := ShaderMaterial.new()
	shader_mi.set_surface_override_material(0, custom)
	shader_mi.name = "ShaderRock"
	root.add_child(shader_mi)
	check(not p3d.prepare_paint_material(shader_mi) and shader_mi.get_surface_override_material(0) == custom,
		"F6: a ShaderMaterial is left alone (and reported)")
	var hint: Label = p3d.get_node("../VBoxContainer/HintLabel")
	check(hint.visible and hint.text.contains("ShaderRock"), "F6: the dock explains why the paint may not show")
	p3d.show_instance_hint(null, null)
	check(not hint.visible, "F6: hint clears on the next selection")
	mi.free()
	bare.free()
	shader_mi.free()
