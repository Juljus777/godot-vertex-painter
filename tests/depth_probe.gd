extends Node3D
## Rendered smoke test for the GPU depth readback used by click_raycast2().
## Run (needs a display/GPU, not --headless):
##   $GODOT --path . res://tests/depth_probe.tscn --quit-after 300
##
## Uses the plugin's own SubViewport/MouseCamera3D/ScreenQuad (from
## vertex_painter.tscn) and decodes the pixel exactly like click_raycast2().
## Prints one DEPTH_PROBE line per hit target, a MISS_PROBE line for empty
## space, then DEPTH_PROBE_RESULT PASS/FAIL. Exit code 0 on pass, 1 on fail.
## A hit passes within ±TOLERANCE of the true distance OR of the 8-bit
## quantized prediction (see _predict_8bit()).

const TOLERANCE := 0.05
## Distances from the mouse camera to the target planes.
const HIT_DISTANCES := [7.0, 30.0]
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
## `direction`, render once, decode pixel (0, 0). Returns the decoded
## normalized distance (before the miss / far checks).
func _sample(origin: Vector3, direction: Vector3) -> float:
	mouse_camera_3d.show()  # start_paint() shows it; hidden by default
	mouse_camera_3d.global_position = origin
	mouse_camera_3d.look_at(origin + direction, Vector3.UP)
	sub_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	for i in SETTLE_FRAMES:
		await get_tree().process_frame
	var vp_img := sub_viewport.get_texture().get_image()
	var screen_depth := vp_img.get_pixel(0, 0).srgb_to_linear()
	var screen_rg := Vector2(screen_depth.r, screen_depth.g)
	return screen_rg.dot(Vector2(1, 1.0 / 255.0))


## Predicts what the readback returns for distance `d` when the SubViewport
## target is 8-bit sRGB (it is on 4.2 Forward+): encode_rg() from
## gpu_depth.gdshader, linear->sRGB, round to 8 bits, then the plugin's
## srgb_to_linear() + decode. With far = 100000 the whole value sits in G,
## so the resolution is coarse (about 0.08 units at 7 units).
func _predict_8bit(d: float) -> float:
	var far := mouse_camera_3d.far
	var v := d / far
	var g := fposmod(255.0 * v, 1.0)
	var r := fposmod(v, 1.0) - g / 255.0
	var enc := Color(r, g, 0.0).linear_to_srgb()
	var q := Color(roundf(enc.r * 255.0) / 255.0, roundf(enc.g * 255.0) / 255.0, 0.0).srgb_to_linear()
	return Vector2(q.r, q.g).dot(Vector2(1, 1.0 / 255.0)) * far


## Same miss/far handling as click_raycast2(); returns -INF for a miss.
func _to_depth(normalized_distance: float) -> float:
	if is_zero_approx(normalized_distance):
		return -INF
	if normalized_distance > 0.9999:
		normalized_distance = 1.0
	return normalized_distance * mouse_camera_3d.far


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
	enable.button_pressed = false
	p3d.set_target(null)
	rock.free()
	return stroke_ok and mat_ok


func _run() -> void:
	print("Godot %s, renderer %s" % [Engine.get_version_info().string,
		ProjectSettings.get_setting("rendering/renderer/rendering_method")])
	var ok := true
	var origin := Vector3.ZERO
	var forward := Vector3(0, 0, -1)

	for d in HIT_DISTANCES:
		target.global_position = origin + forward * d
		target.show()
		var nd := await _sample(origin, forward)
		var got := _to_depth(nd)
		var predicted := _predict_8bit(d)
		# Pass if within tolerance of the true distance, or of the value an
		# 8-bit sRGB target is expected to quantize it to (upstream encoding
		# precision, not a port regression).
		var pass_ := is_finite(got) and (absf(got - d) <= TOLERANCE
			or absf(got - predicted) <= TOLERANCE)
		ok = ok and pass_
		print("DEPTH_PROBE expected=%.1f got=%.4f predicted_8bit=%.4f normalized=%.9f %s" % [
			d, got, predicted, nd, "PASS" if pass_ else "FAIL"])

	# Miss: nothing behind the cursor. Reported for reference (reversed-Z in
	# 4.3 may change what empty space decodes to); not part of pass/fail.
	target.hide()
	var nd_miss := await _sample(origin, forward)
	var miss := _to_depth(nd_miss)
	var kind := "miss(-INF)" if not is_finite(miss) else ("far" if nd_miss >= 0.9999 else "hit")
	print("MISS_PROBE normalized=%.9f decoded=%s -> %s" % [nd_miss, str(miss), kind])

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
	view_cam.free()

	print("DEPTH_PROBE_RESULT %s" % ("PASS" if ok else "FAIL"))
	get_tree().quit(0 if ok else 1)
