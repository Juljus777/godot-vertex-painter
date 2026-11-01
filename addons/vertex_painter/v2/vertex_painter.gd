@tool
extends CenterContainer
class_name VertexPainter

@onready var vertex_painter_3d = $VertexPainter3D
@onready var enable_check_box = $VBoxContainer/EnableCheckBox

func set_screen_name(_screen: String) -> void:
	vertex_painter_3d.set_screen_name(_screen)
