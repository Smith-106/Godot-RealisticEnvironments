shader_type spatial;
render_mode world_vertex_coords, cull_disabled, depth_draw_always;
// No water where a WaterMask's lid is in view (WaterMask.STENCIL_REFERENCE).
stencil_mode read, compare_not_equal, 128;
// Water, quality High: every feature, full step counts (OceanSystem.shader_quality). The shader is water.gdshaderinc.
#include "res://addons/ocean_system/shaders/spatial/water.gdshaderinc"
