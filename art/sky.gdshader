shader_type sky;

// The ash-flats sky: a warm dust band on the horizon under a dusty blue zenith,
// one low sun, and a two-sine dust smear that never resolves into anything you
// could call a cloud.
//
// Every colour here is LINEAR and is written straight out before tone mapping,
// which is why none of the uniforms carry the `source_color` hint — hinting them
// would convert them a second time and wash the whole sky out. The palette they
// come from is sRGB, so `build_art.gd` linearises on the way in; feeding the raw
// sRGB numbers here is what used to make the dome read as flat cream.
//
// The gradient has to do its work inside the frame. A 78-degree camera aimed at
// the horizon only sees up to h = 0.63, so the ramp has to be finished well
// before the zenith. But the haze band has to be WIDE, not narrow: a six-degree
// band is entirely hidden behind the terrain at eye height, and what the player
// then sees filling the sky is `mid_color` alone — one flat achromatic value
// across forty degrees of frame. That was the white-out. The band is now an
// exponential decay rather than a smoothstep with an end, so the warm horizon
// keeps tinting the dome all the way up instead of stopping dead.

// Direction TOWARD the sun. Kept in sync with the Sun light by
// `res://art/world_environment.gd`, so moving the sun moves its disc.
uniform vec3 sun_direction = vec3(-0.623623, 0.275634, -0.731519);

uniform vec3 zenith_color = vec3(0.126, 0.175, 0.256);
uniform vec3 mid_color = vec3(0.324, 0.338, 0.360);
uniform vec3 horizon_color = vec3(0.773, 0.577, 0.366);
// What the sky fades to below the horizon. Sits just under the fog colour so the
// far edge of the terrain mesh has nothing to give itself away against.
uniform vec3 ground_color = vec3(0.426, 0.320, 0.214);

// Scale height, in units of sin(elevation), of the warm haze. The band is an
// e-folding decay, so 0.18 still leaves a third of the horizon colour at ten
// degrees and a seventh at twenty — the whole visible sky is tinted by it.
uniform float horizon_band : hint_range(0.02, 0.60) = 0.18;

// Overall level of the dome. The four stops are authored as radiance the sky
// would have under a neutral exposure; this is where the sky is balanced against
// the ground, and it is also the ambient control, because `ambient_light_source`
// is the sky and the radiance map is built from exactly this output. Dropping it
// darkens the dome and deepens every shadow in the game by the same amount, which
// is the correct coupling — a dimmer sky really does cast less fill.
uniform float sky_energy : hint_range(0.1, 2.0) = 1.0;

// Four sun terms, and the exponents are what matter. pow(s, N) is at half
// strength sqrt(2 ln2 / N) radians off axis, so the old halo exponent of 14 was
// still at half strength EIGHTEEN degrees out — a saucer covering an eighth of
// the frame, which is what the blown white sun actually was. These are 24 deg,
// 6.4 deg, 1.8 deg and 0.57 deg; the last is about twice the true angular radius
// of the sun, which is as tight as a disc can be without aliasing.
uniform float sun_disc : hint_range(0.0, 24.0) = 9.0;
uniform float sun_halo : hint_range(0.0, 2.0) = 0.075;
uniform float sun_glow : hint_range(0.0, 1.0) = 0.022;
uniform float cloud_amount : hint_range(0.0, 2.0) = 1.0;

// GLSL's smoothstep is undefined for edge0 > edge1, and the below-horizon blend
// needs exactly that. Hand-rolled so the horizon does not become a hard seam on
// drivers that take the spec at its word.
float ss(float e0, float e1, float x) {
	float t = clamp((x - e0) / (e1 - e0), 0.0, 1.0);
	return t * t * (3.0 - 2.0 * t);
}

void sky() {
	vec3 d = normalize(EYEDIR);
	float h = d.y;

	vec3 c;
	if (h > 0.0) {
		vec3 upper = mix(mid_color, zenith_color, ss(0.10, 0.62, h));
		c = mix(upper, horizon_color, exp(-h / max(horizon_band, 0.01)));
	} else {
		c = mix(horizon_color, ground_color, ss(0.0, -0.06, h));
	}

	// Dust, not cloud. Two sines beating against each other, with three constraints
	// learned the hard way. The rates have to be high enough that the lobes are
	// smaller than the frame, or the sky grows soft grey blotches the size of a
	// building. Both sines need a height term, because `d.xz` barely changes as you
	// look up and a pure function of azimuth draws itself as vertical stripes
	// running from the horizon to the top of the frame. And it belongs in the band
	// from about one to thirty-five degrees, where dust actually hangs — carried up
	// to the zenith it reads as dirt on the lens.
	float n = sin(d.x * 21.0 + d.z * 13.0 + d.y * 27.0)
		* sin(d.z * 17.0 - d.x * 9.0 - d.y * 19.0);
	float band = smoothstep(0.02, 0.14, h) * (1.0 - smoothstep(0.22, 0.62, h));
	c += vec3(0.022, 0.020, 0.017) * smoothstep(0.18, 0.95, n) * band * cloud_amount;

	// The dome — gradient and dust together — is scaled here, before the sun. The
	// sun is a light source and keeps its own absolute amplitude: dimming the sky
	// must not dim the sun, or the disc goes grey along with everything else.
	c *= sky_energy;

	float s = max(dot(d, normalize(sun_direction)), 0.0);
	c += vec3(1.0, 0.74, 0.46) * pow(s, 8.0) * sun_glow;
	c += vec3(1.0, 0.82, 0.56) * pow(s, 110.0) * sun_halo;
	c += vec3(1.0, 0.90, 0.70) * pow(s, 1400.0) * sun_halo * 1.8;
	c += vec3(1.0, 0.96, 0.86) * pow(s, 14000.0) * sun_disc;

	COLOR = c;
}
