@tool
class_name OceanSystem
extends MeshInstance3D
## An open ocean out to the horizon: FFT wave cascades of one wind-driven spectrum
## (spectrum, cascades), a level-of-detail mesh on the earth's curve, physically based
## water optics, foam, sky and scene reflections, and wakes, bow waves and splashes
## around hulls (HullWaterFootprint). Instance ocean_system.tscn; see
## addons/ocean_system/README.md.
##
## The ocean registers a WaterSurface for its world: whatever floats on it or
## disturbs it uses WaterSurface.find(), never this node. The waves follow a wind
## source (wind_source_path, else the spectrum's own wind) and the water reflects a sky
## source (sky_source_path, else the manual_* values). The water lies at water_level;
## the node's own transform is ignored, so leave it at the origin, level and unscaled.

## How the water reflects the scene's geometry (reflection_mode). The sky, its clouds
## and stars are always reflected.
enum ReflectionMode {
	## No geometry.
	SKY_ONLY,
	## The reflected rays are marched against what the camera already drew: nearly
	## free, but what is off screen or hidden is missed and hits fade at the screen's edges.
	SCREEN_SPACE,
	## A mirrored camera renders the scene: complete, but a second scene render.
	PLANAR,
}
## The stock water shader's tiers (shader_quality).
enum ShaderQuality { LOW, MEDIUM, HIGH }

const WATER_MAT := preload('res://addons/ocean_system/mat_water.tres')
## The stock water shader's tiers, in ShaderQuality order. All include
## shaders/spatial/water.gdshaderinc with different compile-time features.
const WATER_SHADERS : Array[Shader] = [
	preload('res://addons/ocean_system/shaders/spatial/water_low.gdshader'),
	preload('res://addons/ocean_system/shaders/spatial/water_medium.gdshader'),
	preload('res://addons/ocean_system/shaders/spatial/water.gdshader'),
]
const EDITOR_WATER_PREVIEW_MESH := preload('res://addons/ocean_system/editor_water_preview_mesh.tres')
const OceanReflectionRenderer := preload('res://addons/ocean_system/ocean_reflection_renderer.gd')
const MAX_CASCADES := 8
## The FFT sizes simulation_map_size accepts (fft_compute.glsl has one version each).
const SIMULATION_MAP_SIZES : Array[int] = [128, 256, 512, 1024]
## Point lights of the sky (the planets) the water reflects as glints; as MAX_SKY_POINTS in water.gdshader.
const MAX_SKY_POINTS := 8
## The water is drawn on a sphere of this radius (meters) touching the camera's
## sea-level point (water.gdshader, EARTH_RADIUS), so it ends at a real horizon.
## Only the drawing: surface queries, buoyancy and the simulation stay flat.
const EARTH_RADIUS := 6371000.0
## The cascades split the spectrum by tile length (_update_spectrum_bands()): a
## cascade draws waves no longer than its tile / CASCADE_BAND_WAVES_PER_TILE. Its
## longest few waves are the most regular (few directions, tile-periodic), so the
## next larger cascade draws those, ...
const CASCADE_BAND_WAVES_PER_TILE := 6.0
## ... as long as they span at least this many of its texels; otherwise the smaller
## cascade starts at that length instead.
const CASCADE_BAND_MIN_TEXELS := 4.0

## Height of the still water in world units. The surface is drawn here, and water
## queries, buoyancy, hull cutouts and planar reflections use it; the node's own
## position does not move the sea. Keep the sky's sea_level equal to it
## (OceanEnvironment.sea_level sets both).
@export var water_level := 0.0 :
	set(value):
		water_level = value
		update_configuration_warnings()
		_set_water_shader_parameter(&'water_level', water_level)
		_update_planar_reflection_settings()

@export_group('Waves')
## The sea state shared by every cascade: the wind while there is no wind source, the
## spectrum's shape and the waves' height. Edits crossfade the waves to the new spectrum.
@export var spectrum : WaveSpectrum = WaveSpectrum.new() :
	set(value):
		spectrum = value if value != null else WaveSpectrum.new()
## The wave cascades (at most MAX_CASCADES): tiles of the spectrum, each drawing its own
## band of wavelengths, from long swell (large tile_length) to short chop. Adding or
## removing one rebuilds the GPU resources.
@export var cascades : Array[WaveCascade] :
	set(value):
		for cascade in cascades:
			if cascade != null and cascade.changed.is_connected(_on_cascade_changed):
				cascade.changed.disconnect(_on_cascade_changed)
		var new_cascades := value
		if new_cascades.size() > MAX_CASCADES:
			push_error("OceanSystem supports at most %d wave cascades; the extra ones are dropped." % MAX_CASCADES)
			new_cascades.resize(MAX_CASCADES)
		for i in new_cascades.size():
			# Inspector array slots start empty; give them a valid cascade.
			if new_cascades[i] == null:
				new_cascades[i] = WaveCascade.new()
			if not new_cascades[i].changed.is_connected(_on_cascade_changed):
				new_cascades[i].changed.connect(_on_cascade_changed)
		cascades = new_cascades
		_update_cascade_states()
		_setup_wave_generator()
		_on_cascade_changed()
## The wind the waves follow: a WindSystem, or any node with the wind contract (see
## core's WindSource). Empty: the spectrum's own wind_speed and wind_direction. A
## change crossfades the waves like any other change of the wind.
@export var wind_source_path : NodePath :
	set(value):
		wind_source_path = value
		update_configuration_warnings()
		if _is_running():
			_resolve_wind_source()

@export_group('Water')
## Light absorption of the water per color channel, in 1/m. Pure seawater is
## about (0.30, 0.056, 0.012); dissolved organic matter and algae add to it,
## turning clear blue water greener and darker. Sets the deep-water color and how
## light passing through thin wave crests is tinted.
@export var water_absorption := Vector3(0.45, 0.07, 0.03) :
	set(value):
		water_absorption = value
		_set_water_shader_parameter(&'water_absorption', water_absorption)
## Light scattering by particles (sediment, plankton) per color channel, in
## 1/m. More makes the water brighter and more turbid, and crests glow more.
@export var water_scattering := Vector3(0.03, 0.035, 0.04) :
	set(value):
		water_scattering = value
		_set_water_shader_parameter(&'water_scattering', water_scattering)
## How strongly particles scatter forward (Henyey-Greenstein g; ocean particles
## about 0.9). Higher concentrates the crest glow toward the light.
@export_range(0.0, 0.99, 0.01) var water_scattering_anisotropy := 0.85 :
	set(value):
		water_scattering_anisotropy = value
		_set_water_shader_parameter(&'water_scattering_anisotropy', water_scattering_anisotropy)

@export_group('Surface')
## Roughness (perceptual) of water shorter than the smallest cascade in calm air.
## The wind adds the short waves' slopes on top (short_wave_slope_scale), and the
## shader widens it by the wave slopes a pixel cannot resolve, so distant water gets
## rougher on its own; this only sets how sharp the closest glints and reflections
## of a calm sea are.
@export_range(0.0, 1.0, 0.01) var clear_roughness := 0.03 :
	set(value):
		clear_roughness = value
		_update_micro_roughness()
## Scales the slope variance of the short (capillary and gravity-capillary) waves
## the wind raises, which the cascades do not draw: Cox and Munk's (1954) clean sea
## less their slick sea (whose oil film damps them), 0.00356 U - 0.005 for wind
## U (m/s), none below about 1.4 m/s. 1 is measured; 0 keeps clear_roughness at
## every wind.
@export_range(0.0, 2.0, 0.01, "or_greater") var short_wave_slope_scale := 1.0 :
	set(value):
		short_wave_slope_scale = value
		_update_micro_roughness()
