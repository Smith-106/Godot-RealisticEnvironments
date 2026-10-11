# Ocean System

FFT-simulated ocean for Godot 4 Forward+: compute-shader waves rendered on a
CDLOD mesh out to the horizon, with wakes, hull cutouts and GPU water-height
queries for gameplay.

Requires the `core` addon.

## Features

- **Waves:** up to 8 FFT cascades of a JONSWAP spectrum, from swell to chop.
  They follow the wind and crossfade smoothly when it changes.
- **Sea to the horizon:** drawn on the earth's curve; distant waves are
  filtered by mips instead of fading.
- **Foam:** whitecaps on sharp crests, plus wake, bow and hull-edge foam.
- **Wakes and splashes:** an iWave simulation around the camera; hulls make
  Kelvin wakes and bow waves.
- **Hull cutouts:** no water inside up to 8 nearby ships.
- **Water optics:** colour from absorption and scattering, glowing crests,
  refraction, shallow-water transparency and caustics.
- **Reflections:** sky, clouds, stars, planets and the scene (screen-space or
  planar), with a rough-surface Fresnel and sun glitter.
- **Quality tiers:** Low / Medium / High shaders and 15 debug views.

## Quick start

1. Instance `ocean_system.tscn` (an `OceanSystem`, a `MeshInstance3D`).
2. Optional: set `sky_source_path` to a `SkySystem` so reflections follow the
   time of day.
3. Optional: enable `use_external_wind` and set `wind_source_path` to a
   `WindSystem` (or any node with the wind contract).
4. Run with an active `Camera3D` whose far plane reaches past the horizon
   (the demo uses 60 km).

Don't rotate or scale the ocean node; only its height matters. Without a
`RenderingDevice` (Compatibility renderer, headless) the ocean reports an
error and disables itself.

## Main settings

| Group | What it controls |
| --- | --- |
| `parameters` | The wave cascades (`WaveCascadeParameters`, at most 8). |
| Wave Parameters / Surface / Foam Shading | Optical properties (`water_absorption`, `water_scattering`, `water_scattering_anisotropy`), foam, roughness. |
| Sky Reflection | Sky source and `manual_*` fallbacks, sun highlight and glitter. |
| Reflections | `reflection_mode`: Sky Only, Screen Space or Planar. |
| External Wind | `use_external_wind`, `wind_source_path`. |
| Performance | `shader_quality`, `simulation_map_size` (128–1024), `max_wave_phase_step`. |
| Mesh | `mesh_base_cell_size`. |
| Interaction | Wake simulation grid, damping and foam. |

**Wave cascades.** Each `WaveCascadeParameters` is one FFT tile repeating every
`tile_length` metres: long tiles for swell, short for chop. Per cascade you set
`displacement_scale` (1 = physical wave height), `normal_scale`, local or
external-relative wind, spectrum shape (`fetch_length`, `water_depth_meters`,
`swell`, `spread`, `detail`) and foam (`whitecap`, `foam_generation`,
`foam_lifetime`). Retune `whitecap` when you change `displacement_scale`.

**Debug views.** Set the shader uniform `water_debug_view` (1–15) on the
material at runtime to show single shading terms.

## Water queries and splashes

Use the `WaterSurface` contract from `core` (see its README), never
`OceanSystem` directly:

```gdscript
var water := WaterSurface.find(self)
water.submit_query(self, points)            # every physics tick
var result := water.get_query_result(self)  # null until the first readback
if result != null:
	var h := result.samples[0].extrapolated_height(water.get_query_age(result))
water.add_impulse(position, radius, amplitude)  # splash
```

Results are asynchronous and arrive a few frames late; always extrapolate with
`get_query_age()`. A result's `points` belong to its dispatch, so check its size
if your point count changes. Bodies that make their own wake read only the FFT
waves; other floating objects also ride wakes and splashes.

## Ships: cutouts and wakes

1. Add a `HullWaterFootprint` rigidly to the ship (the boat template has one).
2. Set `bake_source_paths` to the hull meshes only (no masts or rigging).
3. Save the scene, press **Bake Profile**, save again.

The baked `HullProfile` hides water inside the hull and makes the hull push
water in the wake simulation. Tune it in the footprint's **Wake** group
(`wake_enabled`, `wake_strength`, `wake_edge_softness`, `bow_wave_strength`).
Raise `cutout_height_offset` if waves cresting a low gunwale show inside the
boat. Only the 8 nearest hulls get cutouts and the 32 nearest make wakes; the
wake simulation runs only at runtime.

## Future work

- **Underwater view:** a camera below the surface (the surface's underside,
  Snell's window, underwater fog and god rays).
- **Shores and shallow water:** a bathymetry map instead of one
  `water_depth_meters` per cascade, giving wave shoaling, refraction and
  breaking along coasts, with shore foam.
- **Currents:** a current field that Doppler-shifts the waves and carries
  floating bodies and foam.
- **Spray and rain:** mist blown off breaking whitecaps; raindrop rings and
  roughness on the surface under rain presets.
- **Persistent wakes:** foam trails that outlive the interaction window around
  the camera, and wakes for ships outside it.
- **Fallback renderer:** a simpler (e.g. Gerstner) ocean for the
  Compatibility renderer, which has no `RenderingDevice`.

## Files

| File | Role |
| --- | --- |
| `ocean_system.gd` / `.tscn` | `OceanSystem` node and default setup |
| `wave_cascade_parameters.gd` | `WaveCascadeParameters` resource |
| `wave_generator.gd`, `shaders/compute/` | FFT compute pipeline |
| `ocean_lod_grid.gd` | CDLOD mesh |
| `ocean_surface_queries.gd` | The ocean's `WaterSurface` (async GPU queries) |
| `hull_water_footprint.gd`, `hull_profile.gd`, `ocean_hulls.gd` | Hull cutouts and wake sources |
| `water_interaction_sim.gd`, `shaders/compute/iwave_*` | Wake simulation |
| `ocean_reflection_renderer.gd`, `planar_reflection_capture_effect.gd` | Planar reflections |
| `shaders/spatial/water.gdshaderinc` + `water*.gdshader`, `mat_water.tres` | Water shader and its quality variants |
| `textures/foam_detail.png`, `textures/generate_foam_detail.py` | Foam pattern and its generator |
