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
	for path in ["res://tests/manual_test.tscn", "res://tests/depth_probe.tscn"]:
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
	var r1: Array[int] = painter.get_n_closest_vertices(big, Vector3.ZERO, Vector3(50, 0, 0), 2)
	check(_sorted(r1) == [4, 5], "large mesh, n=2, hit at x=50 -> [4, 5] (got %s)" % [r1])

	var r2: Array[int] = painter.get_n_closest_vertices(big, Vector3(-50, 0, 0), Vector3.ZERO, 3)
	check(_sorted(r2) == [3, 4, 5], "large mesh, mesh_pos offset, n=3 -> [3, 4, 5] (got %s)" % [r2])

	# Small spacing: squared distances < 1. Before the B1 fix (`furthest_dist`
	# was an int) these truncated to 0 and this returned [0, 1].
	var small := _line_mdt([0.0, 0.1, 0.2, 0.3, 0.4, 0.5])
	var r3: Array[int] = painter.get_n_closest_vertices(small, Vector3.ZERO, Vector3(0.5, 0, 0), 2)
	check(_sorted(r3) == [4, 5], "small mesh, n=2, hit at x=0.5 -> [4, 5] (B1 fixed, got %s)" % [r3])

	# The manual-test sphere (radius 1): with brush size 5, the painted vertices
	# must include the true closest one and stay near the cursor. Before the B1
	# fix they sat near the top cap, up to ~1 unit away.
	var sphere := MeshDataTool.new()
	sphere.create_from_surface(load("res://tests/manual_test_mesh.res"), 0)
	for hit in [Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(0, -1, 0), Vector3(0.6, 0.0, -0.8)]:
		var picked: Array[int] = painter.get_n_closest_vertices(sphere, Vector3.ZERO, hit, 5)
		var closest: int = painter.get_closest_vertex(sphere, Vector3.ZERO, hit)
		var far := 0.0
		for i in picked:
			far = maxf(far, sphere.get_vertex(i).distance_to(hit))
		check(picked.size() == 5 and closest in picked and far < 0.3,
			"sphere hit %s: 5 vertices incl. closest, max dist %.3f < 0.3" % [hit, far])

	# n >= vertex count returns everything.
	var r4: Array[int] = painter.get_n_closest_vertices(small, Vector3.ZERO, Vector3.ZERO, 10)
	check(_sorted(r4) == [0, 1, 2, 3, 4, 5], "n > vertex count returns all (got %s)" % [r4])

	# get_closest_vertex never had B1.
	check(painter.get_closest_vertex(small, Vector3.ZERO, Vector3(0.31, 0, 0)) == 3,
		"get_closest_vertex small mesh -> 3")
	painter.free()