## Multiplies the slopes of every wave in the shading (normals, roughness, caustics),
## the interaction simulation's included. 1 is the physical slope of the waves as
## generated (before WaveSpectrum.displacement_scale); lower is calmer-looking water.
## The mesh and water queries do not change.
@export_range(0.0, 2.0, 0.01) var normal_scale := 1.0 :
	set(value):
		normal_scale = value
		_set_water_shader_parameter(&'normal_scale', normal_scale)

@export_group('Foam')
## Albedo of dense foam (wave, wake and hull edge foam). Foam is a near-neutral
## white scatterer (albedo about 0.8); the lights and sky tint it.
@export_color_no_alpha var foam_color : Color = Color(0.9, 0.92, 0.93) :
	set(value):
		foam_color = value
		_set_water_shader_parameter(&'foam_color', foam_color)
## Multiplies the wave foam coverage the cascades produce (their whitecap,
## foam_generation and foam_lifetime). Raise for more whitecaps; lower for
## cleaner water.
@export_range(0.0, 4.0, 0.01) var foam_intensity := 1.0 :
	set(value):
		foam_intensity = value
		_set_water_shader_parameter(&'foam_intensity', foam_intensity)
## PBR roughness where foam is visible. Foam usually looks best rougher than
## clear water so it does not produce mirror-like highlights.
@export_range(0.0, 1.0, 0.01) var foam_roughness := 0.24 :
	set(value):
		foam_roughness = value
		_set_water_shader_parameter(&'foam_roughness', foam_roughness)
## Pattern that reveals foam coverage as lace and bubbles: foam shows where the
## pattern exceeds 1 - coverage, so its values must be uniformly distributed
## (see textures/generate_foam_detail.py).
@export var foam_detail_texture : Texture2D = preload('res://addons/ocean_system/textures/foam_detail.png') :
	set(value):
		foam_detail_texture = value
		_set_water_shader_parameter(&'foam_detail', foam_detail_texture)
## World size in meters of one tile of foam_detail_texture.
@export_range(0.5, 64.0, 0.1, "or_greater", "suffix:m") var foam_detail_tile_size := 3.0 :
	set(value):
		foam_detail_tile_size = value
		_set_water_shader_parameter(&'foam_detail_tile_size', foam_detail_tile_size)

@export_group('Sky')
## The sky the water reflects and is lit by: a SkySystem, or any node with the sky
## source contract (get_sun_direction(), and optionally get_sun_visibility(),
## clouds, stars, planets and atmosphere; see the README). A source with a
## lighting_changed signal is read only when it fires, others every frame. Empty: the
## manual_* values below.
@export var sky_source_path : NodePath :
	set(value):
		sky_source_path = value
		update_configuration_warnings()
		if _is_running():
			_resolve_sky_source()
			_update_sky_lighting_shader_parameters()
## Overall strength of the water's reflection (sky and planar). It is already
## weighted by Fresnel, so 1 is physical; the engine adds no sky reflection of its own.
@export_range(0.0, 2.0, 0.01) var sky_reflection_strength := 1.0 :
	set(value):
		sky_reflection_strength = value
		_set_water_shader_parameter(&'sky_reflection_strength', sky_reflection_strength)
## Base water reflectance at normal incidence. Real water is near 0.02; artistic
## values above that make reflections visible from more angles.
@export_range(0.0, 0.12, 0.001) var sky_reflection_f0 := 0.02 :
	set(value):
		sky_reflection_f0 = value
		_set_water_shader_parameter(&'sky_reflection_f0', sky_reflection_f0)
## Multiplier on the sun's specular highlight (the sun path). The
## highlight is lit by the scene's lights (color, energy), so 1 is physical.
@export_range(0.0, 4.0, 0.01) var sun_specular_strength := 1.0 :
	set(value):
		sun_specular_strength = value
		_set_water_shader_parameter(&'sun_specular_strength', sun_specular_strength)
@export_subgroup('Manual Sky')
## Zenith colour of the sky the water reflects when the sky source has no atmosphere
## (get_atmosphere_sky_volumes()) or there is none.
@export_color_no_alpha var manual_sky_top_color : Color = Color(0.12, 0.42, 0.78) :
	set(value):
		manual_sky_top_color = value
		_update_sky_lighting_shader_parameters()
## Horizon colour of that sky.
@export_color_no_alpha var manual_sky_horizon_color : Color = Color(0.58, 0.78, 0.94) :
	set(value):
		manual_sky_horizon_color = value
		_update_sky_lighting_shader_parameters()
## Direction toward the sun (world space) without a sky source.
@export var manual_sun_direction := Vector3(0.0, 0.2, -1.0) :
	set(value):
		manual_sun_direction = value
		_update_sky_lighting_shader_parameters()
## Share of the sun reaching the water (0-1) when the sky source has no
## get_sun_visibility() or there is none.
@export_range(0.0, 1.0, 0.01) var manual_sun_visibility := 1.0 :
	set(value):
		manual_sun_visibility = value
		_update_sky_lighting_shader_parameters()

@export_group('Reflections')
## How the water reflects the scene's geometry (see ReflectionMode). Planar
## reflections are created when first used and never render in the editor.
@export var reflection_mode := ReflectionMode.PLANAR :
	set(value):
		reflection_mode = value
		_update_planar_reflection_settings()
@export_subgroup('Planar')
## Maximum side length for the planar reflection texture after resolution_scale
## is applied. Larger values sharpen reflected objects but add render cost.
@export_range(128, 4096, 1, "suffix:px") var reflection_texture_size := 1024 :
	set(value):
		reflection_texture_size = value
		_update_planar_reflection_settings()
## Multiplier applied to the main viewport size when sizing the reflection
## texture. Lower values are faster; higher values reduce blur and aliasing.
@export_range(0.1, 1.0, 0.05) var reflection_resolution_scale := 0.5 :
	set(value):
		reflection_resolution_scale = value
		_update_planar_reflection_settings()
## How much reflected scene geometry covers the sky reflection behind it (1 =
## fully, as in reality). Both share the water's Fresnel reflectance and
## sky_reflection_strength.
@export_range(0.0, 1.0, 0.01) var reflection_strength := 1.0 :
	set(value):
		reflection_strength = value
		_update_planar_reflection_settings()
## Render layer the ocean is put on while planar reflections are active. The
## reflection camera leaves it out so the water does not reflect itself; keep it
## for the water only.
@export_range(1, 20, 1) var reflection_water_layer := 20 :
	set(value):
		reflection_water_layer = value
		_update_planar_reflection_settings()
## Render layers the reflection camera sees. reflection_water_layer is always
## left out.
@export_flags_3d_render var reflection_cull_mask := 0xFFFFF :
	set(value):
		reflection_cull_mask = value
		_update_planar_reflection_settings()
## Clips reflected pixels below the water plane using the reflection viewport's
## depth buffer. This keeps submerged/sinking objects out of planar reflections.
@export var reflection_clip_below_water := true :
	set(value):
		reflection_clip_below_water = value
		_update_planar_reflection_settings()
## Extra distance below the water plane allowed before reflection pixels are
## clipped. Small positive values reduce flicker at waterline intersections.
@export_range(0.0, 1.0, 0.005, "suffix:m") var reflection_clip_bias := 0.03 :
	set(value):
		reflection_clip_bias = value
		_update_planar_reflection_settings()

@export_group('Hull Cutouts')
## Ships (HullWaterFootprint nodes) whose bounds come within this distance of the
## camera get water hidden inside their hull; at most 8, nearest first. Farther
## hulls are not cut out: their interior water is too small to see.
@export_range(0.0, 2000.0, 1.0, "or_greater", "suffix:m") var hull_cutout_distance := 150.0

