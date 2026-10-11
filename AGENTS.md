# AGENTS.md

Working rules for changing this project: only what is easy to get wrong. Read
the addon's `README.md` and the scripts' `##` doc comments before changing it.

## Ground rules
- No compatibility shims: rename or delete APIs, scenes, groups and uniforms
  freely, and update every caller and scene in the same change.
- Production-grade errors: anything a shipped game can hit (missing/wrong node,
  bad config or data, failed GPU resource or shader, too many requests) is
  reported with `push_error` and the feature degrades or disables itself; never
  crash or write out of bounds. `assert()` is stripped from release builds:
  only for internal invariants. Resolve dependencies once (usually `_ready`),
  model expected states ("no result yet", "disabled") explicitly, and check
  `RenderingContext.failed` after building compute resources.
- Editor setup mistakes also show as configuration warnings
  (`_get_configuration_warnings()`, refreshed by `update_configuration_warnings()`
  in the relevant setters): missing sources/paths, missing sky globals,
  `sea_level` ≠ `water_level`, camera far planes short of the horizon, missing
  probes, hull profiles or input actions. Runtime-only nodes are `@tool` and
  return early from `_ready` in the editor with processing off.
- `docs/*-plan.md` are completed design records (their *Deferred verification*
  lists are still open).

## Project basics
- Godot 4.8, Forward+. Main scene `res://demo/main.tscn`. No package manager,
  CI, formatter or tests. Verify by running `demo/main.tscn` (or
  `demo/ocean_optics_debug.tscn` for shading). Headless/Compatibility runs have
  no `RenderingDevice`: they catch GDScript errors, not ocean regressions.
- Keep every script warning-free (warnings are on for addons too): rename
  locals that shadow members (`basis`, `position`, `scale`, `owner`, ...), mark
  intended integer division with `@warning_ignore("integer_division")`, type
  nodes by assignment (`@onready var x : Camera3D = $Camera3D`), not `as`.
  `tools/gd_lint.py` lists warnings via a headless editor's language server.
- Reusable code in `addons/*`; demo glue in `systems/` and `demo/`.
  `examples/` uses only the open-source addons (never `systems/`, `demo/`,
  projectile weapons or `floating_boat_template`); its hull mesh comes from
  `tools/make_example_hull.py`.
- Runtime types use `class_name`; `*_plugin.gd` only set up the project via
  core's `ProjectSetup`, adding missing settings and never changing existing
  ones. A new project requirement goes into the plugin plus a runtime check
  that reports it. `plugin.cfg` `script` paths are relative.
- `.godot/`, `.import/`, `build/`, `export*.cfg`, `fft_wave.md`, `todo.md` are
  ignored local state, never sources of truth.

## Scenes and resources
- Keep `res://` paths and `uid://` values intact in `.tscn`/`.tres`. Every
  script has a committed `.gd.uid`; move it with the script, commit new ones.
- `addons/boat_template/boat.tscn` is the open-source boat.
  `addons/floating_boat_template/floating_boat.tscn` (dev only) inherits it and
  adds `Weapons` at child index 4 (between `Hitboxes` and
  `HullWaterFootprint`). `demo/rowboat.tscn` and `demo/floating_box.tscn`
  inherit that and override nodes by path with matching `index` attributes:
  renaming/reordering template nodes breaks them, `sinking_probe_paths` and
  `demo/main.gd`.
- Buoyancy probes and hull profiles are generated in the editor and saved;
  runtime generation is refused. The template has neither.
- A non-uniformly scaled collision shape gives zero inverse inertia; set
  `inertia` explicitly (as `floating_box.tscn` does).
- No `/** */` doc comments in `.gdshader`/`.gdshaderinc` (editor extracts them
  on every uniform-list call; stalled the editor for seconds). Use `/*` or `//`.
- Debug helpers (probe draw, trail, aim marker, health panel) and the
  starfield are internal runtime children; never save them into a scene.

## Addon boundaries
- `*_system` addons never depend on each other; shared code goes into `core`
  (depends on nothing). Otherwise connect via signals, groups, duck typing.
