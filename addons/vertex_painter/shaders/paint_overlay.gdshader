shader_type spatial;
// Vertex Painter "Normal" paint mode. Drawn as the next pass over the mesh's
// own material: vertex COLOR.rgb is the paint color (sRGB, as picked) and
// COLOR.a is how much it covers the material underneath (0 = not painted).
render_mode blend_mix, depth_draw_never, cull_back;

vec3 srgb_to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + vec3(0.055)) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

void fragment() {
	ALBEDO = srgb_to_linear(COLOR.rgb);
	ALPHA = COLOR.a;
}