@export_group('Interaction')
## Runs the iWave interaction simulation on a window around the camera: hulls
## (HullWaterFootprint) push water and radiate wakes and bow waves, and
## WaterSurface.add_impulse() makes splashes. Runtime only; the editor shows the
## FFT ocean alone.
@export var interaction_enabled := true :
	set(value):
		interaction_enabled = value
		_setup_interaction()
## Simulation steps per second. 0 steps once per physics tick (every hull pose
## moves the water). A fixed rate decouples the cost from the physics rate: a game
## ticking at 120 Hz can simulate the water at 60 or 30. Use a divisor of the
## physics rate, so every step sees the same number of new hull poses (each step
## uses the latest ones); stable to ~5 steps a second at the default cell size.
@export_range(0.0, 240.0, 1.0) var interaction_steps_per_second := 0.0
## Simulation grid resolution. The window covers grid size x cell size meters.
@export_enum('256x256:256', '512x512:512', '1024x1024:1024') var interaction_grid_size := 512 :
	set(value):
		interaction_grid_size = value
		_setup_interaction()
## Meters per simulation cell. Smaller cells resolve shorter waves but shrink
## the window; waves shorter than about 4 cells are not represented.
@export_range(0.1, 4.0, 0.05, "or_greater", "suffix:m") var interaction_cell_size := 0.5 :
	set(value):
		interaction_cell_size = value
		_setup_interaction()
## Velocity damping of simulated waves, in 1/s. Higher values make wakes fade sooner.
@export_range(0.0, 5.0, 0.01, "or_greater") var interaction_damping := 0.2 :
	set(value):
		interaction_damping = value
		_apply_interaction_settings()
## Multiplies gravity in the simulation (wave speed scales with its square root).
## 1 is physical deep-water dispersion.
@export_range(0.1, 4.0, 0.01) var interaction_gravity_scale := 1.0 :
	set(value):
		interaction_gravity_scale = value
		_apply_interaction_settings()
## Viscosity of simulated waves, in m^2/s. Damps short waves far more than long
## ones (rate ~ viscosity * k^2), smoothing grid-scale ripples while leaving
## wakes intact. Above ~3 at 60 physics ticks per second the step is unstable.
@export_range(0.0, 1.0, 0.005, "or_greater") var interaction_viscosity := 0.1 :
	set(value):
		interaction_viscosity = value
		_apply_interaction_settings()
## Width, in cells, of the absorbing border at the window edge. Waves fade out
## there instead of wrapping around; rendering fades over the band inside it.
@export_range(4.0, 128.0, 1.0) var interaction_sponge_cells := 24.0 :
	set(value):
		interaction_sponge_cells = value
		_apply_interaction_settings()
## Extra damping at the very edge of the window, in 1/s.
@export_range(0.0, 60.0, 0.1, "or_greater") var interaction_sponge_damping := 12.0 :
	set(value):
		interaction_sponge_damping = value
		_apply_interaction_settings()
## Foam generated per second by steep simulated waves and advancing hulls.
@export_range(0.0, 10.0, 0.01, "or_greater") var interaction_foam_grow := 1.5 :
	set(value):
		interaction_foam_grow = value
		_apply_interaction_settings()
## Exponential decay rate of simulated foam, in 1/s. Lower values leave longer wake trails.
@export_range(0.0, 10.0, 0.01, "or_greater") var interaction_foam_decay := 0.35 :
	set(value):
		interaction_foam_decay = value
		_apply_interaction_settings()
## Wave slope (rise over run) below which simulated waves make no foam.
@export_range(0.0, 2.0, 0.01) var interaction_foam_slope_threshold := 0.15 :
	set(value):
		interaction_foam_slope_threshold = value
		_apply_interaction_settings()
## Bow foam: foam source per meter of bow-wave rise just outside advancing
## hulls (see HullWaterFootprint.bow_wave_strength).
@export_range(0.0, 20.0, 0.01, "or_greater") var interaction_foam_bow_rate := 0.5 :
	set(value):
		interaction_foam_bow_rate = value
		_apply_interaction_settings()

@export_group('Quality')
## Water shader tier. High has every feature; Medium shortens the refraction search,
## the crest light march, the planar reflection search and the normal maps'
## anisotropic filtering; Low shortens them further and compiles out caustics and
## planet glints. Only applies when water_material uses the stock water shader (one
## of WATER_SHADERS).
@export var shader_quality := ShaderQuality.HIGH :
	set(value):
		shader_quality = clampi(value, ShaderQuality.LOW, ShaderQuality.HIGH) as ShaderQuality
		_material = null
		_parameter_cache.clear()
		if _is_running():
			_apply_water_material()
			_push_all_shader_parameters()
## Resolution of each cascade's displacement and normal maps and of its FFT. Cost
## scales roughly with its square; 512 is much cheaper than 1024.
@export_enum('128x128:128', '256x256:256', '512x512:512', '1024x1024:1024') var simulation_map_size := 512 :
	set(value):
		if value not in SIMULATION_MAP_SIZES:
			push_error("OceanSystem.simulation_map_size must be one of %s; keeping %d." % [SIMULATION_MAP_SIZES, simulation_map_size])
			return
		simulation_map_size = value
		update_configuration_warnings()
		_setup_wave_generator()
## How far, as a share of its shortest wavelength, a cascade's waves may travel
## between two FFT updates; frames in between blend the two. Each cascade gets
## its own rate from this (small tiles more often, up to every frame, which needs
## no blend). Blending frames whose waves moved too far washes the ripples out
## and back every update. Lower is smoother and costs more GPU time.
@export_range(0.02, 0.5, 0.01) var max_wave_phase_step := 0.1
## Maximum number of cascades sampled per pixel for foam and normals (the largest
## tiles first). Fewer is cheaper to shade; the mesh is still displaced by all.
@export_range(1, 8, 1) var fragment_cascade_limit := 3 :
	set(value):
		fragment_cascade_limit = clampi(value, 1, MAX_CASCADES)
		_set_water_shader_parameter(&'fragment_cascade_limit', fragment_cascade_limit)
## Bicubic filtering of the normal maps for smoother close-up wave detail. Costs
## extra texture samples per cascade; turn it off for low-end hardware.
@export var use_bicubic_normals := true :
	set(value):
		use_bicubic_normals = value
		_set_water_shader_parameter(&'use_bicubic_normals', use_bicubic_normals)
## Vertex spacing in meters of the finest mesh level, nearest the camera. Every
## level doubles it, about every 3 * 16 * spacing meters of distance. Smaller
## values give smoother near displacement but more vertices.
@export_range(0.25, 16.0, 0.25, "suffix:m") var mesh_base_cell_size := 1.0

@export_group('Material')
## Template for the water material. OceanSystem renders with a private duplicate
## (applied through the RenderingServer, never saved into the scene), so shader
## parameters set by this node never leak into the template or other oceans.
@export var water_material : ShaderMaterial = WATER_MAT :
	set(value):
		if value == null:
			push_error("OceanSystem.water_material cannot be empty; keeping the current material.")
			return
		water_material = value
		_material = null
		_parameter_cache.clear()
		if _is_running():
			_apply_water_material()
			_push_all_shader_parameters()


