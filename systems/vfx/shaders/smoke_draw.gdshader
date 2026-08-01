shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;

// Smoke sprite. The reference recolours every sprite each frame from
// `HAZE*(1-d) + 0.10*d` with `d = dark * life/maxLife`, so a puff is born sooty
// and ends as haze. That is a straight lerp from the birth colour to the haze
// colour over the particle's life, which is what happens here for free.
//
// The reference pops its sprites out at end of life. This fades them instead,
// and grows them a little as they age, which is the only liberty taken.

uniform sampler2D smoke_tex : source_color, filter_linear_mipmap;
uniform vec3 haze_color : source_color = vec3(0.62, 0.66, 0.70);
uniform float opacity : hint_range(0.0, 1.0) = 0.50;
uniform float grow : hint_range(0.0, 3.0) = 0.55;
uniform float fade_in : hint_range(0.001, 0.5) = 0.08;
uniform float fade_out : hint_range(0.01, 1.0) = 0.32;

// CUSTOM.y, the particle's age, is only readable in the vertex stage.
varying float v_age;

void vertex() {
	float age = clamp(INSTANCE_CUSTOM.y, 0.0, 1.0);
	v_age = age;
	vec2 quad_scale =
			vec2(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[1].xyz)) * (1.0 + grow * age);
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
	float remaining = 1.0 - age;
	ALBEDO = mix(haze_color, COLOR.rgb, remaining);
	ALPHA =
			texture(smoke_tex, UV).a
			* opacity
			* smoothstep(0.0, fade_in, age)
			* smoothstep(0.0, fade_out, remaining);
}
