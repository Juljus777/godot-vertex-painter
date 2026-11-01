extends Node3D
## Rendered smoke test for the GPU depth readback used by click_raycast2().
## Run (needs a display/GPU, not --headless):
##   $GODOT --path . res://tests/depth_probe.tscn --quit-after 300
##
## Uses the plugin's own SubViewport/MouseCamera3D/ScreenQuad (from
## vertex_painter.tscn) and decodes the pixel exactly like click_raycast2().
## Prints one DEPTH_PROBE line per hit target, a MISS_PROBE line for empty
## space, then DEPTH_PROBE_RESULT PASS/FAIL. Exit code 0 on pass, 1 on fail.
## A hit passes within ±TOLERANCE of the true distance OR of the 8-bit
## quantized prediction (see _predict_8bit()).

const TOLERANCE := 0.05
## Distances from the mouse camera to the target planes.
const HIT_DISTANCES := [7.0, 30.0]
## Frames to wait after requesting an UPDATE_ONCE render before reading back.
const SETTLE_FRAMES := 4

@onready var painter: Control = $VertexPainter
@onready var target: MeshInstance3D = $Target

var mouse_camera_3d: Camera3D
var sub_viewport: SubViewport


func _ready() -> void:
	mouse_camera_3d = painter.get_node("SubViewport/MouseCamera3D")
	sub_viewport = painter.get_node("SubViewport")
	_run.call_deferred()


## Mirrors click_raycast2(): place the mouse camera at `origin` looking along
## `direction`, render once, decode pixel (0, 0). Returns the decoded
## normalized distance (before the miss / far checks).
func _sample(origin: Vector3, direction: Vector3) -> float:
	mouse_camera_3d.show()  # start_paint() shows it; hidden by default
	mouse_camera_3d.global_position = origin
	mouse_camera_3d.look_at(origin + direction, Vector3.UP)
	sub_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	for i in SETTLE_FRAMES:
		await get_tree().process_frame
	var vp_img := sub_viewport.get_texture().get_image()
	var screen_depth := vp_img.get_pixel(0, 0).srgb_to_linear()
	var screen_rg := Vector2(screen_depth.r, screen_depth.g)
	return screen_rg.dot(Vector2(1, 1.0 / 255.0))


## Predicts what the readback returns for distance `d` when the SubViewport
## target is 8-bit sRGB (it is on 4.2 Forward+): encode_rg() from
## gpu_depth.gdshader, linear->sRGB, round to 8 bits, then the plugin's
## srgb_to_linear() + decode. With far = 100000 the whole value sits in G,
## so the resolution is coarse (about 0.08 units at 7 units).
func _predict_8bit(d: float) -> float:
	var far := mouse_camera_3d.far
	var v := d / far
	var g := fposmod(255.0 * v, 1.0)
	var r := fposmod(v, 1.0) - g / 255.0
	var enc := Color(r, g, 0.0).linear_to_srgb()
	var q := Color(roundf(enc.r * 255.0) / 255.0, roundf(enc.g * 255.0) / 255.0, 0.0).srgb_to_linear()
	return Vector2(q.r, q.g).dot(Vector2(1, 1.0 / 255.0)) * far


## Same miss/far handling as click_raycast2(); returns -INF for a miss.
func _to_depth(normalized_distance: float) -> float:
	if is_zero_approx(normalized_distance):
		return -INF
	if normalized_distance > 0.9999:
		normalized_distance = 1.0
	return normalized_distance * mouse_camera_3d.far


func _run() -> void:
	print("Godot %s, renderer %s" % [Engine.get_version_info().string,
		ProjectSettings.get_setting("rendering/renderer/rendering_method")])
	var ok := true
	var origin := Vector3.ZERO
	var forward := Vector3(0, 0, -1)

	for d in HIT_DISTANCES:
		target.global_position = origin + forward * d
		target.show()
		var nd := await _sample(origin, forward)
		var got := _to_depth(nd)
		var predicted := _predict_8bit(d)
		# Pass if within tolerance of the true distance, or of the value an
		# 8-bit sRGB target is expected to quantize it to (upstream encoding
		# precision, not a port regression).
		var pass_ := is_finite(got) and (absf(got - d) <= TOLERANCE
			or absf(got - predicted) <= TOLERANCE)
		ok = ok and pass_
		print("DEPTH_PROBE expected=%.1f got=%.4f predicted_8bit=%.4f normalized=%.9f %s" % [
			d, got, predicted, nd, "PASS" if pass_ else "FAIL"])

	# Miss: nothing behind the cursor. Reported for reference (reversed-Z in
	# 4.3 may change what empty space decodes to); not part of pass/fail.
	target.hide()
	var nd_miss := await _sample(origin, forward)
	var miss := _to_depth(nd_miss)
	var kind := "miss(-INF)" if not is_finite(miss) else ("far" if nd_miss >= 0.9999 else "hit")
	print("MISS_PROBE normalized=%.9f decoded=%s -> %s" % [nd_miss, str(miss), kind])

	print("DEPTH_PROBE_RESULT %s" % ("PASS" if ok else "FAIL"))
	get_tree().quit(0 if ok else 1)
