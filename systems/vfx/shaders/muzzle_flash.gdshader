shader_type spatial;
render_mode
		unshaded,
		blend_add,
		depth_draw_never,
		depth_test_disabled,
		cull_disabled,
		shadows_disabled,
		fog_disabled;

// Muzzle flare sprite, additive and depth-test-free so it never clips into the
// barrel it is coming out of (the reference sets depthTest:false for the same
// reason). Opacity and roll are instance uniforms, so the pool shares one
// material across every gun in the scene and still gets a different flash each
// shot.

uniform sampler2D flash_tex : source_color, filter_linear_mipmap;
uniform float brightness : hint_range(0.0, 12.0) = 3.2;

instance uniform float opacity : hint_range(0.0, 1.0);
instance uniform float roll : hint_range(0.0, 6.2832);

void vertex() {
	vec2 quad_scale = vec2(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[1].xyz));
	VERTEX.xy *= quad_scale;
	MODELVIEW_MATRIX =
			VIEW_MATRIX
			* mat4(
					INV_VIEW_MATRIX[0],
					INV_VIEW_MATRIX[1],
					INV_VIEW_MATRIX[2],
					MODEL_MATRIX[3]
			);
}

void fragment() {
	vec2 centred = UV - vec2(0.5);
	float s = sin(roll);
	float c = cos(roll);
	vec2 uv = vec2(centred.x * c - centred.y * s, centred.x * s + centred.y * c) + vec2(0.5);
	vec4 texel = texture(flash_tex, uv);
	ALBEDO = texel.rgb * brightness;
	ALPHA = texel.a * opacity;
}
