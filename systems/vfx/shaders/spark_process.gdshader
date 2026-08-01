shader_type particles;
render_mode disable_force, disable_velocity;

// Impact-spark and hit-spray integrator. This is the reference's stepP() moved
// onto the GPU verbatim (range spec 16.1): gravity is 11 m/s^2 times a
// per-particle scale, and a bounce plane keeps 45 % of the horizontal speed and
// reverses 28 % of the vertical.
//
// Nothing here spawns particles. The node's own emitter is only kept running so
// the system is guaranteed to be processed every frame; any particle it fills in
// by itself is killed on the spot in start(). Everything you actually see came
// from a GPUParticles3D.emit_particle() call, which carries:
//
//   CUSTOM.x  gravity scale   (1.0 default, 0.7 blast fire, 0.2 blast debris)
//   CUSTOM.y  age, 0 at birth, driven to 1 here, read by the draw pass
//   CUSTOM.z  lifetime in seconds
//   CUSTOM.w  world Y of the bounce plane for this particle

uniform float gravity : hint_range(0.0, 40.0) = 11.0;
uniform float bounce_offset : hint_range(0.0, 0.5) = 0.03;
uniform float bounce_keep_horizontal : hint_range(0.0, 1.0) = 0.45;
uniform float bounce_keep_vertical : hint_range(0.0, 1.0) = 0.28;
uniform float particle_size : hint_range(0.001, 2.0) = 0.055;

void start() {
	TRANSFORM[0].xyz = vec3(particle_size, 0.0, 0.0);
	TRANSFORM[1].xyz = vec3(0.0, particle_size, 0.0);
	TRANSFORM[2].xyz = vec3(0.0, 0.0, particle_size);
	if (RESTART_CUSTOM) {
		// Filler from the node's own emitter. Collapse it and drop it.
		TRANSFORM[0].xyz = vec3(0.0);
		TRANSFORM[1].xyz = vec3(0.0);
		TRANSFORM[2].xyz = vec3(0.0);
		CUSTOM = vec4(0.0, 1.0, 0.001, 0.0);
		COLOR = vec4(0.0);
		ACTIVE = false;
	}
}

void process() {
	CUSTOM.y += DELTA / max(CUSTOM.z, 0.001);
	if (CUSTOM.y >= 1.0) {
		ACTIVE = false;
	}
	VELOCITY.y -= gravity * CUSTOM.x * DELTA;
	vec3 p = TRANSFORM[3].xyz + VELOCITY * DELTA;
	float plane = CUSTOM.w + bounce_offset;
	if (p.y < plane) {
		p.y = plane;
		VELOCITY.xz *= bounce_keep_horizontal;
		VELOCITY.y *= -bounce_keep_vertical;
	}
	TRANSFORM[3].xyz = p;
}