- Water consumers use only `WaterSurface.find(node)`, never `OceanSystem`.
  Damage sinking: connect `HitboxHealthManager.group_destroyed` to
  `BuoyantBody._on_hitbox_group_destroyed` in the scene; no hitbox imports in
  buoyancy code.
- Only `ocean_environment` and `boat_template` compose systems
  (`floating_boat_template` adds weapons). `OceanEnvironment.sea_level` sets
  both `OceanSystem.water_level` and `SkySystem.sea_level`.
- `projectile_launcher_system` and `floating_boat_template` are dev/demo, not
  open source: leave them be, and keep other addons independent of them.
- Directions: degrees, 0 = +Z, 90 = +X. Only
  `WaveCascadeParameters._world_wind_direction_to_spectrum_direction` converts
  to the FFT's frame.

## Cross-system contracts (change both sides together)
- **Wind source:** `get_wind_speed()` + `get_wind_direction_degrees()`, or
  `wind_speed` / `wind_direction` properties.
- **Sky source:** `get_sun_direction/sky_top_color/sky_horizon_color/
  sky_ground_horizon_color/sky_ground_bottom_color/sun_visibility()` (or same-
  name properties; missing values fall back to `manual_*`). With a
  `lighting_changed` signal it is read only when that fires, so emit it after
  every lighting change and before freeing textures it handed out. Optional:
  - `get_cloud_cubemap()`: rgb premultiplied cloud radiance at the cloud, a
    opacity, full mips; `null` = no clouds.
  - `get_star_cubemap()`, `get_star_basis()`, `get_star_radiance_scale()`: the
    water reflects them weighted by `1 − planar coverage` (the mirrored camera
    draws its own starfield), so stars never count twice.
  - `get_planet_directions()`, `get_planet_irradiance()` (≤
    `OceanSystem.MAX_SKY_POINTS`): glints on the water; the starfield omits
    planets for cameras below `sea_level`.
  - `get_atmosphere_sky_volumes()` + `get_atmosphere_light()`: the sky the
    water reflects (clouds composited inside the atmosphere).
    `get_atmosphere_view_volumes()`, `get_atmosphere_view_observer()` (read
    every frame), `get_atmosphere_view_max_distance()`: the water's own `FOG`.
- **Exposure:** a light source has `get_scene_illuminance()` (lux, negative
  while unknown) and `get_illuminance_unit_lux()`. `ExposureController` writes
  `CameraAttributes.exposure_multiplier`; Godot applies it to lights,
  `EMISSION` and sky output, not unshaded `ALBEDO` or `FOG`. Systems writing
  their own light read the effective exposure each frame and store HDR
  textures pre-exposed; the sky shader and water divide by it again. Apply
  exposure nowhere else; keep physical light units off. Night tint and
  desaturation only via `NightVisionEffect`.
- **Atmosphere globals:** `atmosphere_*` global uniforms, declared in
  `project.godot` `[shader_globals]`, listed in `AtmosphereGlobals` and
  `atmosphere.gdshaderinc` (change all three together), written only by the
  owning `SkySystem`. Transparent materials haze themselves with
  `FOG = atmosphere_fog(...)`; only `sky_system` and `boat_template` include it.
  Opaque materials must not write `FOG`. Environment fog stays off.
- **Hulls:** `HullWaterFootprint` (group `ocean_hull`) with an editor-baked
  `HullProfile` `.tres` (never hand-edit the image). ≤ 8 cutouts near the
  camera, ≤ 32 wake footprints. SimHull record = 36 floats
  (`WaterInteractionSim.FLOATS_PER_HULL`, `iwave_pressure.glsl`).
- **Water surface:** a simulation registers one `WaterSurface` per `World3D`
  in `_enter_tree` and unregisters in `_exit_tree`. Splashes:
  `add_impulse(position, radius, amplitude)` while `can_add_impulses()` (≤ 64
  per step).
- **Weapons:** recoil receivers implement `apply_recoil(fire_direction,
  shot_data)`; projectiles are group `projectile` or have `launch()` and carry
  `source_rigid_body_instance_id` metadata. `player_controlled` gates boat
  drive and weapon input (`controlled_property`).

