@tool
extends Node3D

const VERTEX_COLOR = preload("res://addons/vertex_painter/shaders/vertex_color.tres")
# "Normal" paint mode layer: next pass of the mesh's material copy.
const PAINT_OVERLAY = preload("res://addons/vertex_painter/shaders/paint_overlay.tres")

# How a mesh shows its paint. Stored per mesh, as its material setup:
# MULTIPLY = material copy with vertex_color_use_as_albedo (texture x paint);
# NORMAL = material copy with PAINT_OVERLAY as next pass (paint covers the
# texture by its alpha). NONE = not painted by this plugin.
enum PaintMode { MULTIPLY, NORMAL }
const NONE := -1
# Painted by an older version: surface override = the debug VERTEX_COLOR shader
# (shows only the vertex colors). Kept as is until a mode is picked for it.
const LEGACY := 2

# Emitted by the dock's "Enable Editable Children" button; the EditorPlugin
# performs it as an undoable action and selects `mesh`.
signal editable_children_requested(instance_root: Node, mesh: MeshInstance3D)

@onready var enable_check_box = $"../VBoxContainer/EnableCheckBox"
@onready var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
@onready var color_picker = $"../VBoxContainer/ColorPicker"
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
# True between a consumed left press and its release. click_active only turns
# on once the (asynchronous) depth readback confirms the press hit the mesh.
var _stroke_down := false
# True between a consumed Ctrl+click press and its release.
var _ctrl_select_down := false
# True for a stroke started with Shift held: it erases instead of painting.
var _erasing := false
# The mesh WE put an editor lock on (null if none). See _update_paint_lock().
var _locked_mesh: MeshInstance3D = null
# Dock hint for an instanced scene whose mesh can't be painted yet.
var _hint_label: Label
var _editable_button: Button
var _hint_root: Node = null
var _hint_mesh: MeshInstance3D = null
# Brush controls built in code (see _build_brush_ui()).
var _brush_slider: HSlider
var _brush_value: Label
var _brush_max: SpinBox
# Alt+click/drag eyedropper state (see forward_3d_input()).
var _alt_pick_down := false
# An Alt+drag that started off the selected mesh belongs to the editor (orbit).
var _alt_editor_drag := false
var _pick_busy := false
# Vertex colors at the start of the current stroke. Opacity blends from these,
# so going over the same spot within one stroke never exceeds the opacity.
var _stroke_base := PackedColorArray()
# Paint mode dropdown (built in code) and the editor's undo manager (set by
# the EditorPlugin; null in tests, then changes apply directly).
var _mode_option: OptionButton
var undo_redo: Object = null

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
		var mode := selected_mode()
		var had_mode := mesh_paint_mode(mesh_i)
		if not load_mesh_for_paint(mesh_i):
			return
		if had_mode == NONE and mode == PaintMode.NORMAL \
				and active_mdt.get_format() & Mesh.ARRAY_FORMAT_COLOR:
			# Existing (e.g. imported) vertex colors: read them as multiply-style
			# factors so white areas don't suddenly cover the texture.
			_convert_mdt_colors(active_mdt, PaintMode.MULTIPLY, PaintMode.NORMAL)
		ensure_vertex_colors(active_mdt, mode)
		begin_stroke_colors()
		mesh_i.mesh = ArrayMesh.new()
		active_mdt.commit_to_surface(mesh_i.mesh)
		prepare_paint_material(mesh_i, mode)
		process_move(event)
		click_active = true

# Load `mi`'s first surface into active_mdt for painting. MeshDataTool only
# works on an ArrayMesh, so a built-in shape (PlaneMesh, BoxMesh, ...) is read
# through an ArrayMesh copy of its geometry and material; start_paint() then
# puts the painted ArrayMesh on the node as for any other mesh. Anything else,
# or a failed load, must not get the previously painted mesh's stale data
# written into it (it used to replace e.g. a plane with a rock): clear it,
# leave the mesh untouched and say why in the dock.
func load_mesh_for_paint(mi: MeshInstance3D) -> bool:
	active_mdt.clear()
	var source: Mesh = mi.mesh
	if source is PrimitiveMesh:
		source = primitive_to_array_mesh(source as PrimitiveMesh)
	if source is ArrayMesh and active_mdt.create_from_surface(source, 0) == OK:
		if mi.mesh is PrimitiveMesh:
			show_hint("\"%s\" was a %s and is now an editable mesh. Paint is stored per vertex, so subdivide built-in shapes before painting them." % [mi.name, mi.mesh.get_class()])
		return true
	active_mdt.clear()
	var kind := mi.mesh.get_class() if mi.mesh else "no mesh"
	show_hint("\"%s\" uses a %s, which can't be painted (only imported meshes, ArrayMesh and built-in shapes). Nothing was changed." % [mi.name, kind])
	return false

