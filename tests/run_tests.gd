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
		test_stop_paint_unlocks(p3d)
	inst.queue_free()
	await process_frame


# B9: stop_paint() must REMOVE _edit_lock_. The editor checks has_meta() for
# the lock icon, gizmos and applying transforms, so a meta set to false still
# leaves the mesh locked after the first stroke.
func test_stop_paint_unlocks(p3d: Node) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = BoxMesh.new()
	root.add_child(mi)
	mi.set_meta("_edit_lock_", true)  # what start_paint() does
	p3d.mesh_i = mi
	p3d.stop_paint()
	check(not mi.has_meta("_edit_lock_"), "B9: stop_paint() removes _edit_lock_ meta")
	mi.free()


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
