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

var editor_interface: EditorInterface
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
# True between a consumed left press and its release. click_active only turns
# on once the (asynchronous) depth readback confirms the press hit the mesh.
var _stroke_down := false
# The mesh WE put an editor lock on (null if none). See _update_paint_lock().
var _locked_mesh: MeshInstance3D = null

func set_interface(_editor_interface: EditorInterface) -> void:
	editor_interface = _editor_interface

func set_screen_name(_screen: String) -> void:
	screen = _screen

func err(message: String) -> void:
	print("Vertex painter [ERROR]: " + message)

func msg(message: String) -> void:
	print("Vertex painter [INFO]: " + message)

# OLD ALGORITHM
func click_raycast():
	var viewport = editor_interface.get_editor_viewport_3d(0)
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
		# Wait until that render has happened. Reading the texture right away
		# returns the PREVIOUS render, i.e. the depth under the last painted
		# point, so a click on empty space would "hit" and paint the mesh.
		await RenderingServer.frame_post_draw
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
	
	var click_location: Vector3 = await click_raycast2()
	# The readback takes a frame; the button may have been released (or the
	# target changed) meanwhile. Then this stroke is over: don't start it.
	if not _stroke_down or not is_instance_valid(mesh_i) or mesh_i != target:
		return
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
	_update_paint_lock()

# While "Enable Vertex Painting" is on, the edited mesh carries the editor's
# _edit_lock_ meta: it is the only script-reachable way to hide a node's
# move/rotate/scale gizmo. Painting input doesn't depend on it (clicks are
# consumed in forward_3d_input()); it is purely visual.
# Rules: the editor treats the node as locked whenever the meta EXISTS, so we
# remove it (never set it to false); we only ever remove a lock we added
# ourselves, so a lock the user set is left alone.
func _update_paint_lock(refresh_gizmo := true) -> void:
	var want: MeshInstance3D = null
	if is_node_ready() and is_inside_tree() and enable_check_box.button_pressed \
			and is_instance_valid(target):
		want = target
	if want == _locked_mesh:
		return
	var changed := _release_paint_lock()
	if want != null and not want.has_meta("_edit_lock_"):
		want.set_meta("_edit_lock_", true)
		_locked_mesh = want
		changed = true
	if changed and refresh_gizmo:
		_refresh_editor_gizmo()

# Removes our lock, if any. Returns true when a lock was actually removed.
func _release_paint_lock() -> bool:
	var removed := false
	if is_instance_valid(_locked_mesh) and _locked_mesh.has_meta("_edit_lock_"):
		_locked_mesh.remove_meta("_edit_lock_")
		removed = true
	_locked_mesh = null
	return removed

# The 3D editor only re-evaluates locks for its transform gizmo when the
# selection changes, so nudge it. Deferred, and targeted at EditorSelection
# (not self), so it is safe while the editor is calling into us or while this
# node is being freed. Re-entry is harmless: _edit() -> set_target() with the
# same mesh is a no-op in _update_paint_lock().
func _refresh_editor_gizmo() -> void:
	if not Engine.is_editor_hint():
		return
	var selection := EditorInterface.get_selection()
	if selection:
		Callable(selection, "emit_signal").call_deferred("selection_changed")

# Called by the EditorPlugin's _apply_changes(), which the editor runs right
# before writing a scene file: lift our lock so it is never saved into the
# .tscn, and put it back on the next frame (after the synchronous save).
func before_save() -> void:
	if _release_paint_lock():
		_update_paint_lock.call_deferred(false)

func _on_enable_check_box_toggled(_enabled: bool) -> void:
	if click_active and not enable_check_box.button_pressed:
		stop_paint()
	_update_paint_lock()

func _enter_tree() -> void:
	# The dock can leave and re-enter the tree (e.g. moved to another slot).
	if is_node_ready():
		_update_paint_lock()

func _exit_tree() -> void:
	# Plugin disabled, editor closing, or dock moved: never leave our lock behind.
	if _release_paint_lock():
		_refresh_editor_gizmo()

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
		_stroke_down = event.pressed
		if event.pressed:
			start_paint(event)  # coroutine: continues after the depth readback
		else:
			stop_paint()
		# Consume every left click while painting is enabled, including misses,
		# so clicking past the mesh doesn't deselect it mid-session.
		return true

	# While the left button is held after a consumed press, the editor must not
	# see the drag either (even if the press missed the mesh).
	if event is InputEventMouseMotion and (click_active or _stroke_down):
		if not (event.button_mask & MOUSE_BUTTON_MASK_LEFT):
			# The release happened outside the viewport; end the stroke.
			_stroke_down = false
			stop_paint()
			return false
		if not click_active:
			return true  # press missed the mesh: swallow the drag, don't paint
		view_camera = camera
		view_mouse_pos = event.position
		process_move(event)
		return true

	return false

func paint() -> void:
		var result2: Vector3 = await click_raycast2()
		if not click_active or not is_instance_valid(mesh_i):
			return  # stroke ended while waiting for the depth readback
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

		await paint()

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
	enable_check_box.toggled.connect(_on_enable_check_box_toggled)

func _on_brush_line_edit_text_submitted(new_text):
	set_brush_size()

func _on_brush_line_edit_focus_exited():
	set_brush_size()
