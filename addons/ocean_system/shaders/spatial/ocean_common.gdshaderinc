// Water optics and wave sampling shared by the water shader (water.gdshaderinc) and the
// underwater view (underwater.gdshader). The includer declares, before including it, the
// uniforms these read (with the water shader's names, so OceanSystem sets both alike):
// water_absorption, water_scattering, water_scattering_anisotropy, normal_scale,
// fragment_cascade_limit, num_cascades, map_scales, spectrum_blend_states,
// wave_frame_blends, normals_a, normals_b, water_level.

#define WATER_IOR 1.333
// Scattering by water molecules (1/m; Morel: 0.00193 (550 nm / lambda)^4.32 at the sRGB
// primaries' wavelengths), and the share particles scatter backward (Petzold, about 1.8%).
#define WATER_MOLECULAR_SCATTERING vec3(0.0012, 0.0019, 0.0040)
#define WATER_PARTICLE_BACKSCATTER_RATIO 0.018
// Caustics (caustic_light()): angular diameter (rad) of the sun's disk, which blurs them
// by that times the light's path; the share of the direct sun in a clear sky's light on
// a level surface; and the softening of the focus singularity (peak about 1 / it).
#define SUN_ANGULAR_DIAMETER 0.0093
#define CAUSTIC_CLEAR_SKY_DIRECT_SHARE 0.8
#define CAUSTIC_SOFTENING 0.12
// Mean cosine of the downwelling light's directions below the surface (about 0.8 under a
// high sun): its diffuse attenuation is K_d = (a + bb) / mean cosine (Kirk 1984).
#define WATER_DOWNWELLING_MEAN_COSINE 0.8

/* Henyey-Greenstein phase function (1/sr). */
float henyey_greenstein(float cos_theta, float g) {
	float g2 = g * g;
	return (1.0 - g2) / (4.0 * PI * pow(max(1.0 + g2 - 2.0 * g * cos_theta, 1e-6), 1.5));
}

/* Backscattering coefficient (1/m): half the molecular scattering, and the particles' share. */
vec3 water_backscattering() {
	return 0.5 * WATER_MOLECULAR_SCATTERING + WATER_PARTICLE_BACKSCATTER_RATIO * water_scattering;
}

/*
 * Radiance of optically deep water just below the surface per unit of the irradiance there
 * (rrs, 1/sr): 0.0949 u + 0.0794 u^2 with u = bb / (a + bb) (Gordon et al. 1988).
 */
vec3 water_subsurface_reflectance() {
	vec3 backscattering = water_backscattering();
	vec3 u = backscattering / (water_absorption + backscattering);
	return (0.0949 + 0.0794 * u) * u;
}

/* Cascade i's wave slope (gradient of the height) at a rest position, from mip lod. */
vec2 cascade_slope(uint i, vec2 rest_xz, float lod) {
	vec4 scales = map_scales[i];
	vec4 blend_state = spectrum_blend_states[i];
	float b_weight = wave_frame_blends[i].x;
	vec3 coords = vec3(rest_xz * scales.xy, blend_state.x);
	vec2 slope = mix(textureLod(normals_a, coords, lod).xy, textureLod(normals_b, coords, lod).xy, b_weight) * blend_state.z;
	// Uniform branch: the pending spectrum is only sampled during a crossfade.
	if (blend_state.w > 0.0) {
		coords.z = blend_state.y;
		slope += mix(textureLod(normals_a, coords, lod).xy, textureLod(normals_b, coords, lod).xy, b_weight) * blend_state.w;
	}
	return slope;
}

/*
 * Variance of the wave slopes within a footprint of width meters around a rest position,
 * summed over the cascades: what the mips average away there (E|g|^2 - |E g|^2).
 */
