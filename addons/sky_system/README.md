# Sky System

**English** · [简体中文](README.zh-CN.md)

A physical day and night sky. The sun, moon, planets and stars are placed by
astronomy. The atmosphere draws the sky and hazes the scene. It also has
volumetric clouds with weather presets, and a light meter for exposure.

Requires `core` and a `RenderingDevice` (Forward+).

## How it works

- **Astronomy.** Latitude, date, year and `time_of_day` place the sun and the
  moon (with its phase), the planets Mercury to Saturn (orbital elements,
  valid 1800–2050) and the stars (rotating with sidereal time). The sun and the
  moon each drive a `DirectionalLight3D`.
- **Atmosphere.** Every frame, compute shaders integrate the air, the ozone and
  a marine haze into lookup textures: transmittance, multiple scattering, and
  volumes for the camera, the sea and the cloud layer. Everything else only
  samples these textures:
  - the sky shader (sky and the sun and moon disks);
  - the lights' colour and brightness;
  - the haze over opaque geometry (a compositor effect, `AerialPerspectiveEffect`);
  - transparent materials and the ocean.

  The sky's colours, twilight and the earth's shadow all come from this one
  model. There are no hand-made gradients.
- **Clouds.** The clouds are a volume you can fly into and above. A weather
  pass builds a coverage, type and density map around the camera from noise.
  The camera's view is raymarched on screen at half resolution, a quarter of
  those pixels per frame. Earlier frames fill in the rest
  (`VolumetricCloudEffect`, in the scene's compositor). Each pixel's clouds are
  drawn in front of its surface and inside the atmosphere's haze. Two cubemaps
  hold the clouds for everything else: one seen from the sea for the ocean's
  reflection, one seen from the camera for the ambient light. They refresh
  1/4, 1/16 or every texel per frame (`cloud_update_stride`). A `CloudPreset`
  holds one weather state (clouds and haze), and presets blend smoothly into
  each other. The clouds drift with the wind and change shape over time.
- **Night sky.** The 9,096 naked-eye stars of the Bright Star Catalogue are
  drawn as physical point lights that twinkle. The Milky Way, airglow and the
  planets are drawn too. Exposure alone decides which of them are visible.
- **Light meter.** `get_scene_illuminance()` gives the lux at the camera from
  the sun, the moon and the sky. `ExposureController` reads it.

After every change other systems depend on, the sky emits `lighting_changed`.
The day cycle updates the sky (and emits it) each time the sun has moved
0.05°, about every 5 frames for a 10-minute day; the sun and moon lights turn
every frame in between.

## How to use

1. Enable **Core** and **Sky System** in **Project Settings > Plugins**. The
   plugin adds the atmosphere's global shader uniforms and debanding to
   `project.godot`.
2. Instance `sky_system.tscn`. Remove any other `WorldEnvironment` or
   `DirectionalLight3D`.
3. Add an `ExposureController` (`exposure_system`) pointed at the sky. Light
   levels are physical, so without one nights render almost black.
4. With an ocean, set `OceanSystem.sky_source_path` to this node and keep
   `sea_level` equal to the ocean's `water_level`.

Keep physical light units and the Environment's own fog off.
`ocean_environment` sets all of this up.

### Settings

| Group | Contents |
| --- | --- |
| (top) | `sea_level`, `time_of_day` (0 midnight, 0.25 sunrise, 0.5 noon, 0.75 sunset), `cycle_enabled`, `cycle_duration_seconds`. |
| Astronomy | `latitude_degrees`, `day_of_year`, `year`, `lunar_age_days`, `north_offset_degrees` (north is −Z by default), `axis_tilt_degrees`, `advance_calendar_with_cycle`. |
| Lights | `sun_energy_multiplier`, `moon_energy_multiplier` (1 = physical), and how bright the disks are in the ambient light and reflections. |
| Night Sky | `star_brightness` (1 = physical), `airglow_brightness`, `star_catalog`, `star_cubemap_size`. |
| Clouds | `clouds_enabled`, `cloud_preset`, `cloud_transition_seconds`, the wind (`cloud_wind_source_path`, or `cloud_wind_speed` / `cloud_wind_direction`), cloud lighting and quality. |

The presets are in `cloud_presets/`: `clear`, `fair`, `cloudy`, `overcast`,
`rain`, `storm` and `sea_fog`. To make your own, duplicate one. Haze
visibility and star twinkling are part of each preset.

### From code

- `transition_clouds_to(preset, seconds)` changes the weather.
- Getters: `get_sun_direction()`, `get_moon_direction()`, `get_sun_color()`,
  `get_sun_visibility()`, `get_moon_visibility()`, `get_moon_phase()`,
  `get_cloud_state()`, `get_scene_illuminance()`,
  `get_illuminance_unit_lux()`. They return cached values and are cheap.
- Signals: `time_of_day_changed(time_of_day)` and `lighting_changed`.
- The cloud, star, planet and atmosphere getters form the ocean's sky source
  contract (see the `ocean_system` README).

### Haze on transparent materials

Opaque geometry is hazed automatically. A transparent material has to haze
itself: include the atmosphere and write `FOG` in `fragment()`.

```glsl
#include "res://addons/sky_system/shaders/atmosphere.gdshaderinc"
// in fragment():
FOG = atmosphere_fog((INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz);
```

Opaque materials must not write `FOG`.

## Limits

- Clouds cast no shadows on the scene. The sun light dims as the camera goes
  down into the cloud layer, for the whole scene at once.
- Transparent surfaces that write no depth are drawn behind the clouds.
- The atmosphere is the same everywhere horizontally. Points beyond 100 km are
  hazed as if they were at 100 km.
- Fast changes (jumping between presets, fast day cycles) take about half a
  second to settle.
