@tool
extends EditorPlugin
## Test-only editor plugin (see tests/check_editor.sh). Checks, in a real
## editor session, that vertex_painter's dock is added on enable and removed
## on disable, twice, without errors. Prints EDITOR_PROBE lines and quits.

const PLUGIN := "vertex_painter"
const SETTLE := 30  # frames between steps


func _enter_tree() -> void:
	print("EDITOR_PROBE loaded")
	_run.call_deferred()


func _count_panels() -> int:
	# The dock content is the VertexPainter scene root (class_name VertexPainter).
	var n := 0
	var stack: Array[Node] = [EditorInterface.get_base_control()]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node.name == "VertexPainter" and node.get_node_or_null("VertexPainter3D") != null:
			n += 1
		stack.append_array(node.get_children())
	return n


func _wait() -> void:
	for i in SETTLE:
		await get_tree().process_frame


func _step(label: String, enabled: bool, expect: int) -> bool:
	EditorInterface.set_plugin_enabled(PLUGIN, enabled)
	await _wait()
	var got := _count_panels()
	var ok := got == expect and EditorInterface.is_plugin_enabled(PLUGIN) == enabled
	print("EDITOR_PROBE %s panels=%d expected=%d %s" % [label, got, expect, "PASS" if ok else "FAIL"])
	return ok


func _enable_check_box() -> CheckBox:
	var stack: Array[Node] = [EditorInterface.get_base_control()]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node.name == "VertexPainter" and node.get_node_or_null("VertexPainter3D") != null:
			return node.get_node("VBoxContainer/EnableCheckBox")
		stack.append_array(node.get_children())
	return null


func _report(label: String, ok: bool, detail := "") -> bool:
	print("EDITOR_PROBE %s %s%s" % [label, "PASS" if ok else "FAIL", (" " + detail) if detail else ""])
	return ok


## F4 in a real editor: the edited mesh is locked (transform gizmo hidden)
## exactly while "Enable Vertex Painting" is on, the lock never ends up in a
## file saved by the editor, and disabling the plugin releases it.
## Works on a throwaway copy of tests/manual_test.tscn under .godot/.
const LOCK_SCENE := "res://.godot/test-logs/f4_lock_probe.tscn"

func _lock_steps() -> bool:
	var ok := true
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(LOCK_SCENE.get_base_dir()))
	DirAccess.copy_absolute(ProjectSettings.globalize_path("res://tests/manual_test.tscn"),
		ProjectSettings.globalize_path(LOCK_SCENE))
	EditorInterface.open_scene_from_path(LOCK_SCENE)
	await _wait()
	# The editor reopens last session's scenes at startup, so this tab may hold
	# a stale copy from an earlier run; force it to the fresh file on disk.
	EditorInterface.reload_scene_from_path(LOCK_SCENE)
	await _wait()
	var root := EditorInterface.get_edited_scene_root()
	var mesh: Node3D = root.get_node_or_null("PaintMe") if root else null
	var check_box := _enable_check_box()
	ok = _report("lock_setup", mesh != null and check_box != null) and ok
	if mesh == null or check_box == null:
		return false
	var selection := EditorInterface.get_selection()
	selection.clear()
	selection.add_node(mesh)
	await _wait()
	ok = _report("lock_before_enable", not mesh.has_meta("_edit_lock_")) and ok
	check_box.button_pressed = true
	await _wait()
	ok = _report("lock_while_enabled", mesh.get_meta("_edit_lock_", false) == true) and ok
	check_box.button_pressed = false
	await _wait()
	ok = _report("lock_after_untick", not mesh.has_meta("_edit_lock_")) and ok

	check_box.button_pressed = true
	await _wait()
	var err := EditorInterface.save_scene()
	await _wait()
	var text := FileAccess.get_file_as_string(LOCK_SCENE)
	ok = _report("lock_not_saved", err == OK and text != "" and not text.contains("_edit_lock_"),
		"save_err=%d" % err) and ok
	ok = _report("lock_back_after_save", mesh.get_meta("_edit_lock_", false) == true) and ok

	EditorInterface.set_plugin_enabled(PLUGIN, false)
	await _wait()
	ok = _report("lock_released_on_plugin_disable", not mesh.has_meta("_edit_lock_")) and ok
	EditorInterface.set_plugin_enabled(PLUGIN, true)
	await _wait()
	return ok


## F6 in a real editor: selecting an instanced scene (like an imported .glb
## rock) whose mesh isn't editable shows the dock hint + button and doesn't
## paint; the button enables Editable Children (undoable) and selects the mesh,
## which then becomes the paint target.
const INSTANCED_SCENE := "res://.godot/test-logs/f6_instanced_probe.tscn"

