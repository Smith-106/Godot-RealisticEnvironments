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
  planar), with a rough-surface Fresnel.
- **Quality tiers:** Low / Medium / High shaders and 15 debug views.

## Quick start

1. Instance `ocean_system.tscn` (an `OceanSystem`, a `MeshInstance3D`).
2. Optional: set `sky_source_path` to a `SkySystem` so the water reflects its
   sky and follows the time of day.
3. Optional: set `wind_source_path` to a `WindSystem` (or any wind source, see
   `core`'s `WindSource`); without one the waves follow the spectrum's own
   wind.
4. Run with an active `Camera3D` whose far plane reaches past the horizon
   (the demo uses 60 km).

`water_level` sets the sea's height; the node's own transform is ignored, so
leave it at the origin, unrotated and unscaled (it warns otherwise). Without a
`RenderingDevice` (Compatibility renderer, headless) the ocean reports an
error and disables itself.

## Main settings

| Group | What it controls |
| --- | --- |
| `water_level` | Height of the still water. |
| Waves | `spectrum` (`WaveSpectrum`), `cascades` (`WaveCascade`, at most 8), `wind_source_path`. |
| Water | Optical properties: `water_absorption`, `water_scattering`, `water_scattering_anisotropy`. |
| Surface | Roughness (`clear_roughness`, `short_wave_slope_scale`) and `normal_scale` (1 = physical slopes). |
| Foam | `foam_color`, `foam_intensity`, `foam_roughness`, the foam pattern. |
| Sky | `sky_source_path`, reflection strength, sun highlight; `manual_*` values without a sky source. |
| Reflections | `reflection_mode` (`SKY_ONLY`, `SCREEN_SPACE`, `PLANAR`) and the planar reflection's settings. |
| Hull Cutouts / Interaction | Hull cutout range; the wake simulation's grid, damping and foam. |
| Quality | `shader_quality` (`LOW`, `MEDIUM`, `HIGH`), `simulation_map_size` (128–1024), `max_wave_phase_step`, `fragment_cascade_limit`, `use_bicubic_normals`, `mesh_base_cell_size`. |
| Material | `water_material`, the template the ocean duplicates. |

**Waves.** `spectrum` (a `WaveSpectrum`, which you can save as a `.tres` sea
state) is shared by every cascade: its wind (used without a wind source), the
spectrum's shape (`fetch_length`, `water_depth`, `swell`, `spread`, `detail`),
`displacement_scale` (1 = the spectrum's wave height; the demo uses 2) and how
fast the waves follow changes. Each of the `cascades` (`WaveCascade`) is one
FFT tile of it repeating every `tile_length` metres: long tiles for swell,
short for chop. The cascades split the spectrum by wavelength, so no wave is
drawn twice: each draws waves up to a sixth of its tile, the next larger tile
the longer ones (its most regular, tile-periodic waves). Use tile lengths that
don't divide each other (the default 250 / 37 / 9 m), so the tiles never repeat
in step. Per cascade you set the foam (`whitecap`, `foam_generation`,
`foam_lifetime`); retune `whitecap` when you change `displacement_scale`.
`get_wind_speed()` / `get_wind_direction_degrees()` give the wind the waves
follow.

**Debug views.** At runtime, set the shader uniform `water_debug_view` (1–15)
on `get_water_material()` (the ocean's private copy) to show single shading
terms.

## Sky source

`sky_source_path` accepts a `SkySystem` or any node with these methods (all but
the first optional; missing ones fall back to the `manual_*` values or to
nothing):

| Method | Gives the water |
| --- | --- |
| `get_sun_direction()` | Direction toward the sun (world space). |
| `get_sun_visibility()` | Share of the sun reaching the sea (0–1), for caustics. |
| `get_cloud_cubemap()` | Clouds: rgb premultiplied radiance at the cloud, a opacity, full mips; `null` = none. |
| `get_star_cubemap()`, `get_star_basis()`, `get_star_radiance_scale()` | Stars: radiance cubemap, world-to-cubemap rotation, scale to scene radiance. |
| `get_planet_directions()`, `get_planet_irradiance()` | Up to 8 point lights reflected as glints. |
| `get_atmosphere_sky_volumes()`, `get_atmosphere_light()` | The sky seen from the sea through an atmosphere; without them the water reflects a gradient of `manual_sky_top_color` and `manual_sky_horizon_color`. |
| `get_atmosphere_view_volumes()`, `get_atmosphere_view_observer()`, `get_atmosphere_view_max_distance()` | The haze between the camera and the water. |

A source with a `lighting_changed` signal is read only when it fires (emit it
after every change), others every frame.

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
  `water_depth`, giving wave shoaling, refraction and
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
| `wave_spectrum.gd` | `WaveSpectrum` resource (the sea state) |
| `wave_cascade.gd` | `WaveCascade` resource (one FFT tile) |
| `wave_cascade_state.gd`, `wave_generator.gd`, `shaders/compute/` | Cascade simulation state and the FFT compute pipeline |
| `ocean_lod_grid.gd` | CDLOD mesh |
| `ocean_surface_queries.gd` | The ocean's `WaterSurface` (async GPU queries) |
| `hull_water_footprint.gd`, `hull_profile.gd`, `ocean_hulls.gd` | Hull cutouts and wake sources |
| `water_interaction_sim.gd`, `shaders/compute/iwave_*` | Wake simulation |
| `ocean_reflection_renderer.gd`, `planar_reflection_capture_effect.gd` | Planar reflections |
| `shaders/spatial/water.gdshaderinc` + `water*.gdshader`, `mat_water.tres` | Water shader and its quality variants |
| `textures/foam_detail.png`, `textures/generate_foam_detail.py` | Foam pattern and its generator |