float slope_variance_within(vec2 rest_xz, float width) {
	float map_size = float(textureSize(normals_a, 0).x);
	float variance = 0.0;
	uint cascade_count = min(uint(num_cascades), uint(fragment_cascade_limit));
	for (uint i = 0U; i < cascade_count; ++i) {
		vec4 scales = map_scales[i];
		vec4 blend_state = spectrum_blend_states[i];
		float texel = 1.0 / (map_size * max(scales.x, scales.y));
		float lod = log2(max(width / texel, 1.0));
		vec4 a = textureLod(normals_a, vec3(rest_xz * scales.xy, blend_state.x), lod);
		vec4 b = textureLod(normals_b, vec3(rest_xz * scales.xy, blend_state.x), lod);
		vec4 m = mix(a, b, wave_frame_blends[i].x);
		variance += max(m.z - dot(m.xy, m.xy), 0.0) * blend_state.z * blend_state.z;
	}
	return variance * normal_scale * normal_scale;
}

/*
 * How much the waves focus (above 1) or spread (below 1) sunlight that entered the water
 * at rest position entry_rest, after a path of `path` meters below the surface (k: the
 * refracted ray's deviation per unit slope, 1 - cos i / (n cos t); see caustic_light()).
 * Refraction turns a slope s into a deviation k s, so the light lands spread by
 * 1 / det(I - path k H), H the height's Hessian (the slopes' gradient). Light reaching one
 * point comes from a patch about r = path k sigma wide, sigma the deviation of the slopes
 * of waves shorter than r: those focus far above it and their light arrives evenly mixed.
 * So H is differenced over r (found by iterating from the patch of all slopes), or over
 * `blur` (the sun's disk over the path, a pixel's footprint) if wider, from the mips that
 * average the waves finer than it.
 */
float caustic_focus(vec2 entry_rest, float path, float k, float blur) {
	float mixing = path * k * sqrt(slope_variance_within(entry_rest, 1.0e6));
	for (int iteration = 0; iteration < 2; ++iteration)
		mixing = path * k * sqrt(slope_variance_within(entry_rest, max(mixing, blur)));
	blur = max(blur, mixing);
	float map_size = float(textureSize(normals_a, 0).x);
	mat2 hessian = mat2(0.0);
	uint cascade_count = min(uint(num_cascades), uint(fragment_cascade_limit));
	for (uint i = 0U; i < cascade_count; ++i) {
		vec4 scales = map_scales[i];
		float texel = 1.0 / (map_size * max(scales.x, scales.y));
		float e = max(blur, texel);
		float lod = log2(e / texel);
		vec2 dx = vec2(e, 0.0);
		vec2 dz = vec2(0.0, e);
		hessian[0] += (cascade_slope(i, entry_rest + dx, lod) - cascade_slope(i, entry_rest - dx, lod)) / (2.0 * e);
		hessian[1] += (cascade_slope(i, entry_rest + dz, lod) - cascade_slope(i, entry_rest - dz, lod)) / (2.0 * e);
	}
	mat2 jacobian = mat2(1.0) - path * k * normal_scale * hessian;
	return inversesqrt(determinant(jacobian) * determinant(jacobian) + CAUSTIC_SOFTENING * CAUSTIC_SOFTENING);
}

/*
 * The sun's light scattered once toward a viewer looking along direction under the water,
 * per unit of irradiance at the surface (1/m sr): the direct share of that light
 * (CAUSTIC_CLEAR_SKY_DIRECT_SHARE times sun_visibility) refracted into the water as a
 * beam, scattered by the particles' forward lobe and the molecules. sun_in_water: the
 * refracted direction toward the sun; 0 while the sun is down.
 */
vec3 underwater_sun_source(vec3 direction, vec3 to_sun, float sun_visibility, out vec3 sun_in_water) {
	sun_in_water = vec3(0.0, 1.0, 0.0);
	if (to_sun.y <= 0.0) {
		return vec3(0.0);
	}
	sun_in_water = -refract(-to_sun, vec3(0.0, 1.0, 0.0), 1.0 / WATER_IOR);
	float cos_scatter = dot(direction, sun_in_water);
	vec3 scattering = water_scattering * henyey_greenstein(cos_scatter, water_scattering_anisotropy)
			+ WATER_MOLECULAR_SCATTERING * (3.0 / (16.0 * PI)) * (1.0 + cos_scatter * cos_scatter);
	return CAUSTIC_CLEAR_SKY_DIRECT_SHARE * sun_visibility / max(sun_in_water.y, 0.05) * scattering;
}

