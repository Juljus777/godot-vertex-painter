shader_type spatial;
// Vertex Painter "Normal" paint mode. Drawn as the next pass over the mesh's
// own material. Vertex COLOR is PREMULTIPLIED: rgb = paint color (sRGB, as
// picked) x coverage, a = coverage (0 = not painted). Dividing by alpha here,
// per fragment, gives clean edges; interpolating plain colors toward the
// unpainted vertices made a fringe in their color around the paint.
render_mode blend_mix, depth_draw_never, cull_back;

vec3 srgb_to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + vec3(0.055)) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

void fragment() {
	vec3 paint = COLOR.a > 0.0001 ? min(COLOR.rgb / COLOR.a, vec3(1.0)) : vec3(0.0);
	ALBEDO = srgb_to_linear(paint);
	ALPHA = COLOR.a;
}
