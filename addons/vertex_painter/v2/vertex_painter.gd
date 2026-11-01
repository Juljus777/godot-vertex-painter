@tool
extends CenterContainer
class_name VertexPainter

@onready var vertex_painter_3d = $VertexPainter3D
@onready var enable_check_box = $VBoxContainer/EnableCheckBox

func set_screen_name(_screen: String) -> void:
	vertex_painter_3d.set_screen_name(_screen)

func _on_enable_check_box_pressed():
	if enable_check_box.button_pressed:
		EditorInterface.set_main_screen_editor("Script")
		EditorInterface.set_main_screen_editor("3D")
