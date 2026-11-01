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


func _run() -> void:
	await _wait()
	var ok := true
	var initial := _count_panels()
	var init_ok := initial == 1 and EditorInterface.is_plugin_enabled(PLUGIN)
	print("EDITOR_PROBE initial panels=%d expected=1 %s" % [initial, "PASS" if init_ok else "FAIL"])
	ok = ok and init_ok
	ok = await _step("disable", false, 0) and ok
	ok = await _step("enable", true, 1) and ok
	ok = await _step("disable2", false, 0) and ok
	ok = await _step("enable2", true, 1) and ok
	print("EDITOR_PROBE_RESULT %s" % ("PASS" if ok else "FAIL"))
	get_tree().quit()
