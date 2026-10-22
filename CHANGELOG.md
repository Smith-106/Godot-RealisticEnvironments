# Changelog

All notable changes to the open-source addons of Godot-RealisticEnvironments.
The addons share one version (`plugin.cfg`) and follow semantic versioning;
before 1.0 a minor version may change the API.

## Unreleased

- Removed for a rewrite: `buoyancy_system`, the interactive waves (iWave
  wakes, bow waves, splashes, `WaterSurface.add_impulse()` /
  `can_add_impulses()`), hull footprints and cutouts (`HullWaterFootprint`,
  `HullProfile`, `HullSlicer`) and `BowSpray`. `WaterSurface.submit_query()`
  lost its `body` argument.
- New `buoyancy_system`: `BuoyantBody` floats a `RigidBody3D` at a set
  `draft`, level and upright by design, with damping and drag relative to the
  water; it reads only the sea's waves. Boats and floating objects float
  again (no longer frozen).
- `WaterSurface.get_surface_drift()`: the surface water's mean drift (3 % of
  the wind on the ocean), which moves the foam and floating bodies.
- Interactive waves (`ocean_system`): hulls make wakes, bow waves and rings
  as they move relative to the water, simulated around the camera with exact
  finite-depth dispersion (Kelvin wakes) and drawn only (queries leave them
  out). New `WaterDisturbance` and `WaterSurface.submit_disturbance()` /
  `release_disturbance()`; `OceanSystem.interaction_map_size` and
  `interaction_cell_size`; `BuoyantBody.wake_strength`; water debug views 16
  and 17. `fft_compute.glsl` takes a direction and the spectrum count.
- Wake foam: hulls churn up foam around the waterline and in a trail by their
  speed through the water, steep wake crests foam too; it drifts with the
  surface drift, fades over about 8 s and is drawn with the whitecaps
  (`foam_intensity`). Water debug view 18.
- `WaterMask` (`core`): an invisible lid that keeps the water out of an open
  hull through the stencil buffer (value 128, read by every water shader
  tier); **Fit to Hull** slices the hull's model to make it. The rowboat and
  the example boat have one.
- `FloatingBoat`: thrust and rudder act at `propulsion_position` (stern,
  below the waterline) and fade out of the water (`buoyancy_path`); thrust
  eases off toward the speed limits. `turn_torque_per_kg` is replaced by
  `turn_acceleration` (degrees/s², independent of mass). The template's body
  uses `linear_damp_mode` Replace.

## 0.1.0 (in preparation)

First open-source release.

- Ocean: FFT wave cascades (JONSWAP/TMA, one spectrum split by wavelength)
  following an external wind, anisotropically filtered normals, CDLOD
  mesh to a curved horizon, foam, iWave wakes, bow waves and splashes, hull
  cutouts, physical water optics (absorption, scattering, crest glow,
  refraction, caustics), rough-surface Fresnel reflections of the sky, stars
  and planets, screen-space or planar reflections, wind-dependent
  micro-roughness, asynchronous GPU water queries, Low / Medium / High shader
  tiers.
- Sky: astronomical sun and moon, physical atmosphere with sea haze and fog
  and aerial perspective, volumetric clouds with blended weather presets, the
  Bright Star Catalogue, the Milky Way, airglow and planets.
- Exposure: incident-light metering, eye adaptation, rod night vision.
- Buoyancy: probe buoyancy with editor-generated probes, sinking.
- Hitbox damage: grouped health and hit effects.
- `core`: the `WaterSurface` (water queries, splashes) and `WindSource`
  contracts the systems talk through, and RenderingDevice helpers.
- `ocean_environment`: drop-in scene with wind, sky, ocean and exposure.
- `boat_template`: ready-wired boat (driving, stability, buoyancy, health,
  wake, bow spray).
- Plugins set up the project they need (global shader uniforms, debanding,
  input actions); misconfigured nodes show editor warnings.
- `examples/`: ocean only, floating objects, a drivable boat.
- Documentation in English and Simplified Chinese (`README.md` /
  `README.zh-CN.md`): how each addon works and how to use it.
