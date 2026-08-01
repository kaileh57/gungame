shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;

// Ash mote. Alpha-blended and fogged, so the field thins out into the haze
// exactly like everything else in the world does rather than hanging in front of
// it. The motes closest to the eye are pulled down in opacity: a grain of grit
// half a metre from your face is a smear, and the reference never has one
// because its field is sparse enough to hide the problem.

uniform sampler2D mote_tex : source_color, filter_linear_mipmap;
uniform float opacity : hint_range(0.0, 1.0) = 0.30;
uniform float near_fade : hint_range(0.05, 8.0) = 1.2;

varying float v_near;

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
	vec3 to_eye = MODEL_MATRIX[3].xyz - INV_VIEW_MATRIX[3].xyz;
	v_near = smoothstep(0.0, near_fade, length(to_eye));
}

void fragment() {
	ALBEDO = COLOR.rgb;
	ALPHA = texture(mote_tex, UV).a * opacity * v_near;
}
