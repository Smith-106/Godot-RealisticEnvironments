# Buoyancy System

**English** · [简体中文](README.zh-CN.md)

Makes `RigidBody3D`s float on the water. Probes are generated from the hull in
the editor and sample the water every physics tick. The system also gives
water contact events and makes bodies sink.

Requires `core`, and water that registers a `WaterSurface` (e.g.
`ocean_system`).

## How it works

- **Probes.** A `BuoyancyProbeVolume` holds the body's probes. A physical
  probe (`BuoyancyProbeNode`) is the top of a vertical water column with a
  `volume` and a `buoyancy_height`. A contact probe (`BuoyancyFxProbeNode`)
  only reports whether it is wet. In the editor, the volume slices the hull
  mesh at the design waterline and fills the outline with probes. The probes
  are saved with the scene and are never generated at runtime.
- **Sampling.** Every physics tick, `BuoyantBody` submits all probe positions
  as one water query (see `core`'s `WaterSurface`). It applies forces from the
  latest result, extrapolated to the present. Until the first result arrives,
  the body is held frozen.
- **Forces.** Each column pushes up by the weight of the water it displaces.
  Each column also feels water resistance relative to the moving water:
  quadratic drag along the body's three axes, damping while it crosses the
  surface (the energy a bobbing body radiates as waves) and added mass in
  heave. Everything is summed into one force and one torque per tick.
- **Contact states.** Every probe has a `BuoyancyProbeState` (depth,
  submersion, wet/dry with hysteresis, the force it applied, the water's normal
  and velocity). Probes that cross the surface emit enter/exit signals.
- **Sinking** (optional). The body sinks when it rolls too far, when chosen
  probes are flooded, or when a damage group is destroyed. Sinking lowers its
  buoyancy, emits a signal and frees it after a delay.

## How to use

```
RigidBody3D
├─ CollisionShape3D
├─ <hull model>
├─ BuoyantBody             applies the forces; optional sinking
└─ BuoyancyProbeVolume     source_paths → hull model
   └─ GeneratedProbes      generated probes
```

1. Add a `BuoyantBody` under the rigid body. It finds the nearest
   `RigidBody3D` ancestor and the water by itself.
2. Add a `BuoyancyProbeVolume` and set:
   - `source_paths`: the hull mesh;
   - `design_waterline_y`: where the hull should float (local);
   - `physical_probe_count` and `fx_probe_count`;
   - **New Probes**: `generated_probe_volume`, the column height and
	 `generated_probe_freeboard`. Freeboard is the deck's height above the
     waterline, so waves above the waterline still lift the hull.
3. Press **Generate All Probes** and save the scene. Probes are ordinary nodes:
   move, delete or duplicate them as you like.
4. Tune `buoyancy_strength` and the drag coefficients on `BuoyantBody`
   (streamlined hulls want a low `longitudinal_drag_coefficient`, about 0.05).

Together, the probes should hold well over the body's weight when fully
submerged (mass ÷ water density; the demo rowboat holds 2.4×). If the
collision shape is scaled non-uniformly, set the body's `inertia` explicitly,
or it cannot pitch or roll. Turn on `debug_enabled` on the volume to see
probes, the waterline and the forces.

### Contact events and probe states

- Signals: `probe_entered_water(state)`, `probe_exited_water(state)`.
- `get_probe_states(tag)`, `get_wet_probe_states(tag)`, `get_probe_state(probe)`.
  Generated contact probes are tagged `bow`, `side` or `stern`.
- After adding or removing volumes at runtime, call `refresh_volumes()`.
- `apply_forces = false` hands the body back to plain physics.

### Sinking

Turn on `sinking_enabled` and choose the triggers: `max_roll_degrees`,
`sinking_probe_paths` with `sink_probe_depth_threshold`, and
`sink_on_destroyed_groups`. To sink on damage, connect
`HitboxHealthManager.group_destroyed` (or your own signal with the same
arguments) to `BuoyantBody._on_hitbox_group_destroyed` in the scene. Sinking
multiplies buoyancy by `sink_buoyancy_multiplier`, emits
`sinking_started(reason, data)` and frees `delete_root_path` after
`delete_delay`. From code: `start_sinking()`, `is_sinking()`.