func _instance_steps() -> bool:
	var ok := true
	DirAccess.copy_absolute(ProjectSettings.globalize_path("res://tests/manual_test_instanced.tscn"),
		ProjectSettings.globalize_path(INSTANCED_SCENE))
	EditorInterface.open_scene_from_path(INSTANCED_SCENE)
	await _wait()
	EditorInterface.reload_scene_from_path(INSTANCED_SCENE)
	await _wait()
	var root := EditorInterface.get_edited_scene_root()
	var rock: Node = root.get_node_or_null("RockA") if root else null
	var rock_mesh: Node = rock.get_node_or_null("RockMesh") if rock else null
	var check_box := _enable_check_box()
	var painter: Node = check_box.get_node("../../VertexPainter3D") if check_box else null
	ok = _report("instance_setup", rock != null and rock_mesh != null and painter != null) and ok
	if rock == null or rock_mesh == null or painter == null:
		return false
	var hint: Label = check_box.get_node("../HintLabel")
	var button: Button = check_box.get_node("../EditableChildrenButton")
	var selection := EditorInterface.get_selection()
	selection.clear()
	selection.add_node(rock)
	await _wait()
	ok = _report("instance_hint_shown", hint.visible and button.visible and hint.text.contains("RockA")
		and painter.target == null and not root.is_editable_instance(rock)) and ok

	button.pressed.emit()
	await _wait()
	var selected := selection.get_selected_nodes()
	ok = _report("instance_editable_enabled", root.is_editable_instance(rock)) and ok
	ok = _report("instance_mesh_selected", selected.size() == 1 and selected[0] == rock_mesh
		and painter.target == rock_mesh and not button.visible, "selected=%s" % [selected]) and ok

	var undo_redo := get_undo_redo()
	undo_redo.get_history_undo_redo(undo_redo.get_object_history_id(root)).undo()
	await _wait()
	ok = _report("instance_editable_undo", not root.is_editable_instance(rock)) and ok
	selection.clear()
	await _wait()
	return ok


## F13 in a real editor: switching a painted mesh's paint mode is one undoable
## action, and a Normal-mode mesh is still Normal after save + reload (the
## saved material references the shared paint_overlay.tres).
const MODE_SCENE := "res://.godot/test-logs/f13_mode_probe.tscn"

func _mode_steps() -> bool:
	var ok := true
	DirAccess.copy_absolute(ProjectSettings.globalize_path("res://tests/manual_test.tscn"),
		ProjectSettings.globalize_path(MODE_SCENE))
	EditorInterface.open_scene_from_path(MODE_SCENE)
	await _wait()
	EditorInterface.reload_scene_from_path(MODE_SCENE)
	await _wait()
	var root := EditorInterface.get_edited_scene_root()
	var mesh: MeshInstance3D = root.get_node("PaintMe")
	var check_box := _enable_check_box()
	var painter: Node = check_box.get_node("../../VertexPainter3D")
	var option: OptionButton = check_box.get_node("../ModeRow/ModeOption")
	var selection := EditorInterface.get_selection()
	selection.clear()
	selection.add_node(mesh)
	await _wait()
	painter.prepare_paint_material(mesh, 0)  # as after a Multiply stroke
	var mul_mesh := mesh.mesh
	var mul_mat := mesh.get_surface_override_material(0)
	selection.clear()
	selection.add_node(mesh)  # re-sync the dropdown to the now-painted mesh
	await _wait()
	ok = _report("mode_setup", painter.mesh_paint_mode(mesh) == 0 and option.selected == 0) and ok

	option.select(1)
	option.item_selected.emit(1)
	await _wait()
	ok = _report("mode_switch_to_normal", painter.mesh_paint_mode(mesh) == 1) and ok
	var history := get_undo_redo().get_history_undo_redo(get_undo_redo().get_object_history_id(root))
	history.undo()
	await _wait()
	ok = _report("mode_switch_undo", painter.mesh_paint_mode(mesh) == 0 and mesh.mesh == mul_mesh
		and mesh.get_surface_override_material(0) == mul_mat) and ok
	history.redo()
	await _wait()
	ok = _report("mode_switch_redo", painter.mesh_paint_mode(mesh) == 1) and ok

	var err := EditorInterface.save_scene()
	await _wait()
	var text := FileAccess.get_file_as_string(MODE_SCENE)
	EditorInterface.reload_scene_from_path(MODE_SCENE)
	await _wait()
	var reloaded: MeshInstance3D = EditorInterface.get_edited_scene_root().get_node("PaintMe")
	ok = _report("mode_normal_survives_save_reload", err == OK and text.contains("paint_overlay.tres")
		and painter.mesh_paint_mode(reloaded) == 1, "save_err=%d" % err) and ok
	selection.clear()
	option.select(0)
	await _wait()
	return ok


## F8 in a real editor: Ctrl+click in the 3D viewport while painting selects
## the mesh under the cursor (instance root if not editable), moves the gizmo
## lock, and a Ctrl+click on empty space changes nothing.
func _viewport_surface() -> Control:
	var editor_vp := EditorInterface.get_editor_viewport_3d(0).get_parent().get_parent()
	for c in editor_vp.get_children():
		if c is Control and c.gui_input.get_connections().size() > 0:
			return c
	return null


