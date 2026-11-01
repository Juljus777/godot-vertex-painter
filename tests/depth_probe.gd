extends Node3D
## Rendered smoke test for the GPU depth readback used by click_raycast2().
## Run (needs a display/GPU, not --headless):
##   $GODOT --path . res://tests/depth_probe.tscn --quit-after 300
##
## Uses the plugin's own SubViewport/MouseCamera3D/ScreenQuad (from
## vertex_painter.tscn) and decodes the pixel exactly like click_raycast2().
## Prints one DEPTH_PROBE line per hit target, a MISS_PROBE line for empty
## space, then DEPTH_PROBE_RESULT PASS/FAIL. Exit code 0 on pass, 1 on fail.
## A hit passes within ±TOLERANCE of the true distance. (F18: the depth is a
## 24-bit integer over R, G, B now, ~6 mm steps; the old 2-channel encoding
## was off by 10+ m beyond ~350 m.)

const TOLERANCE := 0.05
## Distances from the mouse camera to the target planes (incl. far ones).
const HIT_DISTANCES := [7.0, 30.0, 350.0, 2000.0]
## Frames to wait after requesting an UPDATE_ONCE render before reading back.
const SETTLE_FRAMES := 4

@onready var painter: Control = $VertexPainter
@onready var target: MeshInstance3D = $Target

var mouse_camera_3d: Camera3D
var sub_viewport: SubViewport


func _ready() -> void:
	mouse_camera_3d = painter.get_node("SubViewport/MouseCamera3D")
	sub_viewport = painter.get_node("SubViewport")
	_run.call_deferred()


## Mirrors click_raycast2(): place the mouse camera at `origin` looking along
## `direction`, render once, decode pixel (0, 0) with the plugin's own
## decode_depth(). Returns the normalized distance, or -1 for a miss.
func _sample(origin: Vector3, direction: Vector3) -> float:
	mouse_camera_3d.show()  # start_paint() shows it; hidden by default
	mouse_camera_3d.global_position = origin
	mouse_camera_3d.look_at(origin + direction, Vector3.UP)
	sub_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	for i in SETTLE_FRAMES:
		await get_tree().process_frame
	var vp_img := sub_viewport.get_texture().get_image()
	return painter.get_node("VertexPainter3D").decode_depth(vp_img.get_pixel(0, 0))


## Same miss handling as click_raycast2(); returns -INF for a miss.
func _to_depth(normalized_distance: float) -> float:
	if normalized_distance < 0.0:
		return -INF
	return normalized_distance * mouse_camera_3d.far


## F13: does the Normal-mode paint layer actually render over the material?
## An isolated world: blue lit quad in front of a camera; read the center
## pixel unpainted (blue), painted red in Normal (red), then converted to
## Multiply (blue x red = near black).
func _render_pixel(sv: SubViewport) -> Color:
	sv.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	return sv.get_texture().get_image().get_pixel(32, 32)


