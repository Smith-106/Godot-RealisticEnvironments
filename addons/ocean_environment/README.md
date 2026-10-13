# Ocean Environment

A drop-in open ocean: `ocean_environment.tscn` holds the wind, sky, ocean and
exposure, already wired together.

Depends on `core`, `wind_system`, `sky_system`, `ocean_system` and
`exposure_system`.

## Quick start

1. Copy those addons and this one into `addons/` and enable them in
   Project Settings > Plugins.
2. Use Forward+, with physical light units off.
3. Instance `ocean_environment.tscn`; remove any other `WorldEnvironment` or
   `DirectionalLight3D`.
4. Add a `Camera3D` whose `far` reaches past the horizon (the demo uses
   60 000 m) and run.

## Inside

```
OceanEnvironment        sea_level for the whole environment
├─ WindSystem
├─ SkySystem            clouds drift with WindSystem
├─ Ocean                reflects SkySystem, waves follow WindSystem
└─ ExposureController   exposes for SkySystem's light
```

- Set `sea_level` on the root; it keeps the ocean and sky in sync.
- For everything else, enable **Editable Children** and edit the systems
  (time of day, clouds, wind, wave cascades, quality, exposure).
- Scripts can reach the systems as `wind`, `sky`, `ocean`, `exposure`.
- Don't rotate, scale or raise the environment: `sea_level` sets the sea's
  height.

To float things, see `buoyancy_system`; for a ready boat, `boat_template`.
