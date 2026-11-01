@tool
extends EditorPlugin
## Test-only editor plugin, run in a WINDOWED editor (the depth readback needs
## a real renderer). Builds a scene with a subdivided plane (plus boxes on and
## beyond it), selects the plane, enables painting and clicks through the
## plugin with the editor's own 3D camera. Each click must paint only vertices
## near the plane point under the cursor. Prints PAINT_PROBE lines and quits.
## Env: PAINT_PROBE_BIG=1 (500 m plane 100 m below the camera),
## PAINT_PROBE_NORMAL=1 (Normal paint mode). Run via tests/check_editor_paint.sh.

const SCENE := "res://.godot/test-logs/editor_paint_probe.tscn"
const SETTLE := 30


func _enter_tree() -> void:
	_run.call_deferred()


func _wait(n := SETTLE) -> void:
	for i in n:
		await get_tree().process_frame


func _painter() -> Node:
	var stack: Array[Node] = [EditorInterface.get_base_control()]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node.name == "VertexPainter" and node.get_node_or_null("VertexPainter3D") != null:
			return node
		stack.append_array(node.get_children())
	return null


func _build_scene() -> void:
	var root := Node3D.new()
	root.name = "PaintProbe"
	var plane := MeshInstance3D.new()
	plane.name = "Plane"
	var pm := PlaneMesh.new()
	pm.size = Vector2(10, 10)
	pm.subdivide_width = 98
	pm.subdivide_depth = 98
	plane.mesh = pm
	if OS.get_environment("PAINT_PROBE_BIG") == "1":
		plane.scale = Vector3(50, 50, 50)
		plane.position = Vector3(0, -100, 0)
	root.add_child(plane)
	plane.owner = root
	var boxes := [[Vector3(1, 0.5, 0), Vector3(1, 1, 1)], [Vector3(-2, 0.5, 1), Vector3(1, 1, 1)],
		[Vector3(0, 3, -12), Vector3(20, 6, 2)]]
	for i in boxes.size():
		var b := MeshInstance3D.new()
		b.name = "Box%d" % i
		var bm := BoxMesh.new()
		bm.size = boxes[i][1]
		b.mesh = bm
		b.position = boxes[i][0]
		root.add_child(b)
		b.owner = root
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-50, 30, 0)
	root.add_child(light)
	light.owner = root
	var packed := PackedScene.new()
	packed.pack(root)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SCENE.get_base_dir()))
	ResourceSaver.save(packed, SCENE)
	root.free()


func _click(p3d: Node, cam: Camera3D, pos: Vector2) -> void:
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = pos
	p3d.forward_3d_input(cam, press)
	await _wait(10)
	var release := press.duplicate() as InputEventMouseButton
	release.pressed = false
	p3d.forward_3d_input(cam, release)
	await _wait(10)


var _py := 0.0
var _ps := 1.0


func _ground(cam: Camera3D, pos: Vector2) -> Vector3:
	var o := cam.project_ray_origin(pos)
	var d := cam.project_ray_normal(pos)
	if d.y >= -0.01:
		return Vector3(INF, INF, INF)
	var g := o + d * ((_py - o.y) / d.y)
	if absf(g.x) > 5.0 * _ps or absf(g.z) > 5.0 * _ps:
		return Vector3(INF, INF, INF)
	return g


func _on_plane(cam: Camera3D, pos: Vector2) -> bool:
	var g := _ground(cam, pos)
	return g.is_finite() and absf(g.x) < 4.5 * _ps and absf(g.z) < 4.5 * _ps


func _colors(plane: MeshInstance3D) -> PackedColorArray:
	var arr := plane.mesh.surface_get_arrays(0)
	return arr[Mesh.ARRAY_COLOR] if arr[Mesh.ARRAY_COLOR] != null else PackedColorArray()