## Seeds the cascades' spectra.
var _rng := RandomNumberGenerator.new()
## Ocean clock (s), advanced every frame; the waves drawn this frame are at this time.
var _time := 0.0
## The compute pipeline that generates the wave maps (null without cascades, a
## RenderingDevice, or after its GPU resources failed).
var _wave_generator : WaveGenerator
## The simulation state of each cascade, index-aligned with cascades, and the cascades
## they were made for (_update_cascade_states()).
var _cascade_states : Array[WaveCascadeState] = []
var _cascade_state_owners : Array[WaveCascade] = []
## Resolved node of wind_source_path (null without a valid one).
var _wind_source : Node
## Resolved node of sky_source_path (null without one).
var _sky_source : Node
## True when _sky_source has no lighting_changed signal and must be read every frame.
var _sky_source_polled := false
## True while the sky source gives the camera's atmosphere (get_atmosphere_view_volumes()),
## whose observer is read every frame.
var _aerial_perspective_enabled := false
## Instance ids of the bodies that carry a footprint pushing water (_makes_waves()),
## built once per physics tick or frame (_wave_making_bodies_key).
var _wave_making_bodies := {}
var _wave_making_bodies_key := -1
## Last camera exposure sent to the water material (_update_scene_exposure()).
var _scene_exposure := 1.0
## Set by the sky source's lighting_changed signal.
var _sky_lighting_dirty := false

## The generator's maps A and B (see WaveGenerator), bound to the water material.
var _displacement_maps_a := Texture2DArrayRD.new()
var _displacement_maps_b := Texture2DArrayRD.new()
## Normals, slopes and foam, maps A and B.
var _normal_maps_a := Texture2DArrayRD.new()
var _normal_maps_b := Texture2DArrayRD.new()
var _material : ShaderMaterial
## Bound instead of the wave maps while there is no generator (_get_flat_wave_maps()).
var _flat_wave_maps : Texture2DArray
## Last value sent per shader parameter (_set_water_shader_parameter()).
var _parameter_cache := {}
var _surface_queries : OceanSurfaceQueries
## True once every cascade has a frame.
var _has_wave_output := false
## This frame's cascade records for the compute shaders (_pack_cascade_data()),
## shared by the surface queries and the interaction simulation's ticks.
var _cascade_data := PackedByteArray()
var _reflection_renderer : OceanReflectionRenderer
## The CDLOD mesh (runtime only; in the editor it only sends the uniforms) and the
## hull footprints' cutouts and simulation records.
var _lod_grid := OceanLodGrid.new(_set_water_shader_parameter)
var _hulls := OceanHulls.new(_set_water_shader_parameter)
## Null while interaction_enabled is off, in the editor, or before _ready.
var _interaction : WaterInteractionSim
var _interaction_texture := Texture2DRD.new()
## Simulation time not yet stepped (interaction_steps_per_second).
var _interaction_time_due := 0.0


func _init() -> void:
	_rng.set_seed(1234) # This seed gives big waves!

# Registered on enter (before any _ready) so consumers find the surface in their own _ready.
func _enter_tree() -> void:
	if _surface_queries == null and RenderingServer.get_rendering_device() != null:
		_surface_queries = OceanSurfaceQueries.new(RenderingServer.get_rendering_device(), _makes_waves)
	if _surface_queries != null:
		WaterSurface.register(get_world_3d(), _surface_queries)

func _exit_tree() -> void:
	if _surface_queries != null:
		WaterSurface.unregister(get_world_3d(), _surface_queries)

func _ready() -> void:
	process_priority = 100
	if _surface_queries == null:
		push_error("OceanSystem needs a RenderingDevice (Forward+ or Mobile renderer). The ocean is disabled.")
		set_process(false)
		set_physics_process(false)
		return
	_apply_water_material()
	_resolve_wind_source()
	_resolve_sky_source()
	_setup_water_mesh()
	_setup_wave_generator()
	_setup_interaction()
	_push_all_shader_parameters()

func _process(delta : float) -> void:
	var camera := get_viewport().get_camera_3d()
	if not Engine.is_editor_hint():
		_lod_grid.update(camera, global_position, water_level, mesh_base_cell_size, get_path())
	_hulls.update(get_tree(), camera, hull_cutout_distance)
	if _sky_source_polled or _sky_lighting_dirty:
		_update_sky_lighting_shader_parameters()
	if _aerial_perspective_enabled:
		_set_water_shader_parameter(&'aerial_observer', _sky_source.call(&'get_atmosphere_view_observer'))
	_update_scene_exposure()
	_time += delta
	_surface_queries.advance_clock(_time, get_physics_process_delta_time())
	# No generator means no cascades: a flat ocean.
	if _wave_generator != null:
		_update_waves(delta)
		_update_micro_roughness()
		_update_cascade_uniforms()
		_cascade_data = _pack_cascade_data()
	_dispatch_surface_queries()

## The interaction simulation steps with physics: one step per tick sees exactly
## one new pose of every hull, so hull motion reaches it without stutter.
func _physics_process(delta : float) -> void:
	if interaction_steps_per_second <= 0.0:
		_step_interaction(delta)
		return
	# A fixed rate: as many steps as have come due, but never more than two
	# steps' or ticks' worth at once (a hitch is not caught up).
	var step := 1.0 / interaction_steps_per_second
	_interaction_time_due = minf(_interaction_time_due + delta, 2.0 * maxf(step, delta))
	while _interaction_time_due >= step:
		_interaction_time_due -= step
		_step_interaction(step)


## Wind speed (m/s) the waves follow: the wind source's, else the spectrum's.
func get_wind_speed() -> float:
	return WindSource.get_speed(_wind_source) if _wind_source != null else spectrum.wind_speed

## Direction (degrees, 0 = +Z, 90 = +X) the waves' wind blows toward: the wind
## source's, else the spectrum's.
func get_wind_direction_degrees() -> float:
	return WindSource.get_direction(_wind_source) if _wind_source != null else spectrum.wind_direction

## The private duplicate of water_material the ocean renders with (the stock shader swapped
## for the shader_quality tier). Set your own shader parameters on it at runtime (e.g.
## water_debug_view), not on water_material; the ocean owns the ones it sets itself.
func get_water_material() -> ShaderMaterial:
	if _material == null:
		_material = water_material.duplicate()
		# A custom water shader keeps its own code; the stock one gets the chosen tier.
		if _material.shader in WATER_SHADERS:
			_material.shader = WATER_SHADERS[shader_quality]
	return _material


## Whether the ocean runs: it is ready and has a RenderingDevice (else _ready()
## disabled it).
func _is_running() -> bool:
	return is_node_ready() and _surface_queries != null

## Pushes every shader parameter this node owns into the current water material.
func _push_all_shader_parameters() -> void:
	_set_water_shader_parameter(&'water_level', water_level)
	_set_water_shader_parameter(&'water_absorption', water_absorption)
	_set_water_shader_parameter(&'water_scattering', water_scattering)
	_set_water_shader_parameter(&'water_scattering_anisotropy', water_scattering_anisotropy)
	_set_water_shader_parameter(&'normal_scale', normal_scale)
	_update_micro_roughness()
	_set_water_shader_parameter(&'foam_color', foam_color)
	_set_water_shader_parameter(&'foam_intensity', foam_intensity)
	_set_water_shader_parameter(&'foam_roughness', foam_roughness)
	_set_water_shader_parameter(&'foam_detail', foam_detail_texture)
	_set_water_shader_parameter(&'foam_detail_tile_size', foam_detail_tile_size)
	_set_water_shader_parameter(&'sky_reflection_strength', sky_reflection_strength)
	_set_water_shader_parameter(&'sky_reflection_f0', sky_reflection_f0)
	_set_water_shader_parameter(&'sun_specular_strength', sun_specular_strength)
	_set_water_shader_parameter(&'fragment_cascade_limit', fragment_cascade_limit)
	_set_water_shader_parameter(&'use_bicubic_normals', use_bicubic_normals)
	_set_water_shader_parameter(&'scene_exposure', _scene_exposure)
	_update_sky_lighting_shader_parameters()
	_lod_grid.set_cell_size(mesh_base_cell_size, true)
	_bind_wave_textures()
	_update_cascade_uniforms()
	_hulls.reset()
	_hulls.update(get_tree(), get_viewport().get_camera_3d(), hull_cutout_distance)
	_update_planar_reflection_settings()
	_push_interaction_shader_parameters()


