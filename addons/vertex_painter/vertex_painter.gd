@tool
extends EditorPlugin

#var dock
const MAIN_SCREEN = preload("res://addons/vertex_painter/v2/vertex_painter.tscn")

var main_panel_instance: VertexPainter
var dock: EditorDock

func _enter_tree():
	main_panel_instance = MAIN_SCREEN.instantiate()
	
	main_screen_changed.connect(main_panel_instance.set_screen_name)
	
	dock = EditorDock.new()
	dock.title = "VertexPainter"
	dock.default_slot = EditorDock.DOCK_SLOT_LEFT_UR
	dock.add_child(main_panel_instance)
	add_dock(dock)
	
	
func _exit_tree():
	remove_dock(dock)
	dock.queue_free()


# Painting input goes through the editor's 3D input forwarding: the editor
# offers each 3D viewport event to this plugin first while a MeshInstance3D is
# being edited, and skips its own select/transform handling for events we stop.
func _handles(object: Object) -> bool:
	return object is MeshInstance3D


func _edit(object: Object) -> void:
	if main_panel_instance:
		main_panel_instance.vertex_painter_3d.set_target(object as MeshInstance3D)


func _forward_3d_gui_input(viewport_camera: Camera3D, event: InputEvent) -> int:
	if main_panel_instance and main_panel_instance.vertex_painter_3d.forward_3d_input(viewport_camera, event):
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	return EditorPlugin.AFTER_GUI_INPUT_PASS