/*
 * Light the water scatters toward a viewer `depth` meters below the surface, along `path`
 * meters of a ray in direction (unit, away from the viewer), for irradiance on a level
 * surface just above the water (unexposed scene units). The light at depth z is the
 * surface's dimmed by the downwelling attenuation K_d; integrated along the ray, whose
 * depth changes as it climbs or sinks, through the beam attenuation back to the viewer.
 * The diffuse part makes the deep water's own radiance looking down
 * (water_subsurface_reflectance(): the source a + K_d times rrs), and more looking up,
 * where the path climbs toward the light; the sun's part adds the glow around its
 * refracted direction (underwater_sun_source()). One model for the underwater view and
 * the surface seen from below, so they meet without a seam.
 */
vec3 underwater_path_light(vec3 direction, float depth, float path, vec3 irradiance, vec3 to_sun, float sun_visibility) {
	vec3 attenuation = water_absorption + water_scattering + WATER_MOLECULAR_SCATTERING;
	vec3 downwelling = (water_absorption + water_backscattering()) / WATER_DOWNWELLING_MEAN_COSINE;
	vec3 rate = max(attenuation - downwelling * direction.y, vec3(1e-4));
	vec3 integral = (vec3(1.0) - exp(-rate * path)) / rate;
	vec3 sun_in_water;
	vec3 source = water_subsurface_reflectance() * (attenuation + downwelling) + underwater_sun_source(direction, to_sun, sun_visibility, sun_in_water);
	return irradiance * exp(-downwelling * depth) * source * integral;
}

// Steps of the light-shaft march (underwater_shafts()), and how far it goes (m): the waves'
// focus blurs out with depth (the sun's disk and the mixing of the slopes), so far shafts
// are even light.
#define SHAFT_STEPS 8
#define SHAFT_DISTANCE 30.0

/* Per-pixel jitter in [0, 1) (interleaved gradient noise, Jimenez 2014). */
float interleaved_gradient_noise(vec2 pixel) {
	return fract(52.9829189 * fract(dot(pixel, vec2(0.06711056, 0.00583715))));
}

/*
 * Light shafts: the waves above focus and spread the sun's light in the water
 * (caustic_focus()), so its single scattering along an underwater ray (from origin, in
 * direction, `path` meters long) is uneven. Returns what that adds to its mean (in
 * underwater_path_light()), unexposed: marched over the near SHAFT_DISTANCE meters in
 * SHAFT_STEPS jittered steps. The shafts are blurred across by the sun's disk over the
 * light's path and by the pixel (pixel_angle, rad) over the distance. water_level: the
 * includer's uniform.
 */
vec3 underwater_shafts(vec3 origin, vec3 direction, float path, vec3 irradiance, vec3 to_sun, float sun_visibility, float pixel_angle, float jitter) {
	vec3 sun_in_water;
	vec3 sun_source = underwater_sun_source(direction, to_sun, sun_visibility, sun_in_water);
	if (sun_source == vec3(0.0) || num_cascades == 0) {
		return vec3(0.0);
	}
	vec3 attenuation = water_absorption + water_scattering + WATER_MOLECULAR_SCATTERING;
	vec3 downwelling = (water_absorption + water_backscattering()) / WATER_DOWNWELLING_MEAN_COSINE;
	float cos_t = max(sun_in_water.y, 0.05);
	float k = 1.0 - to_sun.y / (WATER_IOR * cos_t);
	float step_length = min(path, SHAFT_DISTANCE) / float(SHAFT_STEPS);
	vec3 shafts = vec3(0.0);
	for (int i = 0; i < SHAFT_STEPS; ++i) {
		float t = (float(i) + jitter) * step_length;
		vec3 point = origin + direction * t;
		float point_depth = water_level - point.y;
		if (point_depth <= 0.0) {
			break;
		}
		float sun_path = point_depth / cos_t;
		// Where the light reaching this point entered (rest position: the waves'
		// horizontal displacement is left out).
		vec2 entry = point.xz + sun_in_water.xz * sun_path;
		float focus = caustic_focus(entry, sun_path, k, max(SUN_ANGULAR_DIAMETER * sun_path, pixel_angle * t));
		shafts += exp(-downwelling * point_depth - attenuation * t) * (focus - 1.0) * step_length;
	}
	return irradiance * sun_source * shafts;
}
