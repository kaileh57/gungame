shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;

// Heat haze over a hot surface: a scorched barrel, a burning wreck, the ground
// where something just went off. It refracts what is already on screen rather
// than adding anything to it, so it costs one transparent quad and reads as air
// instead of as a sprite.
//
// The quad fades out at its own edge so there is never a visible boundary
// between refracted and unrefracted screen. `opacity` is an instance uniform so
// the pool shares one material and still fades each puff of heat out on its own
// schedule.

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D noise_tex : source_color, repeat_enable, filter_linear;
uniform float vfx_time = 0.0;
uniform float strength : hint_range(0.0, 0.06) = 0.008;
uniform float rise_speed : hint_range(0.0, 2.0) = 0.28;
uniform float noise_scale : hint_range(0.25, 8.0) = 1.6;

instance uniform float opacity : hint_range(0.0, 1.0);

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
	vec2 flow = UV * noise_scale + vec2(vfx_time * 0.07, -vfx_time * rise_speed);
	vec2 wobble = texture(noise_tex, flow).rg - vec2(0.5);
	float edge = smoothstep(0.5, 0.12, length(UV - vec2(0.5)));
	float amount = edge * clamp(opacity, 0.0, 1.0);
	ALBEDO = textureLod(screen_tex, SCREEN_UV + wobble * strength * amount, 0.0).rgb;
	ALPHA = amount;
}
