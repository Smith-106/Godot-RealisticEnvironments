#[compute]
#version 460
/**
 * Samples the rendered ocean surface at arbitrary world-space points. Used by
 * buoyancy/gameplay queries, where reading back whole displacement textures
 * would be far too expensive.
 *
 * Heights add the interaction simulation's eta = h + p rather than the visible
 * h, so a hull's own rest depression (h = -p) never costs buoyancy, and its rate
 * joins the surface velocity, so what floats on a wake moves with its water as on
 * the FFT waves. Each point's mode (OceanSurfaceQueries) says whose waves:
 *   - MODE_INTERACTION (bodies that make no waves): eta outside hulls only (render
 *     .w = hull coverage): under a hull, eta is not a surface anything floats on.
 *   - k >= 0 (a body that makes waves): eta everywhere minus its own waves, those
 *     of own-wave simulation k (forced by its hulls alone): the waves of everything
 *     else, as every other body feels them. Its own waves reach it only as its
 *     buoyancy's radiation damping and added mass; read back after the query delay
 *     they would act as a lagging spring and drive it.
 */

#define WORKGROUP_SIZE 64U

layout(local_size_x = WORKGROUP_SIZE, local_size_y = 1, local_size_z = 1) in;

layout(push_constant) restrict readonly uniform PushConstants {
	uint point_count;
	uint cascade_count;
	float water_level;
	float normal_sample_distance;
	vec2 interaction_center;      // world XZ of the simulation window center
	float interaction_cell_size;
	float interaction_fade_start; // Chebyshev distance from the center (m)
	float interaction_fade_end;
};

#define OCEAN_SAMPLING_SET 0
#define OCEAN_CASCADE_BUFFER_BINDING 1
#define OCEAN_DISPLACEMENT_A_BINDING 3
#define OCEAN_DISPLACEMENT_B_BINDING 4
#include "ocean_sampling.glslinc"

struct SurfaceSample {
	vec4 displacement_height; // xyz = displacement of the surface point, w = height
	vec4 normal_data;         // xyz = normal, w = unused
	vec4 surface_velocity;    // xyz = displacement velocity, w = unused
};

layout(std430, set = 0, binding = 0) restrict readonly buffer PointBuffer {
	float points[]; // world positions, xyz tightly packed (PackedVector3Array bytes)
};

layout(std430, set = 0, binding = 2) restrict writeonly buffer SampleBuffer {
	SurfaceSample samples[];
};

#define OWN_WAVE_SLOTS 32
#define MODE_INTERACTION -1

layout(std430, set = 0, binding = 7) restrict readonly buffer ModeBuffer {
	int point_modes[];
};

// Per own-wave slot: window center x, z and fade start, end (Chebyshev distance, m).
layout(std430, set = 0, binding = 8) restrict readonly buffer OwnWindowBuffer {
	vec4 own_windows[OWN_WAVE_SLOTS];
};

// Interaction render textures (rgba16f: h, eta, foam, hull coverage) and eta's rate
// (r16f, m/s), wrap-around addressed: the interaction simulation's, then each
// own-wave simulation's (same cells, its own window).
layout(rgba16f, set = 0, binding = 5) restrict readonly uniform image2D interaction_render;
layout(r16f, set = 0, binding = 6) restrict readonly uniform image2D interaction_rate;
layout(rgba16f, set = 0, binding = 9) restrict readonly uniform image2D own_render[OWN_WAVE_SLOTS];
layout(r16f, set = 0, binding = 10) restrict readonly uniform image2D own_rate[OWN_WAVE_SLOTS];

float window_fade(vec2 p, vec2 center, float fade_start, float fade_end) {
	vec2 from_center = abs(p - center);
	return 1.0 - smoothstep(fade_start, fade_end, max(from_center.x, from_center.y));
}

