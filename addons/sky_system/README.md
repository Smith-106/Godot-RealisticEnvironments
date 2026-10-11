# Sky System

A physical day/night sky: astronomical sun and moon, an atmosphere that draws
the whole sky and hazes the scene, volumetric clouds with weather presets, real
stars and planets, and a light meter for exposure.

Requires the `core` addon and a `RenderingDevice` (Forward+ or Mobile).

## Features

- **Sun and moon** placed for latitude, date and time, coloured and dimmed only
  by the atmosphere; the moon has phases.
- **Atmosphere:** air, ozone and sea haze with multiple scattering — blue sky,
  twilight, the earth's shadow, a hazed horizon, sea fog.
- **Aerial perspective** on every opaque pixel; transparent materials haze
  themselves.
- **Volumetric clouds** that drift with the wind and evolve, with seven
  blendable presets (`clear` … `storm`, `sea_fog`).
- **Night sky:** 9,096 catalog stars with physical brightness and twinkling,
  the Milky Way, airglow and the planets Mercury to Saturn.
- **Scene lighting:** ambient light and reflections from the sky's radiance
  map, and a light meter for `ExposureController`.

## Quick start

1. Enable **Core** and **Sky System** in Project Settings > Plugins. The plugin
   adds the atmosphere's global shader uniforms and debanding to
   `project.godot`.
2. Instance `sky_system.tscn` and remove any other `WorldEnvironment` or
   `DirectionalLight3D`.
3. Add an `ExposureController` (`exposure_system`) pointed at the sky.
   Light levels are physical, so without one nights render near black.
4. To light the ocean, set `OceanSystem.sky_source_path` to this node, and keep
   `sea_level` equal to the ocean's `water_level` (`ocean_environment` does
   both for you).

Keep physical light units and Godot's Environment fog off.

## Main settings

- `time_of_day` 0–1 (0.25 sunrise, 0.5 noon, 0.75 sunset); `cycle_enabled` and
  `cycle_duration_seconds` run a day cycle.
- **Astronomy:** `latitude_degrees`, `day_of_year`, `year`, `lunar_age_days`,
  `north_offset_degrees` (default north is −Z).
- **Clouds:** `clouds_enabled`, `cloud_preset` (blends over
  `cloud_transition_seconds`, or call `transition_clouds_to(preset, seconds)`),
  `cloud_wind_source_path` or `cloud_wind_speed` / `cloud_wind_direction`,
  quality (`cloud_cubemap_size`, `cloud_update_stride`, step counts).
- **Weather haze** is part of each `CloudPreset`: `haze_visibility`,
  `haze_scale_height`, `haze_anisotropy`, `star_scintillation`.
- **Stars:** `star_catalog`, `star_brightness` (1 = physical),
  `airglow_brightness`.
- `sea_level`: world height of the sea.

## Using it from other code

Getters return cached values and are free to call:
`get_sun_direction()`, `get_moon_direction()`, `get_sun_color()`,
`get_sun_visibility()`, `get_moon_phase()`, `get_time_of_day()`,
`get_scene_illuminance()`, `get_illuminance_unit_lux()`, plus cloud, star,
planet and atmosphere textures for the ocean (see the sky-source contract in
`AGENTS.md`). Signals: `time_of_day_changed(time_of_day)`, `lighting_changed`.

Transparent shaders that should be hazed include
`shaders/atmosphere.gdshaderinc` and write
`FOG = atmosphere_fog(world_position);` on every path (see `BowSpray`).
Opaque materials must not write `FOG`.

## Limits

- The camera must stay below the cloud base; clouds cast no shadows on the
  scene.
- The atmosphere is horizontally uniform; points beyond 100 km are hazed as
  at 100 km.
- Fast changes (preset jumps, fast day cycles) settle over about half a second.

## Future work

- **Cloud shadows** on the sea and the scene, and **light shafts** through
  cloud gaps (needs a horizontally varying atmosphere).
- **Flying in and above the clouds** (the camera is now clamped below the
  cloud base).
- **Weather simulation:** advection, growth and rain-out of clouds in place of
  the noise weather map (`cloud_weather.glsl` keeps its output format for
  this).
- **Precipitation:** rain and snow particles, rain shafts below storm clouds,
  lightning.
- **Optical effects:** rainbows, halos around the moon in thin cloud.
- **More night sky:** aurora at high latitudes, earthshine on the moon,
  eclipses, star precession beyond J2000.
- **Local haze:** fog banks and haze that vary across the sea.

## Files

| File | Role |
| --- | --- |
| `sky_system.gd` / `.tscn` | `SkySystem` node, lights and environment |
| `atmosphere_renderer.gd`, `shaders/compute/atmosphere_*` | Atmosphere lookup tables |
| `aerial_perspective_effect.gd`, `shaders/aerial_perspective.glsl` | Scene haze |
| `shaders/atmosphere.gdshaderinc`, `atmosphere_globals.gd` | Haze for transparent materials, global uniforms |
| `cloud_renderer.gd`, `shaders/compute/cloud_*`, `cloud_preset.gd`, `cloud_presets/` | Clouds and weather |
| `star_catalog.gd`, `stars/` | Star catalog and Milky Way (baked by `tools/`) |
| `shaders/sky.gdshader`, `starfield.gdshader`, `celestial_disk.gdshader`, `materials/` | Sky, stars, sun/moon disks |