func _ctrl_click(surface: Control, pos: Vector2) -> void:
	for pressed in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = pressed
		ev.ctrl_pressed = true
		ev.position = pos
		ev.global_position = pos
		surface.gui_input.emit(ev)
	await _wait()


## A screen point over `rock`: walk from its projected center toward the
## viewport center until the point is on screen and the painter's ray test
## says the cursor is over that rock's mesh. (-1, -1) if none is found.
func _on_screen_point(painter: Node, root: Node, cam: Camera3D, rect: Rect2, rock: Node3D) -> Vector2:
	if cam.is_position_behind(rock.global_position):
		return Vector2(-1, -1)
	var from := cam.unproject_position(rock.global_position)
	var center := rect.get_center()
	for i in 21:
		var p := from.lerp(center, i / 20.0)
		if not rect.has_point(p):
			continue
		var hit: MeshInstance3D = painter.mesh_under_ray(root, cam.project_ray_origin(p), cam.project_ray_normal(p))
		if hit != null and rock.is_ancestor_of(hit):
			return p
	return Vector2(-1, -1)


func _ctrl_select_steps() -> bool:
	var ok := true
	DirAccess.copy_absolute(ProjectSettings.globalize_path("res://tests/manual_test_instanced.tscn"),
		ProjectSettings.globalize_path(INSTANCED_SCENE))
	EditorInterface.open_scene_from_path(INSTANCED_SCENE)
	await _wait()
	EditorInterface.reload_scene_from_path(INSTANCED_SCENE)
	await _wait()
	var root := EditorInterface.get_edited_scene_root()
	var rock_a: Node3D = root.get_node("RockA")
	var rock_b: Node3D = root.get_node("RockB")
	var check_box := _enable_check_box()
	var button: Button = check_box.get_node("../EditableChildrenButton")
	var surface := _viewport_surface()
	var cam := EditorInterface.get_editor_viewport_3d(0).get_camera_3d()
	var vp_rect := Rect2(Vector2.ZERO, EditorInterface.get_editor_viewport_3d(0).size)
	var painter: Node = check_box.get_node("../../VertexPainter3D")
	var pos_a := _on_screen_point(painter, root, cam, vp_rect, rock_a)
	var pos_b := _on_screen_point(painter, root, cam, vp_rect, rock_b)
	var visible_ok := surface != null and pos_a.x >= 0 and pos_b.x >= 0
	ok = _report("ctrl_setup", visible_ok, "a=%s b=%s rect=%s" % [pos_a, pos_b, vp_rect]) and ok
	if not visible_ok:
		return false
	var selection := EditorInterface.get_selection()
	selection.clear()
	check_box.button_pressed = true
	await _wait()

	pos_b = _on_screen_point(painter, root, cam, Rect2(Vector2.ZERO, EditorInterface.get_editor_viewport_3d(0).size), rock_b)
	await _ctrl_click(surface, pos_b)
	var sel := selection.get_selected_nodes()
	ok = _report("ctrl_click_selects_instance", sel.size() == 1 and sel[0] == rock_b and button.visible,
		"selected=%s" % [sel]) and ok

	button.pressed.emit()  # editable children -> its mesh becomes the target (and gets the F4 lock)
	await _wait()
	var mesh_b: Node = rock_b.get_node("RockMesh")
	ok = _report("ctrl_target_locked", mesh_b.has_meta("_edit_lock_")) and ok

	# The dock layout (hint text) can resize the viewport: recompute the point now.
	pos_a = _on_screen_point(painter, root, cam, Rect2(Vector2.ZERO, EditorInterface.get_editor_viewport_3d(0).size), rock_a)
	await _ctrl_click(surface, pos_a)
	sel = selection.get_selected_nodes()
	ok = _report("ctrl_click_switches", sel.size() == 1 and sel[0] == rock_a, "selected=%s" % [sel]) and ok
	ok = _report("ctrl_switch_releases_lock", not mesh_b.has_meta("_edit_lock_")) and ok

	await _ctrl_click(surface, Vector2(3, 3))
	sel = selection.get_selected_nodes()
	ok = _report("ctrl_click_sky_keeps_selection", sel.size() == 1 and sel[0] == rock_a, "selected=%s" % [sel]) and ok

	check_box.button_pressed = false
	selection.clear()
	await _wait()
	return ok


func _run() -> void:
	await _wait()
	var ok := true
	var initial := _count_panels()
	var init_ok := initial == 1 and EditorInterface.is_plugin_enabled(PLUGIN)
	print("EDITOR_PROBE initial panels=%d expected=1 %s" % [initial, "PASS" if init_ok else "FAIL"])
	ok = ok and init_ok
	ok = await _lock_steps() and ok
	ok = await _instance_steps() and ok
	ok = await _ctrl_select_steps() and ok
	ok = await _mode_steps() and ok
	ok = await _step("disable", false, 0) and ok
	ok = await _step("enable", true, 1) and ok
	ok = await _step("disable2", false, 0) and ok
	ok = await _step("enable2", true, 1) and ok
	print("EDITOR_PROBE_RESULT %s" % ("PASS" if ok else "FAIL"))
	get_tree().quit()