# An ArrayMesh with the same surfaces (geometry and material) as a built-in
# shape, so MeshDataTool can edit it.
func primitive_to_array_mesh(prim: PrimitiveMesh) -> ArrayMesh:
	var out := ArrayMesh.new()
	for s in prim.get_surface_count():
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, prim.surface_get_arrays(s))
		out.surface_set_material(s, prim.surface_get_material(s))
	return out

# Meshes without a color array (e.g. imported .glb rocks) would get BLACK for
# every vertex the brush doesn't touch (MeshDataTool's default), so start them
# at the mode's "unpainted" value: white for Multiply (texture x 1), and fully
# transparent for Normal (nothing covers the texture yet).
func ensure_vertex_colors(mdt: MeshDataTool, mode: int = PaintMode.MULTIPLY) -> void:
	if mdt.get_format() & Mesh.ARRAY_FORMAT_COLOR:
		return
	var start := Color(1, 1, 1, 0) if mode == PaintMode.NORMAL else Color.WHITE
	for v in mdt.get_vertex_count():
		mdt.set_vertex_color(v, start)

func selected_mode() -> int:
	return _mode_option.selected if _mode_option else PaintMode.MULTIPLY

# The paint mode a mesh is set up for, from its surface material; NONE if this
# plugin hasn't painted it (so a never-painted mesh gets nothing added).
func mesh_paint_mode(mi: MeshInstance3D) -> int:
	var mat := mi.get_active_material(0)
	if mat == null:
		return NONE
	if mat == VERTEX_COLOR:
		return LEGACY
	if mat.next_pass == PAINT_OVERLAY:
		return PaintMode.NORMAL
	if mat is BaseMaterial3D and (mat as BaseMaterial3D).vertex_color_use_as_albedo:
		return PaintMode.MULTIPLY
	return NONE

# Vertex color conversion between modes.
# Multiply -> Normal: white (= unchanged) becomes "not painted" (alpha 0); any
# other color becomes fully covering paint of that color. Normal -> Multiply:
# the paint color blended toward white by its coverage. Multiply -> Normal ->
# Multiply is exact; Normal -> Multiply -> Normal is exact for fully covered or
# unpainted vertices (partial coverage is baked into the color).
func convert_color(c: Color, from: int, to: int) -> Color:
	if from == to:
		return c
	if to == PaintMode.NORMAL:
		var is_white := c.r >= 0.998 and c.g >= 0.998 and c.b >= 0.998
		return Color(1, 1, 1, 0) if is_white else Color(c.r, c.g, c.b, 1)
	return Color(lerpf(1.0, c.r, c.a), lerpf(1.0, c.g, c.a), lerpf(1.0, c.b, c.a), 1)

func _convert_mdt_colors(mdt: MeshDataTool, from: int, to: int) -> void:
	for v in mdt.get_vertex_count():
		mdt.set_vertex_color(v, convert_color(mdt.get_vertex_color(v), from, to))

# Show the paint on the mesh's OWN material (B3), set up for `mode`. The copy
# is made once; later strokes reuse it. The original material is never
# modified. Returns false when the paint can't be shown automatically; the
# dock then says why.
func prepare_paint_material(mi: MeshInstance3D, mode: int = PaintMode.MULTIPLY) -> bool:
	var mat := mi.get_active_material(0)
	if mat == VERTEX_COLOR:
		return true  # legacy debug shader: kept until a mode is picked for it
	if mode == PaintMode.NORMAL:
		return _prepare_normal_material(mi, mat)
	return _prepare_multiply_material(mi, mat)

