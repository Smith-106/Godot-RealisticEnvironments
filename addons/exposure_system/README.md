# Exposure System

Camera exposure from the light falling on the scene, like an incident-light
meter with eye adaptation, darkened further when the view is brighter than that
light (a low sun or moon in view), as the eye adapts to glare. Looking at the
sea or a dark hull does not change it. No dependencies.

## Features

- **Auto exposure** from a light meter; with `adapt_to_view`, a bright view
  (the log-average luminance of the rendered image) lowers it further, so a
  low moon's haze glow or a sunset does not clip to white.
- **Eye adaptation** with separate times for brightening and darkening.
- **Perceptual darkness:** sunset, twilight and night look progressively darker,
  as the eye sees them.
- **Night vision:** below about 3 cd/m² colours fade and shift blue
  (rod vision); the moon keeps its colour.

## Usage

Add an `ExposureController` and set:

- `light_source_path` — a node with `get_scene_illuminance()` (lux at the
  camera, negative while unknown) and `get_illuminance_unit_lux()`.
  `SkySystem` provides both.
- `target_path` — a `WorldEnvironment` or a `Camera3D` (a camera's own
  attributes override the world's, so target the camera if it has some).

Exports: `exposure_compensation_ev`, `perceptual_adaptation` (eye vs. camera),
`brighten_seconds` / `darken_seconds`, `night_vision`,
`night_vision_strength`, `adapt_to_view`. `get_adapted_illuminance()` returns the current
adapted lux.

The controller writes `CameraAttributes.exposure_multiplier` at runtime only,
and adds a `ViewLuminanceEffect` and a `NightVisionEffect` to its target's
compositor. Keep physical light
units off.

## Files

`exposure_controller.gd`, `view_luminance_effect.gd`, `view_luminance.glsl`,
`night_vision_effect.gd`, `night_vision.glsl`,
`exposure_system_plugin.gd`, `plugin.cfg`.
