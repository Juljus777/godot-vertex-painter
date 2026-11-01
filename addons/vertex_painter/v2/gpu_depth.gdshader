shader_type spatial;
render_mode unshaded;

uniform sampler2D depth_texture : source_color, hint_depth_texture, filter_nearest, repeat_disable;

uniform float camera_far = 100000.0;

// The linear distance is written as a 24-bit integer split over R, G and B
// (8 bits each): about 6 mm steps over the camera's 100 km range. (Two
// channels gave ~1.5 m steps, which grew to 10+ m errors once the sRGB
// conversion below was involved, painting far from the cursor when zoomed
// out.) The viewport stores colors as 8-bit sRGB, converting from linear on
// output, so each byte is pre-converted to linear here to come back exact.
vec3 srgb_to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + vec3(0.055)) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

void fragment() {
	float depth = textureLod(depth_texture, SCREEN_UV, 0.).x;
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, depth);
	vec4 view = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	view.xyz /= view.w;
	float d = floor(clamp(-view.z / camera_far, 0.0, 1.0) * 16777215.0);
	float r = floor(d / 65536.0);
	float g = floor((d - r * 65536.0) / 256.0);
	float b = d - r * 65536.0 - g * 256.0;
	ALBEDO = srgb_to_linear(vec3(r, g, b) / 255.0);
}