## Keeps one simulation state per cascade. A cascade resource that stays in the list
## keeps its state (seed, clock, spectra), so editing the list leaves the other
## cascades' waves as they are.
func _update_cascade_states() -> void:
	var states : Array[WaveCascadeState] = []
	for i in cascades.size():
		var previous := _cascade_state_owners.find(cascades[i])
		var state : WaveCascadeState = _cascade_states[previous] if previous >= 0 else null
		# A cascade listed twice gets a state of its own the second time.
		if state == null or states.has(state):
			# Offset cascade start times so layered waves are less likely to align.
			state = WaveCascadeState.new(Vector2i(_rng.randi_range(-10000, 10000), _rng.randi_range(-10000, 10000)), 120.0 + PI * i)
		states.push_back(state)
	_cascade_states = states
	_cascade_state_owners = cascades.duplicate()

## A cascade's tile_length changed (or the list did): the bands and uniforms follow.
func _on_cascade_changed() -> void:
	_update_spectrum_bands()
	_update_cascade_uniforms()
	update_configuration_warnings() # Tile lengths decide the spectrum bands.

## (Re)builds the wave generator for the cascades and simulation_map_size. Without
## cascades, or if its GPU resources fail, the ocean is flat.
func _setup_wave_generator() -> void:
	if not _is_running():
		return
	_surface_queries.clear_uniform_set_cache()
	if _interaction != null:
		_interaction.clear_uniform_set_cache()
	_has_wave_output = false
	for state in _cascade_states:
		state.regenerate()
		state.frame_count = 0
	_update_spectrum_bands() # They depend on simulation_map_size.
	# The previous generator is freed when this returns, after its maps are unbound.
	var _previous_generator := _wave_generator
	_wave_generator = null
	if not cascades.is_empty():
		var generator := WaveGenerator.new()
		generator.init_gpu(simulation_map_size, cascades.size())
		if generator.context.failed:
			push_error("OceanSystem %s: the wave generator's GPU resources failed; the ocean is flat." % get_path())
		else:
			_wave_generator = generator
	var descriptors := _wave_generator.descriptors if _wave_generator != null else {}
	_set_texture_rid(_displacement_maps_a, descriptors[&'displacement_map_a'].rid if _wave_generator != null else RID())
	_set_texture_rid(_displacement_maps_b, descriptors[&'displacement_map_b'].rid if _wave_generator != null else RID())
	_set_texture_rid(_normal_maps_a, descriptors[&'normal_map_a'].rid if _wave_generator != null else RID())
	_set_texture_rid(_normal_maps_b, descriptors[&'normal_map_b'].rid if _wave_generator != null else RID())
	_bind_wave_textures()
	_update_cascade_uniforms()

func _bind_wave_textures() -> void:
	_set_water_shader_parameter(&'num_cascades', cascades.size() if _wave_generator != null else 0)
	# Without a generator the material samples a flat placeholder array (an empty
	# Texture2DArrayRD falls back to a 2D texture, which the shader's arrays reject).
	var maps : Array[TextureLayered] = [_displacement_maps_a, _displacement_maps_b, _normal_maps_a, _normal_maps_b]
	if _wave_generator == null:
		maps.fill(_get_flat_wave_maps())
	# Forced: the textures may hold new RenderingServer RIDs (_set_texture_rid()).
	_set_water_shader_parameter(&'displacements_a', maps[0], true)
	_set_water_shader_parameter(&'displacements_b', maps[1], true)
	_set_water_shader_parameter(&'normals_a', maps[2], true)
	_set_water_shader_parameter(&'normals_b', maps[3], true)

## A 1x1, one-layer texture array of zeros: flat water, no slopes, no foam.
func _get_flat_wave_maps() -> Texture2DArray:
	if _flat_wave_maps == null:
		var image := Image.create_empty(1, 1, false, Image.FORMAT_RGBAH)
		_flat_wave_maps = Texture2DArray.new()
		_flat_wave_maps.create_from_images([image])
	return _flat_wave_maps

## Points texture at the generator texture rid (or none). Cleared first, so it gets a
## new RenderingServer texture: bind it again (forced) afterwards.
func _set_texture_rid(texture: Texture2DArrayRD, rid: RID) -> void:
	texture.texture_rd_rid = RID()
	texture.texture_rd_rid = rid

## The per-cascade uniforms: tile scales and displacement_scale, the spectrum crossfade
## and the A/B frame blend. Sent every frame; unchanged values are skipped.
func _update_cascade_uniforms() -> void:
	var map_scales := PackedVector4Array()
	var blend_states := PackedVector4Array()
	var frame_blends := PackedVector4Array()
	for i in cascades.size():
		var uv_scale := 1.0 / cascades[i].tile_length
		map_scales.push_back(Vector4(uv_scale, uv_scale, spectrum.displacement_scale, 0.0))
		blend_states.push_back(_cascade_states[i].get_blend_state(i))
		frame_blends.push_back(_get_cascade_frame_blend(i))
	_set_water_shader_parameter(&'map_scales', map_scales)
	_set_water_shader_parameter(&'spectrum_blend_states', blend_states)
	_set_water_shader_parameter(&'wave_frame_blends', frame_blends)

## Cascade records for the compute shaders, OceanSurfaceQueries.BYTES_PER_CASCADE each
## (OceanCascade in ocean_sampling.glslinc): the uniforms of _update_cascade_uniforms().
func _pack_cascade_data() -> PackedByteArray:
	var floats := PackedFloat32Array()
	floats.resize(MAX_CASCADES * OceanSurfaceQueries.FLOATS_PER_CASCADE)
	for i in cascades.size():
		var uv_scale := 1.0 / cascades[i].tile_length
		var blend_state := _cascade_states[i].get_blend_state(i)
		var frame_blend := _get_cascade_frame_blend(i)
		var values := [uv_scale, uv_scale, spectrum.displacement_scale, 0.0,
			blend_state.x, blend_state.y, blend_state.z, blend_state.w,
			frame_blend.x, frame_blend.y, frame_blend.z, frame_blend.w]
		var offset := i * OceanSurfaceQueries.FLOATS_PER_CASCADE
		for j in values.size():
			floats[offset + j] = values[j]
	return floats.to_byte_array()

## The water's micro-roughness for the shader's clear_roughness: GGX alpha squared
## is the slope variance (both axes) of what the cascades do not draw, the calm
## clear_roughness plus the wind's short waves (short_wave_slope_scale).
func _update_micro_roughness() -> void:
	var short_wave_variance := maxf(0.00356 * get_wind_speed() - 0.005, 0.0) * short_wave_slope_scale
	var alpha := sqrt(pow(clear_roughness, 4.0) + short_wave_variance)
	_set_water_shader_parameter(&'clear_roughness', sqrt(alpha))

## Updates every cascade whose newest frame the display has reached. A cascade
## computes its next frame one update interval ahead of now, so blending from
## its newest frame to that one shows the waves at the current time.
func _update_waves(frame_delta : float) -> void:
	var wind_speed := get_wind_speed()
	var wind_direction := get_wind_direction_degrees()
	var all_have_frames := true
	for i in cascades.size():
		var state := _cascade_states[i]
		if state.frame_count == 0 or _time >= state.frame_time:
			var interval := _get_cascade_update_interval(cascades[i], state)
			if interval <= frame_delta:
				interval = 0.0 # Every frame: shown as computed, no blend.
			var frame_time := _time + interval
			state.advance(frame_time - state.frame_time if state.frame_count > 0 else 0.0, cascades[i], spectrum, wind_speed, wind_direction)
			_wave_generator.update_cascade(i, cascades[i], state, spectrum.displacement_scale)
			state.previous_frame_time = state.frame_time
			state.frame_time = frame_time
			state.frame_count += 1
		all_have_frames = all_have_frames and state.frame_count > 0
	_has_wave_output = all_have_frames