# NORMAL: a copy of the material (any type) with the paint layer as next pass.
func _prepare_normal_material(mi: MeshInstance3D, mat: Material) -> bool:
	if mat != null and mat.next_pass == PAINT_OVERLAY:
		return true
	if mat != null and mat.next_pass != null:
		show_hint("\"%s\"'s material already has a next pass, so Normal mode can't add its paint layer. Use Multiply, or remove that next pass." % mi.name)
		return false
	var copy: Material = StandardMaterial3D.new() if mat == null else mat.duplicate()
	if copy is BaseMaterial3D:
		(copy as BaseMaterial3D).vertex_color_use_as_albedo = false
	copy.next_pass = PAINT_OVERLAY
	mi.set_surface_override_material(0, copy)
	return true

# MULTIPLY: for a BaseMaterial3D (what imported .glb meshes use) a copy with
# vertex_color_use_as_albedo, so the texture is multiplied by the paint.
func _prepare_multiply_material(mi: MeshInstance3D, mat: Material) -> bool:
	if mat == null:
		var plain := StandardMaterial3D.new()
		plain.vertex_color_use_as_albedo = true
		plain.vertex_color_is_srgb = true
		mi.set_surface_override_material(0, plain)
		return true
	if mat is BaseMaterial3D:
		if (mat as BaseMaterial3D).vertex_color_use_as_albedo and mat.next_pass != PAINT_OVERLAY:
			return true
		var copy := mat.duplicate() as BaseMaterial3D
		copy.vertex_color_use_as_albedo = true
		copy.vertex_color_is_srgb = true  # color picker values are sRGB
		if copy.next_pass == PAINT_OVERLAY:
			copy.next_pass = null  # coming from Normal mode
		mi.set_surface_override_material(0, copy)
		return true
	show_hint("\"%s\" uses a %s. The paint is stored in the mesh, but only shows if that material reads the vertex COLOR." % [mi.name, mat.get_class()])
	return false

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
	_sync_mode_ui()

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

# Ctrl+click selection. Ray-tests every MeshInstance3D in the edited scene
# (bounding box first, then its actual triangles) and selects the nearest hit;
# a mesh inside a non-editable instanced scene selects that instance (like the
# editor does), which then shows the "Enable Editable Children" hint.
func select_mesh_under_cursor(camera: Camera3D, screen_pos: Vector2) -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return
	var origin := camera.project_ray_origin(screen_pos)
	var direction := camera.project_ray_normal(screen_pos)
	var hit := mesh_under_ray(scene_root, origin, direction)
	if hit == null:
		return
	var node := selectable_node_for(hit, scene_root)
	var selection := EditorInterface.get_selection()
	selection.clear()
	selection.add_node(node)

# Nearest visible MeshInstance3D under `root` hit by the world-space ray, or null.
func mesh_under_ray(root: Node, origin: Vector3, direction: Vector3) -> MeshInstance3D:
	var best: MeshInstance3D = null
	var best_dist := INF
	var meshes := root.find_children("*", "MeshInstance3D", true, false)
	if root is MeshInstance3D:
		meshes.append(root)
	for n in meshes:
		var mi := n as MeshInstance3D
		if mi.mesh == null or not mi.is_visible_in_tree():
			continue
		var dist := ray_hit_distance(mi, origin, direction)
		if dist < best_dist:
			best_dist = dist
			best = mi
	return best

# World distance along the ray to the mesh's surface, or INF if it misses.
func ray_hit_distance(mi: MeshInstance3D, origin: Vector3, direction: Vector3) -> float:
	var inv := mi.global_transform.affine_inverse()
	var local_origin := inv * origin
	var local_dir := inv.basis * direction
	if mi.mesh.get_aabb().intersects_ray(local_origin, local_dir) == null:
		return INF
	var faces := mi.mesh.get_faces()
	var nearest := INF
	for i in range(0, faces.size(), 3):
		var p = Geometry3D.ray_intersects_triangle(local_origin, local_dir, faces[i], faces[i + 1], faces[i + 2])
		if p != null:
			nearest = minf(nearest, origin.distance_to(mi.global_transform * (p as Vector3)))
	return nearest

