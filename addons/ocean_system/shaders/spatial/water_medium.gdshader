shader_type spatial;
render_mode world_vertex_coords, cull_disabled, depth_draw_always;
// No water where a WaterMask's lid is in view (WaterMask.STENCIL_REFERENCE).
stencil_mode read, compare_not_equal, 128;
// Water, quality Medium: shorter searches and marches (OceanSystem.shader_quality). The shader is water.gdshaderinc.
#define REFRACTION_MARCH_STEPS 16
#define REFRACTION_REFINE_STEPS 4
#define CREST_MARCH_STEPS 5
#define NORMAL_ANISOTROPY_TAPS 4
#define PLANAR_REFLECTION_STEPS 2
#include "res://addons/ocean_system/shaders/spatial/water.gdshaderinc"
