@tool
extends EditorPlugin

#var dock
const MAIN_SCREEN = preload("res://addons/vertex_painter/v2/vertex_painter.tscn")

var main_panel_instance: VertexPainter

func _enter_tree():
	main_panel_instance = MAIN_SCREEN.instantiate()
	
	main_panel_instance.set_interface(get_editor_interface())
	main_screen_changed.connect(main_panel_instance.set_screen_name)
	
	add_control_to_dock(EditorPlugin.DOCK_SLOT_LEFT_UR, main_panel_instance)
	
	
func _exit_tree():
	remove_control_from_docks(main_panel_instance)
	main_panel_instance.free()


# Painting input goes through the editor's 3D input forwarding: the editor
# offers each 3D viewport event to this plugin first while a MeshInstance3D is
# being edited, and skips its own select/transform handling for events we stop.
func _handles(object: Object) -> bool:
	return object is MeshInstance3D or _uneditable_instance_mesh(object) != null


func _edit(object: Object) -> void:
	if not main_panel_instance:
		return
	var painter = main_panel_instance.vertex_painter_3d
	if not painter.editable_children_requested.is_connected(_on_editable_children_requested):
		painter.editable_children_requested.connect(_on_editable_children_requested)
	var inner_mesh := _uneditable_instance_mesh(object)
	if inner_mesh:
		painter.set_target(null)
		painter.show_instance_hint(object as Node, inner_mesh)
	else:
		painter.show_instance_hint(null, null)
		painter.set_target(object as MeshInstance3D)


# A selected instanced scene (e.g. an imported .glb rock) whose children aren't
# editable in the edited scene: clicking it in the viewport selects its root,
# not the MeshInstance3D inside, and changes to that mesh couldn't be saved.
# Returns the first MeshInstance3D inside it, or null if that doesn't apply.
func _uneditable_instance_mesh(object: Object) -> MeshInstance3D:
	var node := object as Node
	if node == null or node is MeshInstance3D or node.scene_file_path.is_empty():
		return null
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null or node == scene_root or scene_root.is_editable_instance(node):
		return null
	var stack: Array[Node] = [node]
	while not stack.is_empty():
		var n: Node = stack.pop_front()
		if n is MeshInstance3D:
			return n
		stack.append_array(n.get_children())
	return null


# Dock button: the same as Scene tree > right-click > Editable Children, but
# undoable, then select the mesh so it can be painted straight away.
func _on_editable_children_requested(instance_root: Node, mesh: MeshInstance3D) -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null or not scene_root.is_ancestor_of(instance_root):
		return
	var tree := scene_root.get_tree()
	var undo_redo := get_undo_redo()
	undo_redo.create_action("Vertex Painter: Enable Editable Children")
	undo_redo.add_do_method(scene_root, "set_editable_instance", instance_root, true)
	undo_redo.add_do_method(tree, "emit_signal", "tree_changed")
	undo_redo.add_undo_method(scene_root, "set_editable_instance", instance_root, false)
	undo_redo.add_undo_method(tree, "emit_signal", "tree_changed")
	undo_redo.commit_action()
	var selection := EditorInterface.get_selection()
	selection.clear()
	selection.add_node(mesh)


func _forward_3d_gui_input(viewport_camera: Camera3D, event: InputEvent) -> int:
	if main_panel_instance and main_panel_instance.vertex_painter_3d.forward_3d_input(viewport_camera, event):
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	return EditorPlugin.AFTER_GUI_INPUT_PASS


# The editor calls this right before saving a scene: keep the painter's
# gizmo-hiding lock out of saved .tscn files.
func _apply_changes() -> void:
	if main_panel_instance:
		main_panel_instance.vertex_painter_3d.before_save()
