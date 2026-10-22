#[compute]
#version 460
/**
 * Samples the rendered ocean surface at arbitrary world-space points. Used by
 * gameplay queries, where reading back whole displacement textures would be far
 * too expensive. The interactive waves are left out (bodies never feel them),
 * except for the first interaction_point_count points (OceanSystem's camera).
 */

#define WORKGROUP_SIZE 64U

layout(local_size_x = WORKGROUP_SIZE, local_size_y = 1, local_size_z = 1) in;

layout(push_constant) restrict readonly uniform PushConstants {
	uint point_count;
	uint cascade_count;
	float water_level;
	float normal_sample_distance;
	uint interaction_point_count;
	// The interactive waves' window (OceanInteraction.get_window()) and where they
	// start to fade out (share of the half size), as interaction_fade() in water.gdshaderinc.
	float interaction_center_x;
	float interaction_center_z;
	float interaction_half_size;
	float interaction_map_scale;
	float interaction_fade_start;
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

// The interactive waves' map (OceanInteraction): x = height at a rest position, repeating
// every window; repeat, linear sampler.
layout(set = 0, binding = 5) uniform sampler2D interaction_map;

void main() {
	uint index = gl_GlobalInvocationID.x;
	if (index >= point_count) {
		return;
	}

	vec2 p = vec2(points[3U * index], points[3U * index + 2U]);
	vec2 source = ocean_invert_horizontal_displacement(p);
	vec3 visual_displacement;
	vec3 velocity;
	ocean_sample_displacement_and_velocity(source, visual_displacement, velocity);

	// The rendered surface's normal from its tangents at the surface point over p: the
	// displaced positions of its rest neighbours (no inversion needed, unlike heights at
	// world offsets).
	float e = max(normal_sample_distance, 0.001);
	vec3 tangent_x = vec3(2.0 * e, 0.0, 0.0) + ocean_sample_visual_displacement(source + vec2(e, 0.0)) - ocean_sample_visual_displacement(source - vec2(e, 0.0));
	vec3 tangent_z = vec3(0.0, 0.0, 2.0 * e) + ocean_sample_visual_displacement(source + vec2(0.0, e)) - ocean_sample_visual_displacement(source - vec2(0.0, e));
	vec3 normal = normalize(cross(tangent_z, tangent_x));

	float height = water_level + visual_displacement.y;
	if (index < interaction_point_count) {
		vec2 offset = abs(source - vec2(interaction_center_x, interaction_center_z)) / interaction_half_size;
		float fade = 1.0 - smoothstep(interaction_fade_start, 1.0, max(offset.x, offset.y));
		height += textureLod(interaction_map, source * interaction_map_scale, 0.0).x * fade;
	}
	samples[index].displacement_height = vec4(visual_displacement, height);
	samples[index].normal_data = vec4(normal, 0.0);
	samples[index].surface_velocity = vec4(velocity, 0.0);
}
