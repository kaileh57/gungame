shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;

// Hit spray: blood, gut and machine oil. Same integrator as the sparks, but
// alpha-blended rather than additive, because a droplet occludes what is behind
// it instead of glowing. It darkens rather than dims as it ages, and the fade is
// quadratic so the spray reads as a burst and not as a slow dissolve.

uniform sampler2D spark_tex : source_color, filter_linear_mipmap;
uniform float darken : hint_range(0.0, 1.0) = 0.45;

// CUSTOM.y, the particle's age, is only readable in the vertex stage.
varying float v_age;

void vertex() {
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
	float age = v_age;
	ALBEDO = COLOR.rgb * (1.0 - darken * age);
	ALPHA = texture(spark_tex, UV).a * COLOR.a * (1.0 - age * age);
}