## Seconds between a cascade's FFT updates: its shortest wave (two texels, or its
## band's end) may travel max_wave_phase_step of its length, at deep-water phase
## speed sqrt(g lambda / 2 pi).
func _get_cascade_update_interval(cascade : WaveCascade, state : WaveCascadeState) -> float:
	var shortest_wavelength := maxf(2.0 * cascade.tile_length / simulation_map_size, TAU / state.wavenumber_band.y)
	return max_wave_phase_step * sqrt(TAU * shortest_wavelength / WaveGenerator.G)

## Per cascade: x = weight of map B (A gets the rest) at the current time, y =
## factor (1/s) turning B - A into a velocity. The water shader, surface queries
## and the interaction simulation all blend with it.
func _get_cascade_frame_blend(cascade_index : int) -> Vector4:
	var state := _cascade_states[cascade_index]
	if _wave_generator == null or state.frame_count == 0:
		return Vector4.ZERO
	var newest_weight := 1.0
	var rate := 0.0
	var span := state.frame_time - state.previous_frame_time
	# A first frame has nothing to blend from; neither has a paused clock.
	if state.frame_count > 1 and span > 0.0:
		newest_weight = clampf((_time - state.previous_frame_time) / span, 0.0, 1.0)
		rate = 1.0 / span
	if _wave_generator.cascade_newest_output[cascade_index] == 1:
		return Vector4(newest_weight, rate, 0.0, 0.0)
	return Vector4(1.0 - newest_weight, -rate, 0.0, 0.0)

## Splits the spectrum between the cascades by tile length, so each wavelength is drawn
## by one cascade only: from the largest tile down, each cascade draws the waves longer
## than the boundary to the next smaller one (_get_band_boundary_wavelength()), the
## smallest everything shorter. A cascade whose band changed regenerates its spectrum.
## Runs when tile lengths, the cascade list or simulation_map_size change.
func _update_spectrum_bands() -> void:
	var order := _get_cascades_by_tile_size()
	var band_start := 0.0
	for n in order.size():
		var state := _cascade_states[order[n]]
		var band_end := WaveCascadeState.UNBOUNDED_WAVENUMBER
		if n + 1 < order.size():
			band_end = TAU / _get_band_boundary_wavelength(cascades[order[n]], cascades[order[n + 1]])
		var band := Vector2(band_start, band_end)
		if band != state.wavenumber_band:
			state.wavenumber_band = band
			state.regenerate()
		band_start = band_end

## Cascade indices from the largest tile to the smallest (ties in array order).
func _get_cascades_by_tile_size() -> Array[int]:
	var order : Array[int] = []
	for i in cascades.size():
		order.push_back(i)
	order.sort_custom(func(a : int, b : int) -> bool:
		var size_a := cascades[a].tile_length
		var size_b := cascades[b].tile_length
		return size_a > size_b or (size_a == size_b and a < b))
	return order

## Shortest wavelength (m) cascade draws well: CASCADE_BAND_MIN_TEXELS of its texels.
func _get_shortest_resolved_wavelength(cascade : WaveCascade) -> float:
	return CASCADE_BAND_MIN_TEXELS * cascade.tile_length / simulation_map_size

## Wavelength (m) where the band of larger hands over to that of smaller: smaller's
## tile / CASCADE_BAND_WAVES_PER_TILE, but no shorter than larger resolves and no
## longer than smaller's tile.
func _get_band_boundary_wavelength(larger : WaveCascade, smaller : WaveCascade) -> float:
	return minf(maxf(smaller.tile_length / CASCADE_BAND_WAVES_PER_TILE, _get_shortest_resolved_wavelength(larger)), smaller.tile_length)

func _apply_water_material() -> void:
	RenderingServer.instance_geometry_set_material_override(get_instance(), get_water_material().get_rid())

func _setup_interaction() -> void:
	if not _is_running():
		return
	if _interaction != null:
		_interaction_texture.texture_rd_rid = RID()
		_interaction.release()
		_interaction = null
		_surface_queries.interaction = null
		# Query uniform sets that referenced the old render texture are freed with it.
		_surface_queries.clear_uniform_set_cache()
	# The simulation follows the game camera and does not run in the editor.
	if interaction_enabled and not Engine.is_editor_hint():
		if interaction_grid_size not in [256, 512, 1024] or interaction_cell_size <= 0.0:
			push_error("OceanSystem %s: interaction_grid_size must be 256, 512 or 1024 and interaction_cell_size positive; the interaction simulation is off." % get_path())
		else:
			_interaction = WaterInteractionSim.new(RenderingServer.get_rendering_device(), interaction_grid_size, interaction_cell_size)
			if _interaction.has_failed():
				push_error("OceanSystem %s: the interaction simulation's GPU resources failed; it is off." % get_path())
				_interaction.release()
				_interaction = null
	if _interaction != null:
		_apply_interaction_settings()
		_interaction_texture.texture_rd_rid = _interaction.render_texture
		_surface_queries.interaction = _interaction
	_push_interaction_shader_parameters()

func _apply_interaction_settings() -> void:
	# Tunables are copied into the simulation when it exists (see _setup_interaction).
	if _interaction == null:
		return
	_interaction.damping = interaction_damping
	_interaction.viscosity = interaction_viscosity
	_interaction.gravity_scale = interaction_gravity_scale
	_interaction.sponge_cells = interaction_sponge_cells
	_interaction.sponge_damping = interaction_sponge_damping
	_interaction.foam_grow = interaction_foam_grow
	_interaction.foam_decay = interaction_foam_decay
	_interaction.foam_slope_threshold = interaction_foam_slope_threshold
	_interaction.foam_bow_rate = interaction_foam_bow_rate
	_set_water_shader_parameter(&'interaction_window', _get_interaction_window())

func _push_interaction_shader_parameters() -> void:
	_set_water_shader_parameter(&'interaction_enabled', _interaction != null)
	# Forced: the texture's RID changes when the simulation is rebuilt.
	_set_water_shader_parameter(&'interaction_render', _interaction_texture, true)
	_set_water_shader_parameter(&'interaction_cell_size', interaction_cell_size)
	_set_water_shader_parameter(&'interaction_inv_extent', 1.0 / (float(interaction_grid_size) * interaction_cell_size))
	_set_water_shader_parameter(&'interaction_window', _get_interaction_window())

## (window center x, center z, fade start, fade end): rendering and queries fade
## the simulation out by Chebyshev distance from the center, ending where the
## absorbing border begins.
func _get_interaction_window() -> Vector4:
	if _interaction == null:
		return Vector4.ZERO
	var center := _interaction.get_window_center()
	var half_extent := _interaction.get_half_extent()
	var sponge_width := interaction_sponge_cells * interaction_cell_size
	return Vector4(center.x, center.y, half_extent - 2.0 * sponge_width, half_extent - sponge_width)