func _mode_render_probe(p3d: Node) -> bool:
	var sv := SubViewport.new()
	sv.size = Vector2i(64, 64)
	sv.own_world_3d = true
	sv.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(sv)
	var cam := Camera3D.new()
	cam.position = Vector3(0, 0, 2)
	sv.add_child(cam)
	cam.current = true
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(0, 0, 0)  # shines along -Z, onto the quad's front
	sv.add_child(light)
	var quad_arrays := QuadMesh.new()
	quad_arrays.size = Vector2(2, 2)
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, quad_arrays.get_mesh_arrays())
	var blue := StandardMaterial3D.new()
	blue.albedo_color = Color(0, 0, 1)
	mesh.surface_set_material(0, blue)
	var quad := MeshInstance3D.new()
	quad.mesh = mesh
	sv.add_child(quad)

	var option: OptionButton = painter.get_node("VBoxContainer/ModeRow/ModeOption")
	var picker: ColorPicker = painter.get_node("VBoxContainer/ColorPicker")
	option.select(1)  # Normal
	p3d.mesh_i = quad
	p3d.active_mdt.create_from_surface(quad.mesh, 0)
	p3d.ensure_vertex_colors(p3d.active_mdt, 1)
	p3d.begin_stroke_colors()
	quad.mesh = ArrayMesh.new()
	p3d.active_mdt.commit_to_surface(quad.mesh)
	p3d.prepare_paint_material(quad, 1)
	var unpainted: Color = await _render_pixel(sv)

	picker.color = Color(1, 0, 0, 1)
	var all: Array[int] = []
	for v in p3d.active_mdt.get_vertex_count():
		all.append(v)
	p3d.apply_brush(all)
	var painted: Color = await _render_pixel(sv)

	# F16: a full-opacity erase removes the Normal paint: the blue shows again.
	p3d.begin_stroke_colors()
	p3d._erasing = true
	p3d.apply_brush(all)
	p3d._erasing = false
	var erased: Color = await _render_pixel(sv)
	p3d.begin_stroke_colors()
	p3d.apply_brush(all)  # paint red again for the Multiply conversion below

	p3d.convert_mesh_mode(quad, 0)  # -> Multiply
	var multiplied: Color = await _render_pixel(sv)

	var ok: bool = unpainted.b > 0.2 and unpainted.b > unpainted.r * 3.0 \
		and erased.b > 0.2 and erased.b > erased.r * 3.0 \
		and painted.r > 0.2 and painted.r > painted.b * 3.0 \
		and multiplied.r < 0.15 and multiplied.g < 0.15 and multiplied.b < 0.15  # black albedo; ~0.1 is the lit floor
	print("MODE_RENDER_PROBE normal_unpainted=%s normal_painted_red=%s erased=%s multiply_blue_x_red=%s %s" % [
		unpainted, painted, erased, multiplied, "PASS" if ok else "FAIL"])
	option.select(0)
	p3d.mesh_i = null
	sv.free()
	return ok


## F17: no fringe around Normal paint. Green lit plane, one vertex painted red
## (Normal, full opacity), its neighbors unpainted. Halfway to a neighbor the
## pixel must be a red/green mix with NO white in it: blue stays at the lit
## floor. With plain (straight) alpha the unpainted vertices' white leaked in.
func _halo_probe(p3d: Node) -> bool:
	var sv := SubViewport.new()
	sv.size = Vector2i(128, 128)
	sv.own_world_3d = true
	sv.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(sv)
	var cam := Camera3D.new()
	cam.position = Vector3(0, 0, 2)
	sv.add_child(cam)
	cam.current = true
	var light := DirectionalLight3D.new()
	sv.add_child(light)
	var plane_mesh := PlaneMesh.new()
	plane_mesh.size = Vector2(2, 2)
	plane_mesh.subdivide_width = 1
	plane_mesh.subdivide_depth = 1
	var green := StandardMaterial3D.new()
	green.albedo_color = Color(0, 1, 0)
	plane_mesh.material = green
	var plane := MeshInstance3D.new()
	plane.mesh = plane_mesh
	plane.rotation_degrees = Vector3(90, 0, 0)  # faces the camera
	sv.add_child(plane)

	var option: OptionButton = painter.get_node("VBoxContainer/ModeRow/ModeOption")
	var picker: ColorPicker = painter.get_node("VBoxContainer/ColorPicker")
	option.select(1)  # Normal
	p3d.mesh_i = plane
	p3d.load_mesh_for_paint(plane)
	p3d.ensure_vertex_colors(p3d.active_mdt, 1)
	p3d.begin_stroke_colors()
	plane.mesh = ArrayMesh.new()
	p3d.active_mdt.commit_to_surface(plane.mesh)
	p3d.prepare_paint_material(plane, 1)
	var center := 0
	for v in p3d.active_mdt.get_vertex_count():
		if p3d.active_mdt.get_vertex(v).length() < p3d.active_mdt.get_vertex(center).length():
			center = v
	picker.color = Color(1, 0, 0, 1)
	var one: Array[int] = [center]
	p3d.apply_brush(one)
	sv.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := sv.get_texture().get_image()
	var mid := cam.unproject_position(plane.global_transform * Vector3(0.5, 0, 0))
	var c := img.get_pixel(int(mid.x), int(mid.y))
	var ok: bool = c.r > 0.3 and c.g > 0.3 and c.b < 0.15
	print("HALO_PROBE halfway_red_to_unpainted=%s (blue must stay at the lit floor, no white) %s" % [
		c, "PASS" if ok else "FAIL"])
	option.select(0)
	p3d.mesh_i = null
	sv.free()
	return ok