func _run() -> void:
	await _wait()
	EditorInterface.set_main_screen_editor("3D")
	_build_scene()
	EditorInterface.open_scene_from_path(SCENE)
	await _wait()
	EditorInterface.reload_scene_from_path(SCENE)
	await _wait()
	var root := EditorInterface.get_edited_scene_root()
	var plane: MeshInstance3D = root.get_node("Plane")
	_py = plane.global_position.y
	_ps = plane.scale.x
	var painter := _painter()
	var p3d := painter.get_node("VertexPainter3D")
	var sel := EditorInterface.get_selection()
	sel.clear()
	sel.add_node(plane)
	await _wait()
	painter.get_node("VBoxContainer/EnableCheckBox").button_pressed = true
	await _wait()
	if OS.get_environment("PAINT_PROBE_NORMAL") == "1":
		var opt: OptionButton = p3d._mode_option
		opt.select(1)
		opt.item_selected.emit(1)
		await _wait()
	var cam := EditorInterface.get_editor_viewport_3d(0).get_camera_3d()
	var vp_size := EditorInterface.get_editor_viewport_3d(0).get_visible_rect().size
	print("PAINT_PROBE camera=%s viewport=%s target=%s layers=%d" % [cam.global_position, vp_size, p3d.target, plane.layers])
	# Warm-up click: the first stroke turns the PlaneMesh into a painted
	# ArrayMesh (every vertex gets a color), which the checks below can't diff.
	for tries in 50:
		var p := Vector2(randf_range(0.3, 0.7) * vp_size.x, randf_range(0.6, 0.9) * vp_size.y)
		if _on_plane(cam, p):
			await _click(p3d, cam, p)
			break
	var ok := plane.mesh is ArrayMesh
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var clicks := 0
	var worst := 0.0
	for i in 40:
		var pos := Vector2(rng.randf_range(0.05, 0.95) * vp_size.x, rng.randf_range(0.05, 0.95) * vp_size.y)
		var o := cam.project_ray_origin(pos)
		var g := _ground(cam, pos)
		if not g.is_finite():
			continue
		# Skip points where a box is in front of the plane (the expected
		# result there is a matter of design, not this check).
		var hidden := false
		for b in [root.get_node("Box0"), root.get_node("Box1"), root.get_node("Box2")]:
			var aabb: AABB = b.global_transform * b.mesh.get_aabb()
			if aabb.grow(0.05).intersects_segment(o, g):
				hidden = true
		if hidden:
			continue
		painter.get_node("VBoxContainer/ColorPicker").color = Color(rng.randf(), rng.randf(), rng.randf(), 1)
		var before := _colors(plane)
		await _click(p3d, cam, pos)
		var after := _colors(plane)
		var verts: PackedVector3Array = plane.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var n := 0
		var far := 0.0
		for v in after.size():
			if not after[v].is_equal_approx(before[v]):
				n += 1
				var dist := (plane.global_transform * verts[v]).distance_to(g)
				if dist > 0.5 * _ps and n < 4:
					print("PAINT_PROBE   far v%d dist=%.1f before=%s after=%s" % [v, dist, before[v], after[v]])
				far = maxf(far, dist)
		clicks += 1
		worst = maxf(worst, far)
		var good := n > 0 and far < 0.5 * _ps
		ok = ok and good
		print("PAINT_PROBE click %d at %s ground=%s painted=%d farthest=%.2f m %s" % [i, pos, g, n, far, "PASS" if good else "FAIL"])
	print("PAINT_PROBE clicks=%d worst=%.2f m" % [clicks, worst])

	# Drags: one motion event per frame, like a real mouse, between random
	# points on the plane (some crossing the boxes). Every painted vertex must
	# lie near the plane points under the cursor path.
	for k in 8:
		var a := Vector2.ZERO
		var b := Vector2.ZERO
		for tries in 200:
			a = Vector2(rng.randf_range(0.05, 0.95) * vp_size.x, rng.randf_range(0.3, 0.95) * vp_size.y)
			b = Vector2(rng.randf_range(0.05, 0.95) * vp_size.x, rng.randf_range(0.3, 0.95) * vp_size.y)
			if _on_plane(cam, a) and _on_plane(cam, b):
				break
		var path: Array[Vector3] = []
		painter.get_node("VBoxContainer/ColorPicker").color = Color(rng.randf(), rng.randf(), rng.randf(), 1)
		var before := _colors(plane)
		var press := InputEventMouseButton.new()
		press.button_index = MOUSE_BUTTON_LEFT
		press.pressed = true
		press.position = a
		p3d.forward_3d_input(cam, press)
		var steps := 60
		for i in steps + 1:
			var pos := a.lerp(b, float(i) / steps)
			var g := _ground(cam, pos)
			if g.is_finite():
				path.append(g)
			var m := InputEventMouseMotion.new()
			m.position = pos
			m.relative = (b - a) / steps
			m.button_mask = MOUSE_BUTTON_MASK_LEFT
			p3d.forward_3d_input(cam, m)
			await get_tree().process_frame
		var release := press.duplicate() as InputEventMouseButton
		release.pressed = false
		release.position = b
		p3d.forward_3d_input(cam, release)
		await _wait(15)
		var after := _colors(plane)
		var verts: PackedVector3Array = plane.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var n := 0
		var far := 0.0
		for v in after.size():
			if not after[v].is_equal_approx(before[v]):
				n += 1
				var w := plane.global_transform * verts[v]
				var nearest := INF
				for g in path:
					nearest = minf(nearest, w.distance_to(g))
				far = maxf(far, nearest)
		var good := n > 0 and far < 0.6 * _ps
		ok = ok and good
		print("PAINT_PROBE drag %d %s -> %s painted=%d farthest_from_path=%.2f m %s" % [k, a, b, n, far, "PASS" if good else "FAIL"])
	ok = ok and clicks > 5
	print("PAINT_PROBE_RESULT %s" % ("PASS" if ok else "FAIL"))
	painter.get_node("VBoxContainer/EnableCheckBox").button_pressed = false
	await _wait()
	get_tree().quit(0 if ok else 1)