# What the editor would select for a click on `mesh`: the mesh itself, or the
# outermost instanced scene whose children aren't editable.
func selectable_node_for(mesh: Node, scene_root: Node) -> Node:
	var node := mesh
	while node != scene_root and node.owner != null and node.owner != scene_root \
			and not scene_root.is_editable_instance(node.owner):
		node = node.owner
	return node

# Called by the EditorPlugin's _forward_3d_gui_input(). Returns true when the
# event was used for painting; the editor then skips its own selection and
# transform handling for it, so no edit lock is needed during a stroke.
# Right/middle buttons, wheel and hover always pass through (camera navigation).
func is_target_under_cursor(camera: Camera3D, screen_pos: Vector2) -> bool:
	return is_instance_valid(target) and target.mesh != null and is_finite(ray_hit_distance(
		target, camera.project_ray_origin(screen_pos), camera.project_ray_normal(screen_pos)))

func forward_3d_input(camera: Camera3D, event: InputEvent) -> bool:
	# Alt+click / Alt+drag while painting: pick the color under the cursor
	# (eyedropper) instead of painting. Keeps picking while dragging.
	# Only when the selected mesh is under the cursor; otherwise the whole
	# Alt+drag goes to the editor (e.g. "Emulate 3 Button Mouse" orbit).
	if _alt_editor_drag:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT \
				and not event.pressed:
			_alt_editor_drag = false
		if event is InputEventMouseMotion and not (event.button_mask & MOUSE_BUTTON_MASK_LEFT):
			_alt_editor_drag = false  # released outside the viewport
		return false
	if enable_check_box.button_pressed and target != null:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed and event.alt_pressed:
				if not is_target_under_cursor(camera, event.position):
					_alt_editor_drag = true
					return false
				_alt_pick_down = true
				view_camera = camera
				view_mouse_pos = event.position
				_pick_color()
				return true
			if not event.pressed and _alt_pick_down:
				_alt_pick_down = false
				return true  # the release belongs to the pick
		if _alt_pick_down and event is InputEventMouseMotion:
			if not (event.button_mask & MOUSE_BUTTON_MASK_LEFT):
				_alt_pick_down = false  # released outside the viewport
				return false
			view_camera = camera
			view_mouse_pos = event.position
			_pick_color()
			return true

	# Ctrl+click while painting: select the mesh under the cursor instead of
	# painting (the editor's own Ctrl+click would start a rotate). Works even
	# when nothing is selected yet; the plugin gets all 3D input for this.
	if enable_check_box.button_pressed and event is InputEventMouseButton \
			and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed and event.is_command_or_control_pressed():
			_ctrl_select_down = true
			select_mesh_under_cursor(camera, event.position)
			return true
		if not event.pressed and _ctrl_select_down:
			_ctrl_select_down = false
			return true  # the release belongs to the Ctrl+click
	if _ctrl_select_down and event is InputEventMouseMotion:
		return true  # don't let a Ctrl+drag reach the editor

	if not enable_check_box.button_pressed or target == null:
		return false

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		view_camera = camera
		view_mouse_pos = event.position
		mesh_i = target
		_stroke_down = event.pressed
		if event.pressed:
			_erasing = event.shift_pressed  # Shift+drag erases
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
			var vertices := get_n_closest_vertices(active_mdt, mesh_i.global_transform, \
				result2, brush_size)
			apply_brush(vertices)

# Snapshot of the colors before this stroke (see _stroke_base).
func begin_stroke_colors() -> void:
	_stroke_base.resize(active_mdt.get_vertex_count())
	for v in active_mdt.get_vertex_count():
		_stroke_base[v] = active_mdt.get_vertex_color(v)

func brush_opacity() -> float:
	return color_picker.color.a  # the picker's A slider is the opacity

# Blend the picked color into `vertices` by the brush opacity, starting from
# the colors they had before the stroke, then rebuild the mesh ONCE (it used
# to be rebuilt after every single vertex).
func apply_brush(vertices: Array[int]) -> void:
	var paint_color: Color = color_picker.color
	var opacity := brush_opacity()
	var normal := selected_mode() == PaintMode.NORMAL and is_instance_valid(mesh_i) \
		and mesh_paint_mode(mesh_i) == PaintMode.NORMAL
	for idx in vertices:
		var base: Color = _stroke_base[idx] if idx < _stroke_base.size() else active_mdt.get_vertex_color(idx)
		var out := blend_erase(base, opacity, normal) if _erasing else blend_paint(base, paint_color, opacity, normal)
		active_mdt.set_vertex_color(idx, out)
	mesh_i.mesh.clear_surfaces()
	active_mdt.commit_to_surface(mesh_i.mesh)

