shader_type spatial;
render_mode
		unshaded,
		blend_add,
		depth_draw_never,
		cull_disabled,
		shadows_disabled,
		fog_disabled;

// Additive spark sprite. The reference fades a spark by multiplying its colour
// toward black and letting additive blending make it vanish; the same curve
// lives here, driven by the age the process shader writes into CUSTOM.y.
//
// Fog is off deliberately: additive geometry cannot be fogged without adding
// haze colour to the frame, which turns distant sparks into grey smears.

uniform sampler2D spark_tex : source_color, filter_linear_mipmap;
uniform float brightness : hint_range(0.0, 6.0) = 1.4;

// CUSTOM.y, the particle's age, is only readable in the vertex stage.
varying float v_age;

void vertex() {
	// Camera-facing billboard that keeps the particle's own scale.
	v_age = clamp(INSTANCE_CUSTOM.y, 0.0, 1.0);
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
	float fade = 1.0 - v_age;
	ALBEDO = COLOR.rgb * brightness * fade;
	ALPHA = texture(spark_tex, UV).a * COLOR.a;
}