func _step_interaction(delta : float) -> void:
	# Disabled, or nothing to sample the incident waves from before the first FFT output.
	if _interaction == null or not _has_wave_output:
		return
	var camera := get_viewport().get_camera_3d()
	# The window follows the active camera; without one there is nothing to center on.
	if camera == null:
		return
	var hull_data := _hulls.pack_interaction_hulls(get_tree(), camera.global_position, _interaction.get_half_extent() * sqrt(2.0))
	var hull_profiles_rd := RenderingServer.texture_get_rd_texture(_hulls.profiles_texture.get_rid()) if _hulls.profiles_texture != null else RID()
	@warning_ignore("integer_division")
	_interaction.step(
		delta,
		camera.global_position,
		hull_data,
		hull_data.size() / WaterInteractionSim.FLOATS_PER_HULL,
		_cascade_data,
		cascades.size(),
		water_level,
		_wave_generator.descriptors[&'displacement_map_a'].rid,
		_wave_generator.descriptors[&'displacement_map_b'].rid,
		hull_profiles_rd
	)
	_set_water_shader_parameter(&'interaction_window', _get_interaction_window())

## Whether body carries a footprint that pushes water. Every query owner asks every
## tick, so the bodies are collected once per physics tick (or frame, outside physics).
func _makes_waves(body : PhysicsBody3D) -> bool:
	if body == null or _interaction == null:
		return false
	var key := Engine.get_physics_frames() if Engine.is_in_physics_frame() else -1 - Engine.get_process_frames()
	if key != _wave_making_bodies_key:
		_wave_making_bodies_key = key
		_wave_making_bodies.clear()
		for node in get_tree().get_nodes_in_group(&"ocean_hull"):
			var footprint := node as HullWaterFootprint
			var footprint_body := OceanSurfaceQueries.find_physics_body(footprint)
			if OceanHulls.pushes_water(footprint) and footprint_body != null:
				_wave_making_bodies[footprint_body.get_instance_id()] = true
	return _wave_making_bodies.has(body.get_instance_id())

## The sky source's lighting and its optional extras (clouds, stars, planets,
## atmosphere), each falling back to the manual values or to none.
func _update_sky_lighting_shader_parameters() -> void:
	_sky_lighting_dirty = false
	var sun_direction : Vector3 = _read_sky(&'get_sun_direction', manual_sun_direction)
	if sun_direction.length_squared() <= 0.0001:
		push_error("OceanSystem %s: the sun direction is zero; using straight up." % get_path())
		sun_direction = Vector3.UP
	_set_water_shader_parameter(&'sky_sun_direction', sun_direction.normalized())
	_set_water_shader_parameter(&'sky_sun_visibility', float(_read_sky(&'get_sun_visibility', manual_sun_visibility)))
	# The sky reflected without an atmosphere.
	_set_water_shader_parameter(&'sky_top_color', manual_sky_top_color)
	_set_water_shader_parameter(&'sky_horizon_color', manual_sky_horizon_color)
	_set_water_shader_parameter(&'sky_ground_horizon_color', manual_sky_horizon_color.darkened(0.25))
	_set_water_shader_parameter(&'sky_ground_bottom_color', manual_sky_top_color.darkened(0.55))
	var cloud_cubemap : Texture = _read_sky(&'get_cloud_cubemap', null)
	_set_water_shader_parameter(&'sky_clouds_enabled', cloud_cubemap != null)
	_set_water_shader_parameter(&'sky_cloud_cubemap', cloud_cubemap)
	# Stars: a cubemap, the rotation into its frame (it turns with the sky) and the
	# scale of its values to scene radiance.
	var star_cubemap : Texture = _read_sky(&'get_star_cubemap', null)
	_set_water_shader_parameter(&'sky_stars_enabled', star_cubemap != null)
	_set_water_shader_parameter(&'sky_star_cubemap', star_cubemap)
	if star_cubemap != null:
		_set_water_shader_parameter(&'sky_star_basis', _read_sky(&'get_star_basis', Basis.IDENTITY))
		_set_water_shader_parameter(&'sky_star_radiance_scale', _read_sky(&'get_star_radiance_scale', 0.0))
	# Point lights (the planets), reflected as glints; at most MAX_SKY_POINTS.
	var point_directions : PackedVector3Array = _read_sky(&'get_planet_directions', PackedVector3Array())
	var point_irradiance : PackedVector3Array = _read_sky(&'get_planet_irradiance', PackedVector3Array())
	if point_directions.size() != point_irradiance.size():
		push_error("OceanSystem %s: the sky source's planet directions and irradiance differ in length; no planet glints." % get_path())
		point_directions.clear()
	var point_count := mini(point_directions.size(), MAX_SKY_POINTS)
	_set_water_shader_parameter(&'sky_point_count', point_count)
	if point_count > 0:
		_set_water_shader_parameter(&'sky_point_directions', point_directions.slice(0, point_count))
		_set_water_shader_parameter(&'sky_point_irradiance', point_irradiance.slice(0, point_count))
	# The atmosphere between the sea and the reflected sky; a source without one lacks
	# the method or returns no volumes.
	var volumes : Array = _read_sky(&'get_atmosphere_sky_volumes', [])
	_set_water_shader_parameter(&'sky_atmosphere_enabled', not volumes.is_empty())
	_set_water_shader_parameter(&'sky_atmosphere_transmittance', volumes[0] if not volumes.is_empty() else null)
	_set_water_shader_parameter(&'sky_atmosphere_inscatter', volumes[1] if not volumes.is_empty() else null)
	_set_water_shader_parameter(&'sky_atmosphere_inscatter_lobe', volumes[2] if not volumes.is_empty() else null)
	if not volumes.is_empty():
		_set_water_shader_parameter(&'sky_atmosphere_light', _read_sky(&'get_atmosphere_light', Vector4(0.0, 1.0, 0.0, 0.0)))
	# The atmosphere between the camera and the water. The water is transparent,
	# drawn after the sky's aerial perspective, so it hazes itself (FOG).
	var view_volumes : Array = _read_sky(&'get_atmosphere_view_volumes', [])
	_aerial_perspective_enabled = not view_volumes.is_empty()
	_set_water_shader_parameter(&'aerial_perspective_enabled', _aerial_perspective_enabled)
	_set_water_shader_parameter(&'aerial_transmittance', view_volumes[0] if _aerial_perspective_enabled else null)
	_set_water_shader_parameter(&'aerial_inscatter', view_volumes[1] if _aerial_perspective_enabled else null)
	_set_water_shader_parameter(&'aerial_inscatter_lobe', view_volumes[2] if _aerial_perspective_enabled else null)
	if _aerial_perspective_enabled:
		_set_water_shader_parameter(&'aerial_max_distance', _sky_source.call(&'get_atmosphere_view_max_distance'))
		_set_water_shader_parameter(&'aerial_observer', _sky_source.call(&'get_atmosphere_view_observer'))

## What the sky source's method returns, or fallback without a source or that method.
func _read_sky(method : StringName, fallback : Variant) -> Variant:
	if _sky_source != null and _sky_source.has_method(method):
		return _sky_source.call(method)
	return fallback

## The spectrum's own wind is used while there is no valid source.
func _resolve_wind_source() -> void:
	_wind_source = null
	if wind_source_path.is_empty():
		return
	var node := get_node_or_null(wind_source_path)
	if WindSource.is_valid(node):
		_wind_source = node
	else:
		push_error("OceanSystem %s: wind_source_path %s is not a wind source (get_wind_speed() and get_wind_direction_degrees(), or wind_speed and wind_direction); the waves follow the spectrum's own wind." % [get_path(), wind_source_path])