# Shift+drag eraser dab, by the same opacity. Normal: the paint covers less
# (alpha drops), so the material shows through again; color kept. Multiply:
# back toward white, i.e. the texture unchanged.
func blend_erase(base: Color, opacity: float, normal: bool) -> Color:
	if normal:
		return Color(base.r, base.g, base.b, base.a * (1.0 - opacity))
	var restored := base.lerp(Color.WHITE, opacity)
	restored.a = base.a
	return restored

# One dab. Multiply: move the factor toward the paint color (alpha untouched).
# Normal: lay the paint over what's there ("over" compositing); alpha is how
# much the paint covers the material underneath.
func blend_paint(base: Color, color: Color, opacity: float, normal: bool) -> Color:
	if not normal:
		var blended := base.lerp(color, opacity)
		blended.a = base.a
		return blended
	var a := opacity + base.a * (1.0 - opacity)
	if a <= 0.0:
		return Color(1, 1, 1, 0)
	var keep := base.a * (1.0 - opacity)
	return Color((color.r * opacity + base.r * keep) / a, (color.g * opacity + base.g * keep) / a,
		(color.b * opacity + base.b * keep) / a, a)

# Switch a painted mesh to `to`: convert its vertex colors and set up its
# material, as one undoable editor action (direct when there's no undo
# manager, e.g. in tests). A mesh painted with the old debug shader (LEGACY)
# gets that override removed and its own material set up instead.
func convert_mesh_mode(mi: MeshInstance3D, to: int) -> bool:
	var from := mesh_paint_mode(mi)
	if from == NONE or from == to or not mi.mesh is ArrayMesh:
		return false
	var old_mesh: Mesh = mi.mesh
	var old_override: Material = mi.get_surface_override_material(0)
	var mdt := MeshDataTool.new()
	if mdt.create_from_surface(old_mesh, 0) != OK:
		return false
	if mdt.get_format() & Mesh.ARRAY_FORMAT_COLOR:
		_convert_mdt_colors(mdt, PaintMode.MULTIPLY if from == LEGACY else from, to)
	else:
		ensure_vertex_colors(mdt, to)
	var new_mesh := ArrayMesh.new()
	mdt.commit_to_surface(new_mesh)
	# Work out the new material on a stand-in so nothing changes before commit.
	var probe := MeshInstance3D.new()
	probe.mesh = new_mesh
	probe.set_surface_override_material(0, null if from == LEGACY else old_override)
	var ok := prepare_paint_material(probe, to)
	var new_override: Material = probe.get_surface_override_material(0)
	probe.free()
	if not ok:
		return false
	if undo_redo:
		undo_redo.create_action("Vertex Painter: switch paint mode")
		undo_redo.add_do_property(mi, "mesh", new_mesh)
		undo_redo.add_do_method(mi, "set_surface_override_material", 0, new_override)
		undo_redo.add_undo_property(mi, "mesh", old_mesh)
		undo_redo.add_undo_method(mi, "set_surface_override_material", 0, old_override)
		undo_redo.commit_action()
	else:
		mi.mesh = new_mesh
		mi.set_surface_override_material(0, new_override)
	return true

# Dropdown changed: convert the selected mesh if it's already painted another
# way; otherwise the mode applies from its first stroke.
func _on_mode_selected(index: int) -> void:
	if is_instance_valid(target) and mesh_paint_mode(target) != NONE:
		convert_mesh_mode(target, index)
	_sync_mode_ui()

