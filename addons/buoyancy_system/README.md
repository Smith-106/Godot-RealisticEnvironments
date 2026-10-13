# Buoyancy System

Probe-based buoyancy for `RigidBody3D`s: probes generated from the hull in the
editor, sampled every physics tick through the world's `WaterSurface`. Also
gives water contact events and sinking.

Requires the `core` addon and a water simulation that registers a
`WaterSurface` (e.g. `ocean_system`).

## Setup

```
RigidBody3D
├─ CollisionShape3D
├─ <hull model>
├─ BuoyantBody             applies the forces; optional sinking
└─ BuoyancyProbeVolume     source_paths → hull model
   └─ GeneratedProbes      generated probe nodes
```

1. Add a `BuoyantBody` under the rigid body (it finds the nearest
   `RigidBody3D` ancestor and the water itself).
2. Add a `BuoyancyProbeVolume`. Set `source_paths` to the hull mesh,
   `design_waterline_y` (local) to where the hull should float, and
   `generated_probe_freeboard` to the height of the deck or gunwale above it,
   so waves above the waterline still lift the hull.
3. Press **Generate All Probes** in the editor and save the scene. The
   **New Probes** settings (`generated_probe_volume`, ...) apply to probes
   generated from then on. Probes are never generated at runtime.
4. Tune `buoyancy_strength`, the probe volumes and the drag coefficients.
   Probes are ordinary nodes you can move, delete or duplicate.

Size the probes so they hold well over the body's weight when fully
submerged (the demo rowboat holds 2.4×). If the collision shape is scaled
non-uniformly, set the body's `inertia` explicitly or it cannot pitch or roll.

## Probes

- **`BuoyancyProbeNode`** (physical): the top of a water column
  `buoyancy_height` tall that displaces `volume` (m³) when fully under water;
  `longitudinal_drag_multiplier` / `lateral_drag_multiplier` scale its drag.
- **`BuoyancyFxProbeNode`** (contact): no force, only wet/dry state and
  enter/exit events, tagged `bow`, `side` or `stern`.

## `BuoyantBody`

Each probe gets buoyancy plus water resistance relative to the moving water:
quadratic drag per axis (`vertical_drag_coefficient`,
`longitudinal_drag_coefficient`, `lateral_drag_coefficient`; about 1 for blunt
bodies, ~0.05 forward for streamlined hulls), wave-making damping
(`heave_damping_ratio`) and added mass (`added_mass_coefficient`). Forces per
probe are capped by `max_probe_acceleration`. The body stays frozen until the
first water result arrives.

API: `get_probe_states(tag_filter)`, `get_wet_probe_states(tag_filter)`,
`get_probe_state(probe)`, `refresh_volumes()`; signals
`probe_entered_water(state)`, `probe_exited_water(state)`. Each
`BuoyancyProbeState` carries the probe's `depth`, `submersion`, `is_wet`,
`entered` / `exited`, `force`, `normal` and `surface_velocity`. Set
`apply_forces = false` to stop forces and sampling.

`debug_enabled` on a volume (off by default) draws probes, the waterline and
forces, in the editor and at runtime. `generate_probes(physical, fx)` is what
the Generate buttons call.

## Sinking

Turn on `sinking_enabled`. The body sinks when roll exceeds
`max_roll_degrees`, when every probe in `sinking_probe_paths` is deeper than
`sink_probe_depth_threshold`, or when a group in `sink_on_destroyed_groups`
is destroyed. For that, connect a damage system's signal (e.g.
`HitboxHealthManager.group_destroyed`) to `_on_hitbox_group_destroyed` in the
scene. Sinking scales buoyancy by `sink_buoyancy_multiplier`, emits
`sinking_started(reason, data)` and frees `delete_root_path` after
`delete_delay`. `start_sinking()` and `is_sinking()` work from code.

## Future work

- **Progressive flooding:** compartments that fill through damage and sink the
  hull with trim and list, instead of one buoyancy multiplier.
- **Wind and current forces:** drag from the wind source on sails and
  superstructure, and drift with water currents.
- **Wave loads:** slamming impacts on the bow and water on deck.
- **Rotational added mass:** added inertia in pitch and roll (heave only today).
- **Probes from collision shapes:** probes for spheres, boxes and capsules
  without a hull mesh, for debris and props.
- **Scaling to many bodies:** fewer probes or sleeping for bodies far from the
  camera.
- **Constraints:** mooring lines, anchors and towing.
