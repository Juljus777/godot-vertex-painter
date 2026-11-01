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
