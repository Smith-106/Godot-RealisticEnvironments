# Ocean System

**English** · [简体中文](README.zh-CN.md)

An open ocean for Godot 4.8 Forward+. It has wind-driven FFT waves out to a
curved horizon, physically based water shading, foam and reflections. Hulls
make wakes, and anything that floats can query the water height on the GPU.

Requires `core` and a `RenderingDevice` (Forward+). Without one
(Compatibility renderer, headless) the ocean reports an error and stays off.

## How it works

- **One sea state, several tiles.** A `WaveSpectrum` describes the sea: a
  wind-driven JONSWAP spectrum, corrected for water depth (TMA). The
  `WaveCascade`s are FFT tiles of this spectrum at different sizes (default
  250, 37 and 9 m). Each tile draws only its own band of wavelengths, so
  together they draw the spectrum exactly once, from long swell to short chop.
- **GPU wave synthesis.** Compute shaders advance each cascade's spectrum to
  the current time and run an inverse FFT. The output is a displacement map
  and a normal map (slopes and foam) with full mip chains. Small tiles update
  more often than large ones, and frames in between blend two FFT results.
- **Following the wind.** The wind comes from `wind_source_path`, or else from
  the spectrum's own settings. When it changes past a threshold, a new
  spectrum is generated in a spare slot and crossfaded in. The sea never jumps,
  and long swell turns toward a new wind more slowly than chop.
- **Mesh to the horizon.** The mesh is a quadtree of grid patches around the
  camera (CDLOD, drawn as one multimesh), finest near the camera. It bends with
  the earth's curve, so the sea ends at the real horizon. The vertex shader
  displaces it by every cascade. Far waves are filtered through mip levels, not
  faded out.
- **Shading.** Absorption and scattering in the water set its colour. Light
  through thin crests makes them glow, and the shader adds refraction,
  caustics and foam where waves compress. One rough-surface Fresnel weights
  every reflection: the sky with its clouds, stars, planets and atmosphere,
  the sun's highlight, and the scene (screen-space or planar).
- **Wakes and splashes.** An iWave simulation runs on a window around the
  camera (by default 512 × 512 cells of 0.5 m). Hulls (`HullWaterFootprint`)
  push water in it, which makes Kelvin wakes, bow waves and wake foam.
  `add_impulse()` adds splash rings. Water inside nearby hulls is cut out.
- **Water queries.** The ocean registers a `WaterSurface` (see `core`). All
  queries in a frame go to the GPU in one dispatch. They sample the same
  surface that is drawn, wakes included, and are read back asynchronously.

The sea lies at `water_level`. The node's own transform is ignored.

## How to use

1. Enable **Core** and **Ocean System** in **Project Settings > Plugins**, then
   instance `ocean_system.tscn`. Leave the node at the origin, unrotated and
   unscaled, and set the height with `water_level`.
2. Use a `Camera3D` whose `far` reaches past the horizon. From 10 m up the
   horizon is 11 km away, from 100 m up 36 km; the demo uses 60 km.
3. Optional: set `wind_source_path` to a `WindSystem` and `sky_source_path` to
   a `SkySystem`. Without them, the waves use the spectrum's own wind and the
   water reflects the **Manual Sky** colours.

`ocean_environment` does all of this for you.

### Settings