// The four texels around p on a grid of dims cells (wrap-around) and their weights.
void bilinear_texels(vec2 p, ivec2 dims, out ivec2 texels[4], out vec4 weights) {
	vec2 q = p / interaction_cell_size - 0.5;
	ivec2 base = ivec2(floor(q));
	vec2 f = q - vec2(base);
	ivec2 p0 = base & (dims - 1);
	ivec2 p1 = (p0 + 1) & (dims - 1);
	texels = ivec2[4](p0, ivec2(p1.x, p0.y), ivec2(p0.x, p1.y), p1);
	weights = vec4((1.0 - f.x) * (1.0 - f.y), f.x * (1.0 - f.y), (1.0 - f.x) * f.y, f.x * f.y);
}

// Bilinear (eta, its rate) of the interaction waves at p for a point of mode.
vec2 sample_interaction(vec2 p, int mode) {
	float fade = window_fade(p, interaction_center, interaction_fade_start, interaction_fade_end);
	if (fade <= 0.0) {
		return vec2(0.0);
	}
	ivec2 texels[4];
	vec4 weights;
	bilinear_texels(p, imageSize(interaction_render), texels, weights);
	vec2 value = vec2(0.0);
	for (int i = 0; i < 4; ++i) {
		vec4 render = imageLoad(interaction_render, texels[i]);
		// Outside hulls only, unless the body's own waves are taken out below.
		float weight = weights[i] * (mode == MODE_INTERACTION ? 1.0 - render.w : 1.0);
		value += vec2(render.y, imageLoad(interaction_rate, texels[i]).x) * weight;
	}
	// The loop index keeps the image array index dynamically uniform.
	for (int k = 0; k < OWN_WAVE_SLOTS; ++k) {
		if (k != mode) {
			continue;
		}
		vec4 window = own_windows[k];
		float own_fade = window_fade(p, window.xy, window.z, window.w);
		if (own_fade <= 0.0) {
			break;
		}
		bilinear_texels(p, imageSize(own_render[k]), texels, weights);
		for (int i = 0; i < 4; ++i) {
			value -= vec2(imageLoad(own_render[k], texels[i]).y, imageLoad(own_rate[k], texels[i]).x) * weights[i] * own_fade;
		}
	}
	return value * fade;
}

void main() {
	uint index = gl_GlobalInvocationID.x;
	if (index >= point_count) {
		return;
	}

	vec2 p = vec2(points[3U * index], points[3U * index + 2U]);
	int mode = point_modes[index];
	vec2 source = ocean_invert_horizontal_displacement(p);
	vec3 visual_displacement;
	vec3 velocity;
	ocean_sample_displacement_and_velocity(source, visual_displacement, velocity);
	vec2 interaction = sample_interaction(p, mode);
	visual_displacement.y += interaction.x;
	velocity.y += interaction.y;

	// The rendered surface's normal from its tangents at the surface point over p: the
	// displaced positions of its rest neighbours (no inversion needed, unlike heights at
	// world offsets). Then the simulation's slope from its own heights.
	float e = max(normal_sample_distance, 0.001);
	vec3 tangent_x = vec3(2.0 * e, 0.0, 0.0) + ocean_sample_visual_displacement(source + vec2(e, 0.0)) - ocean_sample_visual_displacement(source - vec2(e, 0.0));
	vec3 tangent_z = vec3(0.0, 0.0, 2.0 * e) + ocean_sample_visual_displacement(source + vec2(0.0, e)) - ocean_sample_visual_displacement(source - vec2(0.0, e));
	vec3 normal = normalize(cross(tangent_z, tangent_x));
	vec2 slope = -normal.xz / normal.y + vec2(
			sample_interaction(p + vec2(e, 0.0), mode).x - sample_interaction(p - vec2(e, 0.0), mode).x,
			sample_interaction(p + vec2(0.0, e), mode).x - sample_interaction(p - vec2(0.0, e), mode).x) / (2.0 * e);
	normal = normalize(vec3(-slope.x, 1.0, -slope.y));

	samples[index].displacement_height = vec4(visual_displacement, water_level + visual_displacement.y);
	samples[index].normal_data = vec4(normal, 0.0);
	samples[index].surface_velocity = vec4(velocity, 0.0);
}
