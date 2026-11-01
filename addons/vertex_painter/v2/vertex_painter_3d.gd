@tool
extends Node3D

const VERTEX_COLOR = preload("res://addons/vertex_painter/shaders/vertex_color.tres")

@onready var enable_check_box = $"../VBoxContainer/EnableCheckBox"
@onready var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
@onready var color_picker = $"../VBoxContainer/ColorPicker"
@onready var brush_line_edit = $"../VBoxContainer/BrushLineEdit"
@onready var mouse_camera_3d: Camera3D = $"../SubViewport/MouseCamera3D"
@onready var sub_viewport = $"../SubViewport"
@onready var debug: MeshInstance3D = $"../Debug"
@onready var show_debug_check_box = $"../VBoxContainer/ShowDebugCheckBox"

var screen := ""
var mesh_i: MeshInstance3D = null
var error := false
var click_active := false
var active_mdt := MeshDataTool.new()
var pre_mat
var brush_size := 1
var working := false
# Set by the EditorPlugin: the MeshInstance3D being edited, and the camera and
# viewport-local mouse position of the last forwarded 3D viewport event.
var target: MeshInstance3D = null
var view_camera: Camera3D = null
var view_mouse_pos := Vector2.ZERO

func set_screen_name(_screen: String) -> void:
	screen = _screen

func err(message: String) -> void:
	print("Vertex painter [ERROR]: " + message)

func msg(message: String) -> void:
	print("Vertex painter [INFO]: " + message)

# OLD ALGORITHM
func click_raycast():
	var viewport = EditorInterface.get_editor_viewport_3d(0)
	var mouse_pos = viewport.get_mouse_position()
	var camera = viewport.get_camera_3d()
	
	var from = camera.project_ray_origin(mouse_pos)
	var to = from + camera.project_ray_normal(mouse_pos) * 100
	
	var rayQuery := PhysicsRayQueryParameters3D.new()
	rayQuery.from = from
	rayQuery.to = to
	
	var result = space.intersect_ray(rayQuery)
	return result

# NEW ALGORITHM - Does not require a collider
func click_raycast2(offset := Vector2(0,0)) -> Vector3:
	# Camera and position come from the forwarded event, so painting works in
	# whichever 3D viewport (of up to four) the user is drawing in.
	var mouse_pos := view_mouse_pos + offset
	var camera := view_camera

	#var from = camera.project_ray_origin(mouse_pos)
	#var to = from + camera.project_ray_normal(mouse_pos) * 2.0
	
	var src_pos: Vector3 = camera.project_ray_origin(mouse_pos)
	#var src_pos: Vector3 = from
	var direction: Vector3 = camera.project_ray_normal(mouse_pos).normalized()
	#var direction: Vector3 = from.direction_to(to)
	
	mouse_camera_3d.global_position = src_pos - direction
	
	var point: Vector3
	if is_zero_approx((direction - Vector3(0, -1, 0)).length_squared()):
		mouse_camera_3d.rotation_degrees = Vector3(-90, 0, 0)
		point = src_pos
	else:
		mouse_camera_3d.look_at(mouse_camera_3d.global_position + direction, Vector3.UP)
		sub_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
		var vp_tex: ViewportTexture = sub_viewport.get_texture()
		var vp_img := vp_tex.get_image()
		if vp_img == null or vp_img.is_empty():
			# No depth image yet (or no renderer, e.g. headless): treat as a miss.
			return Vector3(-INF, -INF, -INF)

		var screen_depth = vp_img.get_pixel(0, 0).srgb_to_linear()
		
		var screen_rg = Vector2(screen_depth.r, screen_depth.g)
		var normalized_distance: float = screen_rg.dot(Vector2(1, 1.0 / 255.0))
		#print(normalized_distance)
		if (is_zero_approx(normalized_distance)):
			return Vector3(-INF, -INF, -INF)
		
		if (normalized_distance > 0.9999):
			normalized_distance = 1.0
		
		var depth: float = normalized_distance * mouse_camera_3d.far
		point = mouse_camera_3d.global_position + direction * depth
	
	debug.global_position = point
	return point

func start_paint(event: InputEvent) -> void:
	mouse_camera_3d.show()
	if show_debug_check_box.button_pressed:
		debug.show()
	
	var click_location := click_raycast2()
	if click_location.is_finite():
		#print(click_location)
		active_mdt.create_from_surface(mesh_i.mesh, 0)
		mesh_i.mesh = ArrayMesh.new()
		active_mdt.commit_to_surface(mesh_i.mesh)
		pre_mat = mesh_i.get_surface_override_material(0)
		mesh_i.set_surface_override_material(0, VERTEX_COLOR)
		process_move(event)
		click_active = true