## F18: a fast drag across a big, dense plane (182 x 182, 98 subdivisions,
## like a level's ground) through forward_3d_input: no gaps wider than the
## vertex spacing along the stroke, nothing painted far from it, and the end
## of the stroke painted (the release's final dab).
func _stroke_probe(p3d: Node, view_cam: Camera3D) -> bool:
	var plane := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.subdivide_width = 98
	pm.subdivide_depth = 98
	plane.mesh = pm
	plane.scale = Vector3(91, 91, 91)
	plane.position = Vector3(0, -60, -120)
	add_child(plane)
	var enable: CheckBox = painter.get_node("VBoxContainer/EnableCheckBox")
	var picker: ColorPicker = painter.get_node("VBoxContainer/ColorPicker")
	enable.button_pressed = true
	p3d.set_target(plane)
	picker.color = Color(1, 0, 1, 1)
	var vp := view_cam.get_viewport().get_visible_rect().size
	var a := Vector2(vp.x * 0.3, vp.y * 0.85)  # low in the view: on the plane
	var b := Vector2(vp.x * 0.7, vp.y * 0.88)
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = a
	p3d.forward_3d_input(view_cam, press)
	for i in 30:  # ~30 frames for the whole stroke: fast
		var motion := InputEventMouseMotion.new()
		motion.position = a.lerp(b, (i + 1) / 30.0)
		motion.button_mask = MOUSE_BUTTON_MASK_LEFT
		p3d.forward_3d_input(view_cam, motion)
		await get_tree().process_frame
	var release := press.duplicate() as InputEventMouseButton
	release.pressed = false
	release.position = b
	p3d.forward_3d_input(view_cam, release)
	for i in 20:
		await get_tree().process_frame
	var ha := _ground_hit(view_cam, a, plane.position.y)
	var hb := _ground_hit(view_cam, b, plane.position.y)
	var verts: PackedVector3Array = plane.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var colors: PackedColorArray = plane.mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
	var painted: Array[Vector3] = []
	var far := 0.0
	for v in colors.size():
		if colors[v].is_equal_approx(Color(1, 0, 1, 1)):
			var w := plane.global_transform * verts[v]
			painted.append(w)
			var ab := hb - ha
			var t := clampf((w - ha).dot(ab) / ab.length_squared(), 0.0, 1.0)
			far = maxf(far, w.distance_to(ha + ab * t))
	var gap := 0.0
	for i in 41:
		var p := ha.lerp(hb, i / 40.0)
		var nearest := INF
		for w in painted:
			nearest = minf(nearest, w.distance_to(p))
		gap = maxf(gap, nearest)
	var spacing := 182.0 / 99.0
	var ok: bool = painted.size() > 0 and gap <= spacing and far <= 4.0 * spacing
	print("STROKE_PROBE painted=%d biggest_gap=%.1f m farthest_from_path=%.1f m (vertex spacing %.1f m) %s" % [
		painted.size(), gap, far, spacing, "PASS" if ok else "FAIL"])
	enable.button_pressed = false
	p3d.set_target(null)
	plane.free()
	return ok


func _ground_hit(cam: Camera3D, pos: Vector2, y: float) -> Vector3:
	var o := cam.project_ray_origin(pos)
	var dir := cam.project_ray_normal(pos)
	return o + dir * ((y - o.y) / dir.y)