## Ocean invariants
- CDLOD: one multimesh of 16 × 16 nodes set via the RenderingServer, selected
  per frame (`OceanLodGrid.update()`). `LOD_RANGE_FACTOR` must stay above ~2.8
  or levels crack. Only the drawing curves with the earth (`EARTH_RADIUS`);
  queries, buoyancy, hulls, reflections and the simulation stay flat. Keep
  camera far planes past the horizon (demo: 60 km). The editor shows
  `editor_water_preview_mesh.tres`. Never save a generated mesh; don't rotate
  or scale the ocean.
- Shader code lives in `water.gdshaderinc`; `water.gdshader`,
  `water_medium.gdshader`, `water_low.gdshader` only set defines. All variants
  keep identical uniforms (compile features out, not uniforms).
- The ocean renders with a private duplicate of `water_material` via
  `instance_geometry_set_material_override`. Never set `material_override`;
  keep `mat_water.tres` free of runtime values.
- Push constants (`RenderingContext.create_push_constant()`) are packed at the
  shader's exact size, 4 bytes per value, no padding: edit GLSL and packing
  together. Same for `CloudRenderer`'s push constants and Params buffer.
- Storage images are `readonly`/`writeonly`; descriptor sets bind by array
  index, so order matches binding numbers.
- `simulation_map_size`: power of two, 128–1024 (`fft_compute.glsl` has one
  `#[versions]` entry per size). ≤ 8 cascades, each with active + pending
  spectrum slots crossfading every input change; only `tile_length`, cascade
  count and map size regenerate without crossfade.
- Dispatches in one compute list are unordered: put
  `compute_list_add_barrier` between dependent passes, and set every pass's
  push constant (a barrier re-applies the last one).
- Displacement/normal maps have full mips (`mip_chain.glsl`). Normal maps are
  `(slope x, slope z, squared slope, foam)`; `z − |xy|²` is slope variance
  → roughness. Keep every channel linearly averageable. Storage bindings use
  per-layer single-mip views; compute shaders read displacement via samplers.
- Lighting: `light()` does body diffuse (by light height), crest scattering
  and the sun's GGX; sky and planar reflections are `EMISSION`. Colour comes
  only from `water_absorption`, `water_scattering`,
  `water_scattering_anisotropy`: no artistic tints. `SPECULAR = 0` (engine
  specular doubles the sky). Reflections share one rough-surface Fresnel
  (`rough_fresnel`), never plain Schlick. `normal_scale` 1 = physical slopes.
- Transparency: water is in the transparent pass; light from behind goes into
  `EMISSION` (no `ALPHA`) via `underwater_transmittance()`, albedo scaled by
  `1 − transmittance` (same transmittance). Keep `depth_draw_always`,
  `cast_shadow` off and `mat_water.tres` `render_priority` below every other
  transparent material. Caustics only in the water (`caustic_light()`).
- `displacement_scale` 1 = physical JONSWAP height (demo uses ~2). `whitecap`
  thresholds include it; retune them together. Foam is coverage averaged by
  mips: no distance fades. `foam_detail.png` must stay uniformly distributed
  (regenerate with `generate_foam_detail.py`).
- Surface queries are async: `submit_query` every tick, `get_query_result`
  (null at first), `release_query` in `_exit_tree`. Extrapolate with
  `extrapolated_height(water.get_query_age(result))`, never
  `get_clock() - dispatch_time`. Results belong to their dispatch's points.
- Anything sampling wave displacement must match the vertex shader:
  per-cascade A/B frame blend (`OceanSystem._get_cascade_frame_blend()`),
  spectrum blend weights (`spectrum_blend_states.zw`, skip pending when
  `.w == 0`). Cascade buffer = 48 bytes/cascade
  (`OceanSurfaceQueries.BYTES_PER_CASCADE`, `ocean_sampling.glslinc`). Queries
  read mip 0 and invert horizontal displacement.
- Includes aren't tracked by the importer: after editing an include, delete
  `.godot/imported/<name>-*` of every shader using it (touching is not
  enough). `ocean_sampling.glslinc` → `surface_query.glsl`,
  `iwave_pressure.glsl`; `iwave_common.glslinc` → every `iwave_*.glsl`;
  `atmosphere_common.glslinc` → `atmosphere_*.glsl`, `aerial_perspective.glsl`;
  `cloud_noise.glslinc` → `cloud_noise_bake.glsl`, `cloud_weather.glsl`.
