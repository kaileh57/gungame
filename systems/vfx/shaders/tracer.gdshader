shader_type spatial;
render_mode
		unshaded,
		blend_add,
		depth_draw_never,
		cull_disabled,
		shadows_disabled,
		fog_disabled;

// Pooled tracer. One MultiMesh, one draw call, `instance_count` slots, and no
// CPU work at all after the segment is written: the streak walks from the muzzle
// to the impact point entirely in this vertex shader.
//
// The instance transform is the whole flight path - X spans muzzle to impact,
// Y is the ribbon width, Z faces the camera. The vertex shader then squeezes the
// quad down to the short lit section that has actually been reached:
//
//   INSTANCE_CUSTOM.x  vfx_time the shot was fired
//   INSTANCE_CUSTOM.y  lifetime in seconds
//   INSTANCE_CUSTOM.z  projectile speed in m/s, or 0 for an instant full streak
//   INSTANCE_CUSTOM.w  total path length in metres
//
// The reference draws a 1 px line at full length for 45 ms. A line is one pixel
// wide at any distance in Godot and reads as a scratch on the lens, so this is a
// ribbon; and a ribbon that travels is worth more than one that appears whole,
// because it tells you where the bullet went.

uniform sampler2D tracer_tex : source_color, filter_linear_mipmap;
uniform vec3 tracer_color : source_color = vec3(1.0, 0.878, 0.690);
uniform float vfx_time = 0.0;
uniform float streak_length : hint_range(0.5, 200.0) = 9.0;
uniform float peak_alpha : hint_range(0.0, 2.0) = 0.5;
uniform float brightness : hint_range(0.0, 8.0) = 2.2;

varying float v_alpha;

void vertex() {
	float born = INSTANCE_CUSTOM.x;
	float life = max(INSTANCE_CUSTOM.y, 0.0001);
	float speed = INSTANCE_CUSTOM.z;
	float path = max(INSTANCE_CUSTOM.w, 0.0001);
	float elapsed = max(vfx_time - born, 0.0);
	float head = (speed <= 0.0) ? path : min(speed * elapsed, path);
	float tail = max(head - streak_length, 0.0);
	// UV.x runs 0 at the muzzle end of the quad to 1 at the impact end; remap it
	// onto the lit window and let the instance basis put it back in the world.
	VERTEX.x = mix(tail, head, UV.x) / path - 0.5;
	v_alpha = (1.0 - clamp(elapsed / life, 0.0, 1.0)) * peak_alpha * step(0.001, head);
}

void fragment() {
	ALBEDO = tracer_color * brightness;
	ALPHA = texture(tracer_tex, UV).a * v_alpha;
}