func start_paint_legacy(event: InputEvent) -> void:
	mesh_i.create_trimesh_collision()
	mesh_i.get_children()[0].hide()
	mesh_i.set_meta("_edit_lock_", true)
	
	var click_location = click_raycast()
	if click_location:
		active_mdt.create_from_surface(mesh_i.mesh, 0)
		mesh_i.mesh = ArrayMesh.new()
		active_mdt.commit_to_surface(mesh_i.mesh)
		pre_mat = mesh_i.get_surface_override_material(0)
		mesh_i.set_surface_override_material(0, VERTEX_COLOR)
		process_move(event)
		click_active = true

func stop_paint() -> void:
	mouse_camera_3d.hide()
	debug.hide()
	if pre_mat == null:
		pre_mat = VERTEX_COLOR
		mesh_i.set_surface_override_material(0, pre_mat)

	# legacy - remove static body children
	#for c in mesh_i.get_children():
	#	c.queue_free()
	
	click_active = false

# Called by the EditorPlugin's _edit(): the MeshInstance3D now being edited,
# or null when the selection no longer contains one.
func set_target(mesh: MeshInstance3D) -> void:
	if click_active and mesh != target:
		stop_paint()
	target = mesh

# Called by the EditorPlugin's _forward_3d_gui_input(). Returns true when the
# event was used for painting; the editor then skips its own selection and
# transform handling for it, so no edit lock is needed during a stroke.
# Right/middle buttons, wheel and hover always pass through (camera navigation).
func forward_3d_input(camera: Camera3D, event: InputEvent) -> bool:
	if not enable_check_box.button_pressed or target == null:
		return false

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		view_camera = camera
		view_mouse_pos = event.position
		mesh_i = target
		if event.pressed:
			start_paint(event)
		else:
			stop_paint()
		# Consume every left click while painting is enabled, including misses,
		# so clicking past the mesh doesn't deselect it mid-session.
		return true

	if event is InputEventMouseMotion and click_active:
		if not (event.button_mask & MOUSE_BUTTON_MASK_LEFT):
			# The release happened outside the viewport; end the stroke.
			stop_paint()
			return false
		view_camera = camera
		view_mouse_pos = event.position
		process_move(event)
		return true

	return false

func paint() -> void:
		var result2 = click_raycast2()
		if result2.is_finite():
			var vertices := get_n_closest_vertices(active_mdt, mesh_i.global_position, \
				result2, brush_size)
			for idx in vertices:
				active_mdt.set_vertex_color(idx, color_picker.color)
				mesh_i.mesh.clear_surfaces()
				active_mdt.commit_to_surface(mesh_i.mesh)

func legacy_paint() -> void:
	var result = click_raycast()
	if "position" in result:
		var vertices := get_n_closest_vertices(active_mdt, mesh_i.global_position, \
			result.position, brush_size)
		for idx in vertices:
			active_mdt.set_vertex_color(idx, color_picker.color)
			mesh_i.mesh.clear_surfaces()
			active_mdt.commit_to_surface(mesh_i.mesh)

func process_move(event: InputEvent) -> void:
	if not working:
		working = true
		
		paint()
		
		# STATIC MESH LEGACY
		#legacy_paint()
		
		await get_tree().create_timer(0.05).timeout
		working = false
	
func get_n_closest_vertices(mdt: MeshDataTool, mesh_pos: Vector3, \
	hit_pos: Vector3, n: int) -> Array[int]:
	
	var vertices := []
	for v in range(mdt.get_vertex_count()):
		var v_pos := mdt.get_vertex(v) + mesh_pos
		var dist := hit_pos.distance_squared_to(v_pos)
		
		if len(vertices) < n:
			# fill with the first n vertices
			vertices.append([v, dist])
		else:
			# after array fill, determine if largest should be replaced
			var changes := []
			var furthest_dist := 0.0
			var furthest_index := -1
			for index in range(len(vertices)):
				var vertex: Variant = vertices[index]
				var dist_2: float = vertex[1]
				
				if dist_2 > furthest_dist:
					furthest_dist = dist_2
					furthest_index = index
			
			# largest element gets kicked out for this one
			if dist < furthest_dist:
				vertices[furthest_index] = [v, dist]
	
	# extract indices (idx)
	var v_indices: Array[int] = []
	for vertex in vertices:
		v_indices.append(vertex[0])
	return v_indices

func get_closest_vertex(mdt: MeshDataTool, mesh_pos: Vector3, hit_pos: Vector3) -> int:
	var closest_dist := INF
	var closest_index := -1
	for v in range(mdt.get_vertex_count()):
		var v_pos := mdt.get_vertex(v) + mesh_pos
		var dist := hit_pos.distance_squared_to(v_pos)
		if dist < closest_dist:
			closest_dist = dist
			closest_index = v
	
	return closest_index

func set_brush_size() -> void:
	var brush_s = brush_line_edit.text
	
	var brush_s_f = float(brush_s)
	
	brush_size = int(round(brush_s_f))
	
	brush_line_edit.text = str(brush_size)
	msg("Brush size = " + str(brush_size))

func _ready() -> void:
	set_brush_size()

func _on_brush_line_edit_text_submitted(new_text):
	set_brush_size()

func _on_brush_line_edit_focus_exited():
	set_brush_size()