- Interaction sim (`WaterInteractionSim`, runtime only) simulates `η = h + p`.
  Render texture `(h, η, foam, hull coverage)`. Queries add `η · (1 −
  coverage)`, except for owners on a wave-making body, which read FFT waves
  only (own waves fed back make it oscillate). Don't add a geometric own-wave
  mask. Steps per physics tick or at `interaction_steps_per_second`.
  `interaction_grid_size` is a power of two ≤ 1024 (exact FFT of `g·|k|`).
- `HullProfile` images are RGBA16F; changing channels means re-baking all
  profiles (one texture array format).
- Planar reflections reserve render layer 20 (`reflection_water_layer`) for
  water. The water samples `PlanarReflectionCaptureEffect.texture` and
  `distance_texture` (resize both via `set_size()`), not the SubViewport.
- Texture RIDs: a material keeps the RID set on it. Swap a `Texture2DRD`'s
  `texture_rd_rid` directly (never clear to `RID()` first, which frees it →
  white), or re-set the parameter with `_set_water_shader_parameter(..., force)`
  (it skips unchanged values). Getting this wrong made reflections white after
  window resizes.

## Sky invariants
- `CloudRenderer` renders clouds as seen at the cloud into a cubemap's upper
  half; sky shader, starfield and water composite it inside the atmosphere
  (`atmosphere_sky_with_clouds()`). Change the encoding everywhere together.
  Camera is assumed below the cloud base.
- Sky/starfield cloud uniforms go only through
  `RenderingServer.material_set_param`, never `set_shader_parameter`.
- The sky shader must not read `POSITION` or `TIME` (forces radiance re-renders);
  the `Sky` is INCREMENTAL and `SkySystem._refresh_sky_radiance()` refreshes it.
- The weather map is written only by `cloud_weather.glsl`; the raymarcher is a
  pure reader. Noise percentile constants in `cloud_noise_bake.glsl` must be
  recomputed when the noise changes.
- `CloudPreset` fields interpolate and are listed in `BLENDED_PROPERTIES`
  (`haze_visibility` also in `GEOMETRIC_BLENDED_PROPERTIES`).
- Keep `rendering/anti_aliasing/quality/use_debanding` on (night skies band).
- Stars are physical light (magnitude → lux, × exposure in the shader): no
  visibility curves, twilight fades or moon washout. `starfield.gdshader`
  writes `POSITION` on the far plane; take `abs()` of the projection's `[1][1]`.
  `bright_star_catalog.tres` and `milky_way.exr` are generated by `tools/`; the
  Milky Way holds only stars fainter than V = 8, keep the catalog within that.
- The atmosphere model lives only in `AtmosphereRenderer`'s compute passes;
  consumers only sample. The one CPU copy is
  `SkySystem._get_atmosphere_transmittance()` (same constants). Don't add sky
  gradients, ambient terms, light colour curves or night gating: sun and moon
  colours come only from transmittance, and both bodies light the atmosphere.
- The view-volume layout (`atmosphere_view_uvw()`, slices) and lobe phase are
  copied in `atmosphere_common.glslinc`, `atmosphere.gdshaderinc` and the
  water shader; change together. Consumers composite
  `background * transmittance + inscatter + lobe * phase`.
- Atmosphere and cloud outputs are pre-exposed; the sky shader divides by
  `atmosphere_exposure`, and once more in `AT_CUBEMAP_PASS` (Godot 4.8 exposes
  the radiance map twice).
- `AerialPerspectiveEffect` (in `sky_system.tscn`'s compositor, no exported
  state) runs before the transparent pass, per sample with MSAA.

## Physics layers
- Layer 2 `Projectile`, layer 3 `Hitbox`. Projectiles: layer 2, mask 4;
  hitboxes: layer 3, mask 2. Projectiles don't collide with ships.

## Known quirks (don't "fix" silently)
- `Projectile` uses a flat `waterline_y` and `ProjectileWeaponController` a
  flat `aim_plane_y`; neither uses wave height.
- F is both `toggle_fullscreen` and `camera_move_down`; C is both
  `cycle_camera_mode` and `toggle_camera_follow`.