# Show the selected mesh's mode in the dropdown (without converting), and a
# note for meshes still on the old debug shader.
func _sync_mode_ui() -> void:
	if _mode_option == null:
		return
	var mode := mesh_paint_mode(target) if is_instance_valid(target) else NONE
	if mode == PaintMode.MULTIPLY or mode == PaintMode.NORMAL:
		_mode_option.select(mode)
	elif mode == LEGACY:
		_mode_option.select(-1)  # nothing selected, so picking either mode fires
	elif _mode_option.selected == -1:
		_mode_option.select(PaintMode.MULTIPLY)
	if mode == LEGACY:
		show_hint("\"%s\" still uses the old debug shader (vertex colors only, texture hidden). Pick a Mode to switch it to its own material; the colors are kept." % target.name)
	elif _hint_label and _hint_label.text.contains("old debug shader"):
		show_hint("")

# Color of the vertex nearest `world_point` (white if the mesh has no colors).
func color_at(mi: MeshInstance3D, world_point: Vector3) -> Color:
	var mdt := MeshDataTool.new()
	if not mi.mesh is ArrayMesh or mdt.create_from_surface(mi.mesh, 0) != OK:
		return Color.WHITE
	if not (mdt.get_format() & Mesh.ARRAY_FORMAT_COLOR):
		return Color.WHITE
	var idx := get_closest_vertex(mdt, mi.global_transform, world_point)
	return mdt.get_vertex_color(idx) if idx >= 0 else Color.WHITE

# Alt+click eyedropper: take the color under the cursor instead of painting.
# One depth readback at a time; drag events arriving meanwhile are skipped.
func _pick_color() -> void:
	if _pick_busy:
		return
	_pick_busy = true
	mouse_camera_3d.show()
	var hit: Vector3 = await click_raycast2()
	mouse_camera_3d.hide()
	_pick_busy = false
	if hit.is_finite() and is_instance_valid(target):
		var picked := color_at(target, hit)
		picked.a = color_picker.color.a  # keep the current opacity
		color_picker.color = picked