func _resolve_sky_source() -> void:
	# A freed source was disconnected by the engine.
	if is_instance_valid(_sky_source) and _sky_source.has_signal(&'lighting_changed') and _sky_source.is_connected(&'lighting_changed', _on_sky_lighting_changed):
		_sky_source.disconnect(&'lighting_changed', _on_sky_lighting_changed)
	_sky_source = null if sky_source_path.is_empty() else get_node_or_null(sky_source_path)
	if _sky_source == null and not sky_source_path.is_empty():
		push_error("OceanSystem %s: sky_source_path %s not found; using the manual sky values." % [get_path(), sky_source_path])
	var signals_changes := _sky_source != null and _sky_source.has_signal(&'lighting_changed')
	_sky_source_polled = _sky_source != null and not signals_changes
	if signals_changes:
		_sky_source.connect(&'lighting_changed', _on_sky_lighting_changed)

func _on_sky_lighting_changed() -> void:
	_sky_lighting_dirty = true

func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if ProjectSettings.get_setting("rendering/renderer/rendering_method") == "gl_compatibility":
		warnings.push_back("The ocean needs the Forward+ or Mobile renderer (compute shaders); with Compatibility there is no water.")
	if cascades.is_empty():
		warnings.push_back("No wave cascades: the sea is flat.")
	var order := _get_cascades_by_tile_size()
	for n in range(order.size() - 1):
		var larger := cascades[order[n]]
		var smaller := cascades[order[n + 1]]
		if _get_shortest_resolved_wavelength(larger) > smaller.tile_length:
			warnings.push_back("Wave cascades %d and %d: tile lengths %s and %s m are too far apart for simulation_map_size %d, so waves between them are missing. Use tiles at most %d times apart, or a larger map." % [order[n], order[n + 1], larger.tile_length, smaller.tile_length, simulation_map_size, int(simulation_map_size / CASCADE_BAND_MIN_TEXELS)])
	if not global_basis.is_equal_approx(Basis.IDENTITY) or not is_zero_approx(global_position.y):
		warnings.push_back("The ocean ignores its own transform: it is drawn level at water_level, and its waves, queries and reflections assume an unrotated, unscaled node. Keep it (and its parents) at height 0 without rotation or scale, and set water_level instead (OceanEnvironment.sea_level in the drop-in environment).")
	if not sky_source_path.is_empty():
		var sky := get_node_or_null(sky_source_path)
		if sky == null:
			warnings.push_back("sky_source_path does not point to a node; the manual sky values are used.")
		elif sky.get(&'sea_level') != null and not is_equal_approx(float(sky.get(&'sea_level')), water_level):
			warnings.push_back("The sky's sea_level (%s) differs from water_level (%s): its horizon and haze sit at the wrong height. Set both to the same value (OceanEnvironment.sea_level does)." % [sky.get(&'sea_level'), water_level])
	if not wind_source_path.is_empty() and not WindSource.is_valid(get_node_or_null(wind_source_path)):
		warnings.push_back("wind_source_path does not point to a wind source (e.g. a WindSystem); the waves follow the spectrum's own wind.")
	# Cameras of the edited scene: the sea is drawn out to the horizon, but no farther
	# than a camera's far plane.
	var scene_root := get_tree().edited_scene_root if Engine.is_editor_hint() and is_inside_tree() else null
	if scene_root != null:
		for camera : Camera3D in scene_root.find_children("*", "Camera3D", true, false):
			var horizon := sqrt(2.0 * EARTH_RADIUS * maxf(camera.global_position.y - water_level, 2.0))
			if camera.far < horizon:
				warnings.push_back("Camera %s: far (%d m) ends before the horizon (%d m at its height), so the sea stops short of it. Raise far (the demo uses 60000 m)." % [scene_root.get_path_to(camera), camera.far, horizon])
	return warnings

## The editor shows the shared preview plane. At runtime the ocean is a CDLOD
## quadtree of grid nodes (OceanLodGrid) drawn as one multimesh, set directly as this
## instance's base through the RenderingServer, so no generated mesh is ever saved.
func _setup_water_mesh() -> void:
	if Engine.is_editor_hint():
		mesh = EDITOR_WATER_PREVIEW_MESH
		extra_cull_margin = maxf(256.0, EDITOR_WATER_PREVIEW_MESH.size.length() * 0.5)
		return
	_lod_grid.attach(get_instance())

func _update_planar_reflection_settings() -> void:
	if not _is_running():
		return
	_set_water_shader_parameter(&'screen_space_reflections_enabled', reflection_mode == ReflectionMode.SCREEN_SPACE)
	var planar := reflection_mode == ReflectionMode.PLANAR
	# Planar reflections never render in the editor, and the renderer is only created once enabled.
	if Engine.is_editor_hint() or (_reflection_renderer == null and not planar):
		_set_water_shader_parameter(&'planar_reflection_enabled', false)
		_set_water_shader_parameter(&'planar_reflection_strength', 0.0)
		return
	if _reflection_renderer == null:
		_reflection_renderer = OceanReflectionRenderer.new(_set_water_shader_parameter)
		_reflection_renderer.name = "OceanReflectionRenderer"
		add_child(_reflection_renderer, false, INTERNAL_MODE_FRONT)
	_reflection_renderer.enabled = planar
	_reflection_renderer.texture_size = reflection_texture_size
	_reflection_renderer.resolution_scale = reflection_resolution_scale
	_reflection_renderer.reflection_strength = reflection_strength
	_reflection_renderer.water_layer = reflection_water_layer
	_reflection_renderer.reflection_cull_mask = reflection_cull_mask
	_reflection_renderer.clip_below_water = reflection_clip_below_water
	_reflection_renderer.clip_bias = reflection_clip_bias
	_reflection_renderer.apply(self, water_level)

## The water sums its reflections pre-exposed (the sky source's textures and the planar
## reflection are stored that way) and divides EMISSION by the camera's exposure.
func _update_scene_exposure() -> void:
	var camera := get_viewport().get_camera_3d()
	var attributes : CameraAttributes = camera.attributes if camera and camera.attributes else get_world_3d().camera_attributes
	var exposure := attributes.exposure_multiplier if attributes else 1.0
	if exposure != _scene_exposure:
		_scene_exposure = exposure
		_set_water_shader_parameter(&'scene_exposure', exposure)

## Sends value unless it equals the last value sent (many parameters are pushed
## every frame but rarely change). force re-sends it, e.g. a texture whose
## RenderingServer RID changed.
func _set_water_shader_parameter(parameter: StringName, value: Variant, force := false) -> void:
	if not force and _parameter_cache.has(parameter):
		var previous : Variant = _parameter_cache[parameter]
		if typeof(previous) == typeof(value) and previous == value:
			return
	# Arrays are copied: a caller may edit its array in place and send it again.
	_parameter_cache[parameter] = value.duplicate() if value is Array or typeof(value) >= TYPE_PACKED_BYTE_ARRAY else value
	get_water_material().set_shader_parameter(parameter, value)

func _dispatch_surface_queries() -> void:
	# Nothing to sample until the first FFT output exists (or ever, with no cascades).
	if not _has_wave_output:
		return
	_surface_queries.dispatch(
		_wave_generator.descriptors[&'displacement_map_a'].rid,
		_wave_generator.descriptors[&'displacement_map_b'].rid,
		_cascade_data,
		cascades.size(),
		water_level,
		_get_interaction_window(),
		interaction_cell_size
	)

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		# Unbound before the generator frees the textures behind them.
		_displacement_maps_a.texture_rd_rid = RID()
		_displacement_maps_b.texture_rd_rid = RID()
		_normal_maps_a.texture_rd_rid = RID()
		_normal_maps_b.texture_rd_rid = RID()
		_wave_generator = null
		# Null when interaction is off, in the editor, or the ocean was disabled.
		if _interaction != null:
			_interaction_texture.texture_rd_rid = RID()
			_interaction.release()
		# Null when the ocean was disabled for lack of a RenderingDevice.
		if _surface_queries != null:
			_surface_queries.retire()
		# The multimesh exists at runtime only.
		_lod_grid.release()
