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


func _run() -> void:
	await _wait()
	var ok := true
	var initial := _count_panels()
	var init_ok := initial == 1 and EditorInterface.is_plugin_enabled(PLUGIN)
	print("EDITOR_PROBE initial panels=%d expected=1 %s" % [initial, "PASS" if init_ok else "FAIL"])
	ok = ok and init_ok
	ok = await _lock_steps() and ok
	ok = await _step("disable", false, 0) and ok
	ok = await _step("enable", true, 1) and ok
	ok = await _step("disable2", false, 0) and ok
	ok = await _step("enable2", true, 1) and ok
	print("EDITOR_PROBE_RESULT %s" % ("PASS" if ok else "FAIL"))
	get_tree().quit()
