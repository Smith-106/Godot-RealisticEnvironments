#[compute]
#version 450
/*
 * The view's log-average luminance (Krawczyk et al. 2005's adaptation luminance): one
 * workgroup averages the natural log of the luminance over a GRID_X x GRID_Y grid of
 * texels spread across the HDR colour buffer, each at least floor_luminance, and writes
 * the mean log into the result buffer. Units are the colour buffer's (ViewLuminanceEffect
 * turns them into cd/m2).
 */

#define GRID_X 96
#define GRID_Y 54
#define THREADS 256

layout(local_size_x = THREADS, local_size_y = 1, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform restrict readonly image2D color_image;

layout(set = 0, binding = 1, std430) restrict writeonly buffer Result {
	float mean_log_luminance;
} result;

layout(push_constant, std430) restrict readonly uniform PushConstants {
	vec2 size;
	// The darkest luminance counted, in colour-buffer units (black pixels would make the
	// log average 0).
	float floor_luminance;
	float unused;
} pc;

shared float partial_sums[THREADS];

void main() {
	uint thread = gl_LocalInvocationID.x;
	float sum = 0.0;
	for (uint i = thread; i < GRID_X * GRID_Y; i += THREADS) {
		vec2 cell = vec2(float(i % GRID_X), float(i / GRID_X)) + 0.5;
		ivec2 texel = ivec2(cell / vec2(GRID_X, GRID_Y) * pc.size);
		vec3 rgb = max(imageLoad(color_image, texel).rgb, vec3(0.0));
		float luminance = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
		// NaN pixels count as the floor; overflowed ones as the brightest half float.
		luminance = isnan(luminance) ? pc.floor_luminance : min(luminance, 65504.0);
		sum += log(max(luminance, pc.floor_luminance));
	}
	partial_sums[thread] = sum;
	barrier();
	for (uint stride = THREADS / 2; stride > 0; stride /= 2) {
		if (thread < stride) {
			partial_sums[thread] += partial_sums[thread + stride];
		}
		barrier();
	}
	if (thread == 0) {
		result.mean_log_luminance = partial_sums[0] / float(GRID_X * GRID_Y);
	}
}