| Group | Contents |
| --- | --- |
| `water_level` | Height of the still water. |
| Waves | `spectrum`: wind (used without a wind source), `fetch_length` (the sea stops growing once fully developed), `water_depth`, `swell`, `spread`, `detail`, `displacement_scale` (1 = physical height; the demo uses 2), and how fast the sea follows changes. Save one as a `.tres` to reuse a sea state. `cascades` (at most 8): `tile_length`, plus foam (`whitecap`, `foam_generation`, `foam_lifetime`). Use tile lengths that don't divide each other, the largest at least 1.5 times the peak wavelength (the ocean warns otherwise). Retune `whitecap` after changing `displacement_scale`. |
| Water | `water_absorption`, `water_scattering`, `water_scattering_anisotropy`: the only source of the water's colour. |
| Surface | `clear_roughness`, `short_wave_slope_scale` (wind ripples too small to simulate), `normal_scale` (1 = physical slopes). |
| Foam | `foam_color`, `foam_intensity`, `foam_roughness`, the foam pattern texture and its tile size. |
| Sky | `sky_source_path`, reflection strength and F0, the sun's highlight; **Manual Sky** values for when there is no sky source. |
| Reflections | `reflection_mode`: `SKY_ONLY`, `SCREEN_SPACE` or `PLANAR` (default), plus the planar reflection's resolution and clipping. Render layer 20 (`reflection_water_layer`) is reserved for the water. |
| Hull Cutouts | `hull_cutout_distance`. |
| Interaction | The wake simulation: on/off, grid, cell size, step rate, damping and foam. |
| Quality | `shader_quality` (`LOW`, `MEDIUM`, `HIGH`), `simulation_map_size` (128–1024), `max_wave_phase_step`, `fragment_cascade_limit`, `use_bicubic_normals`, `mesh_base_cell_size`. |
| Material | `water_material`: the template the ocean copies. The ocean renders with a private duplicate. |

From code: `get_wind_speed()` and `get_wind_direction_degrees()` give the wind
the waves follow. `get_water_material()` returns the material actually used. To
show single shading terms, set its `water_debug_view` uniform (1–15) at
runtime.

### Ships: cutouts and wakes

1. Add a `HullWaterFootprint` to the ship, rigidly attached (usually a direct
   child of the body; the boat template has one).
2. Set `bake_source_paths` to the hull meshes only (no masts or rigging).
3. Save the scene, press **Bake Profile**, and save again.

The baked `HullProfile` hides the water inside the hull and lets the hull
push water. Tune the wakes in the **Wake** group. If waves cresting a low
gunwale show water inside the boat, raise `cutout_height_offset`. Only the 8
nearest hulls get cutouts, and only the 32 nearest make wakes.

### Water queries and splashes

Use `WaterSurface.find(node)` from `core` (its README has the example), never
`OceanSystem`. Bodies with their own `HullWaterFootprint` read only the FFT
waves, not the wakes they make themselves. Up to 64 splashes per simulation
step are accepted.

### Sky source

`sky_source_path` accepts a `SkySystem` or any node with these methods. Only
the first one is required; the ocean falls back to the **Manual Sky** values
for missing ones.

| Method | Gives the water |
| --- | --- |
| `get_sun_direction()` | Direction toward the sun (world space). |
| `get_sun_visibility()` | Share of the sun reaching the sea (0–1). |
| `get_cloud_cubemap()` | Clouds seen from the sea: rgb premultiplied radiance at the cloud, a opacity, full mips; `null` = none. |
| `get_star_cubemap()`, `get_star_basis()`, `get_star_radiance_scale()` | Stars: radiance cubemap, world-to-cubemap rotation, scale to scene radiance. |
| `get_planet_directions()`, `get_planet_irradiance()` | Up to 8 point lights, reflected as glints. |
| `get_atmosphere_sky_volumes()`, `get_atmosphere_light()` | The sky seen from the sea, through the atmosphere. Without them the water reflects a gradient from `manual_sky_top_color` to `manual_sky_horizon_color`. |
| `get_atmosphere_view_volumes()`, `get_atmosphere_view_observer()`, `get_atmosphere_view_max_distance()` | The haze between the camera and the water. |

If the source has a `lighting_changed` signal, the ocean reads it only when
that signal fires (emit it after every change). Otherwise it reads it every
frame.

## Limits

- Below the water the surface is drawn as seen from under it (Snell's window, total
  internal reflection, the water between), but nothing else is: objects under the
  water get no underwater fog and there are no light shafts.
- One ocean per world, with one depth for the whole sea (no shores).
- Only the drawing is curved. Queries, buoyancy and the wake simulation treat
  the sea as flat.
- Wakes exist only inside the simulation window around the camera.