## F19: painting the plane while the cursor is over ANOTHER mesh. A big box
## stands beyond the plane's far edge (like the huge rocks around a level's
## ground). Pressing on the box used to paint the plane's vertices nearest to
## the box hit, i.e. on the plane's edge. Now: nothing is painted. And a box
## standing ON the plane must not stop painting the plane under the cursor.
func _edge_probe(p3d: Node, view_cam: Camera3D) -> bool:
	var plane := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(40, 40)
	pm.subdivide_width = 19
	pm.subdivide_depth = 19
	plane.mesh = pm
	plane.position = Vector3(0, -10, -30)  # spans z = -10 .. -50
	add_child(plane)
	var box := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(60, 60, 4)
	box.mesh = bm
	box.position = Vector3(0, 10, -80)  # beyond the plane's far edge
	add_child(box)
	var enable: CheckBox = painter.get_node("VBoxContainer/EnableCheckBox")
	var picker: ColorPicker = painter.get_node("VBoxContainer/ColorPicker")
	enable.button_pressed = true
	p3d.set_target(plane)
	picker.color = Color(1, 1, 0, 1)
	var center := view_cam.get_viewport().get_visible_rect().size / 2.0
	var on_box := view_cam.unproject_position(box.position)
	await _click(p3d, view_cam, center + Vector2(0, center.y * 0.6))  # on the plane: first stroke
	var before: PackedColorArray = plane.mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
	await _click(p3d, view_cam, on_box)
	var after: PackedColorArray = plane.mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
	var changed := 0
	for v in after.size():
		if not after[v].is_equal_approx(before[v]):
			changed += 1
	var off_ok := changed == 0
	print("EDGE_PROBE press on another mesh beyond the plane: plane vertices painted=%d (expected 0) %s" % [
		changed, "PASS" if off_ok else "FAIL"])

	# A second box ON the plane, between camera and plane: pressing on it paints
	# the plane underneath (the selected mesh), not the box's surface point.
	var cover := MeshInstance3D.new()
	var cm := BoxMesh.new()
	cm.size = Vector3(6, 6, 6)
	cover.mesh = cm
	cover.position = Vector3(0, -7, -25)
	add_child(cover)
	var on_cover := view_cam.unproject_position(Vector3(0, -6, -22))  # cover's front face; the ray meets the plane at z = -36.7
	var o := view_cam.project_ray_origin(on_cover)
	var dir := view_cam.project_ray_normal(on_cover)
	var under := o + dir * ((-10.0 - o.y) / dir.y)  # where the ray meets the plane
	picker.color = Color(0, 1, 1, 1)
	await _click(p3d, view_cam, on_cover)
	var verts: PackedVector3Array = plane.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var cols: PackedColorArray = plane.mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
	var far := 0.0
	var n := 0
	for v in cols.size():
		if cols[v].is_equal_approx(Color(0, 1, 1, 1)):
			n += 1
			far = maxf(far, (plane.global_transform * verts[v]).distance_to(under))
	var through_ok: bool = n > 0 and far < 4.0
	print("EDGE_PROBE press on a mesh in front of the plane: painted=%d at most %.1f m from the plane point under the cursor %s" % [
		n, far, "PASS" if through_ok else "FAIL"])
	enable.button_pressed = false
	p3d.set_target(null)
	plane.free()
	box.free()
	cover.free()
	return off_ok and through_ok


func _click(p3d: Node, cam: Camera3D, pos: Vector2) -> void:
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = pos
	p3d.forward_3d_input(cam, press)
	for i in 8:
		await get_tree().process_frame
	var release := press.duplicate() as InputEventMouseButton
	release.pressed = false
	p3d.forward_3d_input(cam, release)
	for i in 8:
		await get_tree().process_frame