func legacy_paint() -> void:
	var result = click_raycast()
	if "position" in result:
		var vertices := get_n_closest_vertices(active_mdt, mesh_i.global_transform, \
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
	
# B2: vertices are compared in WORLD space through the mesh's full global
# transform (position, rotation and non-uniform scale). Adding only the
# position put the brush in the wrong place on any rotated or scaled mesh.
func get_n_closest_vertices(mdt: MeshDataTool, mesh_xform: Transform3D, \
	hit_pos: Vector3, n: int) -> Array[int]:

	var vertices := []
	for v in range(mdt.get_vertex_count()):
		var v_pos := mesh_xform * mdt.get_vertex(v)
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

func get_closest_vertex(mdt: MeshDataTool, mesh_xform: Transform3D, hit_pos: Vector3) -> int:
	var closest_dist := INF
	var closest_index := -1
	for v in range(mdt.get_vertex_count()):
		var v_pos := mesh_xform * mdt.get_vertex(v)
		var dist := hit_pos.distance_squared_to(v_pos)
		if dist < closest_dist:
			closest_dist = dist
			closest_index = v
	
	return closest_index

func set_brush_size() -> void:
	brush_size = int(_brush_slider.value)
	_brush_value.text = str(brush_size)

func _ready() -> void:
	enable_check_box.toggled.connect(_on_enable_check_box_toggled)
	_setup_color_picker()
	_build_brush_ui()
	_build_hint_ui()
	set_brush_size()

# Brush opacity lives in the picker's own alpha ("A") slider. The Intensity
# slider (HDR, Godot 4.5+) is hidden: vertex colors are stored as 0..1 with 8
# bits per channel, so brightening past white would just clip.
func _setup_color_picker() -> void:
	color_picker.edit_alpha = true
	if "edit_intensity" in color_picker:
		color_picker.set("edit_intensity", false)
	color_picker.tooltip_text = "The A (alpha) slider is the brush opacity: how much of the color each stroke applies."

# Brush size slider (1..Max, a vertex count) with an adjustable Max, placed
# under the "Brush Size:" label; then the shortcut hint.
func _build_brush_ui() -> void:
	var row := HBoxContainer.new()
	row.name = "BrushSizeRow"
	_brush_slider = HSlider.new()
	_brush_slider.name = "BrushSizeSlider"
	_brush_slider.min_value = 1
	_brush_slider.max_value = 50
	_brush_slider.step = 1
	_brush_slider.value = 5
	_brush_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_brush_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_brush_slider.tooltip_text = "Number of vertices painted around the cursor."
	_brush_slider.value_changed.connect(func(_v: float): set_brush_size())
	_brush_value = Label.new()
	_brush_value.custom_minimum_size.x = 32
	var max_label := Label.new()
	max_label.text = "Max:"
	_brush_max = SpinBox.new()
	_brush_max.name = "BrushSizeMax"
	_brush_max.min_value = 2
	_brush_max.max_value = 100000
	_brush_max.step = 1
	_brush_max.value = 50
	_brush_max.tooltip_text = "Largest value the brush size slider goes up to."
	_brush_max.value_changed.connect(func(v: float): _brush_slider.max_value = v)
	row.add_child(_brush_slider)
	row.add_child(_brush_value)
	row.add_child(max_label)
	row.add_child(_brush_max)

	var shortcuts := Label.new()
	shortcuts.name = "ShortcutHint"
	shortcuts.text = "Shift+drag: erase\nCtrl+click: switch mesh\nAlt+click/drag: pick color\nA slider (in the picker): opacity"
	shortcuts.modulate = Color(1, 1, 1, 0.7)
	shortcuts.mouse_filter = Control.MOUSE_FILTER_PASS  # so the tooltip shows
	shortcuts.tooltip_text = "While painting is enabled. It only picks when the selected mesh is under the cursor; elsewhere Alt+drag still reaches the editor (e.g. \"Emulate 3 Button Mouse\" orbit).\nSome Linux window managers use Alt+drag to move windows; Alt+click still works there."

	var size_label: Label = $"../VBoxContainer/Label"
	size_label.add_sibling(shortcuts)
	size_label.add_sibling(row)

	# Paint mode, above "Brush Size:".
	var mode_row := HBoxContainer.new()
	mode_row.name = "ModeRow"
	var mode_label := Label.new()
	mode_label.text = "Mode:"
	_mode_option = OptionButton.new()
	_mode_option.name = "ModeOption"
	_mode_option.add_item("Multiply", PaintMode.MULTIPLY)
	_mode_option.add_item("Normal", PaintMode.NORMAL)
	_mode_option.select(PaintMode.MULTIPLY)
	_mode_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_mode_option.tooltip_text = "Multiply: the texture is multiplied by the paint (white = unchanged).\nNormal: the paint covers the texture, by the opacity (A slider).\nStored per mesh; switching a painted mesh converts its paint (undoable)."
	_mode_option.item_selected.connect(_on_mode_selected)
	mode_row.add_child(mode_label)
	mode_row.add_child(_mode_option)
	size_label.add_sibling(mode_row)
	size_label.get_parent().move_child(mode_row, size_label.get_index())

func _build_hint_ui() -> void:
	var box: VBoxContainer = $"../VBoxContainer"
	_hint_label = Label.new()
	_hint_label.name = "HintLabel"
	_hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint_label.hide()
	box.add_child(_hint_label)
	_editable_button = Button.new()
	_editable_button.name = "EditableChildrenButton"
	_editable_button.text = "Enable Editable Children"
	_editable_button.hide()
	_editable_button.pressed.connect(_on_editable_button_pressed)
	box.add_child(_editable_button)

# Text shown under the dock controls; empty hides it.
func show_hint(text: String) -> void:
	_hint_label.text = text
	_hint_label.visible = not text.is_empty()

# Called by the EditorPlugin when the selection is an instanced scene (e.g. an
# imported .glb rock) whose MeshInstance3D isn't editable in this scene: its
# mesh can't be painted (or the paint saved) until Editable Children is on.
# root == null clears the hint.
func show_instance_hint(root: Node, mesh: MeshInstance3D) -> void:
	_hint_root = root
	_hint_mesh = mesh
	if root == null:
		show_hint("")
		_editable_button.hide()
		return
	show_hint("\"%s\" is an instanced scene. To paint its mesh \"%s\", enable Editable Children (the paint is then saved in this scene)." % [root.name, mesh.name])
	_editable_button.show()

func _on_editable_button_pressed() -> void:
	if is_instance_valid(_hint_root) and is_instance_valid(_hint_mesh):
		editable_children_requested.emit(_hint_root, _hint_mesh)