func _paint_probe(p3d: Node, view_cam: Camera3D) -> bool:
	var sphere := SphereMesh.new()
	sphere.radial_segments = 24
	sphere.rings = 12
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, sphere.get_mesh_arrays())
	var tex := GradientTexture2D.new()
	var original := StandardMaterial3D.new()
	original.albedo_texture = tex
	mesh.surface_set_material(0, original)
	var rock := MeshInstance3D.new()
	rock.mesh = mesh
	add_child(rock)
	rock.global_transform = Transform3D(
		Basis(Vector3(0.3, 1, 0.2).normalized(), 1.1).scaled(Vector3(1.6, 0.8, 1.2)), Vector3(0, 0, -6))
	var picker: ColorPicker = painter.get_node("VBoxContainer/ColorPicker")
	picker.color = Color(1, 0, 0)
	var enable: CheckBox = painter.get_node("VBoxContainer/EnableCheckBox")
	enable.button_pressed = true
	p3d.set_target(rock)
	var center := view_cam.get_viewport().get_visible_rect().size / 2.0
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = center
	var consumed: bool = p3d.forward_3d_input(view_cam, press)
	for i in 10:  # depth readback + first paint
		await get_tree().process_frame
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.position = center
	p3d.forward_3d_input(view_cam, release)
	for i in 6:  # F18: the release paints one final dab
		await get_tree().process_frame
	var hit: Vector3 = p3d.debug.global_position

	var arrays := rock.mesh.surface_get_arrays(0)
	var colors = arrays[Mesh.ARRAY_COLOR]
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var red := 0
	var white := 0
	var far := 0.0
	if colors != null:
		for i in colors.size():
			if colors[i].is_equal_approx(Color(1, 0, 0)):
				red += 1
				far = maxf(far, (rock.global_transform * verts[i]).distance_to(hit))
			elif colors[i].is_equal_approx(Color.WHITE):
				white += 1
	var used := rock.get_surface_override_material(0) as StandardMaterial3D
	var mat_ok: bool = used != null and used != original and used.vertex_color_use_as_albedo \
		and used.albedo_texture == tex and not original.vertex_color_use_as_albedo
	var stroke_ok: bool = consumed and colors != null and red == p3d.brush_size \
		and white == colors.size() - red and far < 0.6
	print("PAINT_PROBE consumed=%s painted=%d (brush %d) others_white=%s max_dist_from_hit=%.3f %s" % [
		consumed, red, p3d.brush_size, colors != null and white == colors.size() - red, far,
		"PASS" if stroke_ok else "FAIL"])
	print("PAINT_MATERIAL_PROBE copy_with_vertex_color=%s texture_kept=%s original_untouched=%s %s" % [
		used != null and used.vertex_color_use_as_albedo, used != null and used.albedo_texture == tex,
		not original.vertex_color_use_as_albedo, "PASS" if mat_ok else "FAIL"])

	# F9: Alt+click on the spot just painted red takes red back (eyedropper)
	# and paints nothing.
	picker.color = Color(1, 1, 1, 0.6)  # current opacity 60 %
	var colors_before = rock.mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
	var alt_press := press.duplicate() as InputEventMouseButton
	alt_press.alt_pressed = true
	p3d.forward_3d_input(view_cam, alt_press)
	for i in 6:
		await get_tree().process_frame
	p3d.forward_3d_input(view_cam, release)
	var unchanged: bool = rock.mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR] == colors_before
	var pick_ok: bool = picker.color.is_equal_approx(Color(1, 0, 0, 0.6)) and unchanged
	print("PICK_PROBE alt_click picked=%s (RGB red, opacity kept 0.6) mesh_unchanged=%s %s" % [picker.color, unchanged,
		"PASS" if pick_ok else "FAIL"])

	# F14/F15: right after painting the rock, paint a built-in PlaneMesh in front
	# of it. It used to become a copy of the rock (stale MeshDataTool data); now
	# it becomes an editable copy of the PLANE and gets the paint.
	var plane := MeshInstance3D.new()
	var plane_mesh := PlaneMesh.new()
	plane_mesh.size = Vector2(4, 4)
	plane_mesh.subdivide_width = 7
	plane_mesh.subdivide_depth = 7
	plane.mesh = plane_mesh
	add_child(plane)
	plane.global_transform = Transform3D(Basis(Vector3.RIGHT, PI / 2), Vector3(0, 0, -3))  # faces the camera
	var plane_verts := (plane_mesh.get_mesh_arrays()[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	picker.color = Color(0, 1, 0, 1)
	p3d.set_target(plane)
	p3d.forward_3d_input(view_cam, press)
	for i in 10:
		await get_tree().process_frame
	p3d.forward_3d_input(view_cam, release)
	var green := 0
	var plane_colors = plane.mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR] if plane.mesh is ArrayMesh else null
	if plane_colors != null:
		for c in plane_colors:
			if c.is_equal_approx(Color(0, 1, 0, 1)):
				green += 1
	var plane_count: int = (plane.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	var plane_ok: bool = plane.mesh is ArrayMesh and plane_count == plane_verts and green == p3d.brush_size
	print("PLANE_PROBE plane_vertices=%d (own %d, rock %d) painted_green=%d %s" % [plane_count, plane_verts,
		(rock.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size(), green,
		"PASS" if plane_ok else "FAIL"])
	plane.free()
	pick_ok = pick_ok and plane_ok

	enable.button_pressed = false
	p3d.set_target(null)
	rock.free()
	return stroke_ok and mat_ok and pick_ok


func _run() -> void:
	print("Godot %s, renderer %s" % [Engine.get_version_info().string,
		ProjectSettings.get_setting("rendering/renderer/rendering_method")])
	var ok := true
	var origin := Vector3.ZERO
	var forward := Vector3(0, 0, -1)
	# F19: the depth camera renders only the paint target, which carries the
	# paint layer while painting is on. These raw depth checks stand in for that.
	target.layers |= painter.get_node("VertexPainter3D").PAINT_LAYER

	for d in HIT_DISTANCES:
		target.global_position = origin + forward * d
		target.show()
		var nd := await _sample(origin, forward)
		var got := _to_depth(nd)
		var pass_ := is_finite(got) and absf(got - d) <= TOLERANCE
		ok = ok and pass_
		print("DEPTH_PROBE expected=%.1f got=%.4f error=%.4f %s" % [
			d, got, absf(got - d), "PASS" if pass_ else "FAIL"])

	# Miss: nothing behind the cursor must decode as a miss.
	target.hide()
	var nd_miss := await _sample(origin, forward)
	var miss_ok := not is_finite(_to_depth(nd_miss))
	ok = ok and miss_ok
	print("MISS_PROBE normalized=%.9f -> %s %s" % [nd_miss, "miss" if miss_ok else "hit",
		"PASS" if miss_ok else "FAIL"])

	# F3/F5: the REAL click_raycast2(), fed the way _forward_3d_gui_input()
	# feeds it (a viewport camera + viewport-local mouse position). Each call
	# must use a FRESH depth render: one call, no warm-up call.
	var p3d := painter.get_node("VertexPainter3D")
	var view_cam := Camera3D.new()
	add_child(view_cam)
	view_cam.global_position = Vector3(0, 0, 0)
	view_cam.look_at(Vector3(0, 0, -1), Vector3.UP)
	var plane_d := 7.0
	target.global_position = Vector3(0, 0, -plane_d)
	target.show()
	p3d.view_camera = view_cam
	p3d.view_mouse_pos = view_cam.get_viewport().get_visible_rect().size / 2.0
	mouse_camera_3d.show()
	var point: Vector3 = await p3d.click_raycast2()
	var expected := Vector3(0, 0, -plane_d)
	# 0.1: the 8-bit depth encoding resolves about 0.08 units at this range.
	var hit_ok := point.is_finite() and point.distance_to(expected) <= 0.1
	ok = ok and hit_ok
	print("RAYCAST_PROBE expected=%s got=%s %s" % [expected, point, "PASS" if hit_ok else "FAIL"])
	# F5: right after a hit, a click on empty space must be a miss. Before the
	# fix it decoded the previous render's depth and "hit" (painting the mesh).
	# Let frames pass first, like a user moving from the mesh to the sky.
	for i in SETTLE_FRAMES:
		await get_tree().process_frame
	target.hide()
	var sky: Vector3 = await p3d.click_raycast2()
	var sky_ok := not sky.is_finite()
	ok = ok and sky_ok
	print("RAYCAST_SKY_AFTER_HIT_PROBE got=%s %s" % [sky, "PASS" if sky_ok else "FAIL"])

	# F6: a full stroke through forward_3d_input() on a rotated, non-uniformly
	# scaled, textured mesh with no vertex colors (like an atmosphere rock).
	ok = await _paint_probe(p3d, view_cam) and ok
	ok = await _mode_render_probe(p3d) and ok
	ok = await _halo_probe(p3d) and ok
	ok = await _stroke_probe(p3d, view_cam) and ok
	ok = await _edge_probe(p3d, view_cam) and ok
	view_cam.free()

	print("DEPTH_PROBE_RESULT %s" % ("PASS" if ok else "FAIL"))
	get_tree().quit(0 if ok else 1)
