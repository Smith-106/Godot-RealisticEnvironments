# Buoyancy System

**English** · [简体中文](README.zh-CN.md)

Makes `RigidBody3D`s float on the water. In the editor, the hull mesh is baked
into columns that measure its shape. Every physical force comes from that shape,
the body's mass and the water, so there is nothing to tune: a hull floats, trims,
rolls and slows the way its geometry makes it. The system also gives water
contact events and makes bodies sink.

Requires `core`, and water that registers a `WaterSurface` (e.g.
`ocean_system`).

## How it works

- **Baking.** A `BuoyancyProbeVolume` slices the hull at many heights. At each
  height, everything open water cannot reach from the side displaces water:
  solid parts, and the air the hull's sides enclose (an open boat's inside below
  the gunwale), but not a lattice tower water flows through. A grid of columns
  (`BuoyancyProbeNode`) covers the hull's plan. Each column records its
  cross-section at every height (`area_profile`) and the hull sides it owns, with
  their real outward normals (`side_panels`). Contact probes
  (`BuoyancyFxProbeNode`) go on the waterline the body floats at. Probes are
  saved with the scene and never generated at runtime.
- **Report.** The volume's configuration warnings work out how the body floats
  in calm water for its mass and centre of mass. They warn if it sinks, floats
  heeled or trimmed (and say where to put the centre of mass), has almost no
  freeboard, or is unstable upright (negative metacentric height). **Generate**
  prints the full summary: draft, freeboard, reserve buoyancy, metacentric
  heights, heel and trim.
- **Sampling.** Every physics tick, `BuoyantBody` submits all probe positions
  as one water query (see `core`'s `WaterSurface`). It applies forces from the
  latest result, extrapolated to the present. Until the first result arrives,
  the body is held frozen (at most 5 s).
- **Forces**, per column, relative to the moving water, summed into one force
  and one torque:
  - buoyancy: the weight of the water its submerged part displaces, at that
	part's centroid;
  - pressure drag on the faces moving into the water, ½·ρ·C·A·u² with u the
	velocity along the face's normal. C is 1, a flat plate. A fine bow meets the
	water at a slant and so has little drag, while a flat side has much: a hull
	glides forward and grips sideways;
  - hull lift: at a small drift angle a hull is a wing of aspect ratio
	2·draft / length, with side force (π/2)·ρ·T²·U·v (slender-body theory) —
	deep hulls and keels grip, flat ones skid;
  - skin friction on the wetted area (the ITTC 1957 line);
  - wave damping while the column crosses the surface (`wave_damping_ratio`,
	the energy a bobbing body radiates as waves);
  - heave added mass: the waterplane as a flat plate on the water, an exact 3D
	result for an ellipse of its length and area.
- **Contact states.** Every probe has a `BuoyancyProbeState` (depth,
  submersion, wet/dry with hysteresis, the force it applied, the water's normal
  and velocity). Probes that cross the surface emit enter/exit signals.
- **Sinking** (optional). The body sinks when it rolls too far, when chosen
  probes are flooded, or when a damage group is destroyed. Sinking lowers its
  buoyancy, emits a signal and frees it after a delay.

## How to use

```
RigidBody3D                mass, center_of_mass (custom), collision shape
├─ <hull model>
├─ BuoyantBody             applies the forces; optional sinking
└─ BuoyancyProbeVolume     source_paths → hull model
   └─ GeneratedProbes      baked probes
```

1. Give the rigid body its real `mass`. For a boat, also set a custom
   `center_of_mass` (cargo and ballast sit low). If the collision shape is scaled
   non-uniformly, set `inertia` explicitly, or the body cannot pitch or roll.
2. Add a `BuoyantBody` under the rigid body. It finds the nearest
   `RigidBody3D` ancestor and the water by itself.
3. Add a `BuoyancyProbeVolume`. Set `source_paths` to the hull mesh, and if a
   superstructure lets water in, set `watertight_top_y` to the deck.
4. Press **Generate All Probes** and save the scene. Read the summary it prints
   and the volume's warnings: if the body floats tilted, move its
   `center_of_mass` where the warning says.

`physical_probe_count` (about 24) sets how finely the columns follow the hull,
and `fx_probe_count` sets how many contact probes go along the waterline.
`water_density` is 1025 for seawater and 1000 for fresh water. Re-bake after
editing the hull; `tools/bake_buoyancy_probes.gd` re-bakes scenes from the
command line. Turn on `debug_enabled` on the volume to see probes, the waterline
and the forces.

### Contact events and probe states

- Signals: `probe_entered_water(state)`, `probe_exited_water(state)`.
- `get_probe_states(tag)`, `get_wet_probe_states(tag)`, `get_probe_state(probe)`.
  Generated contact probes are tagged `bow`, `side` or `stern`.
- After adding or removing volumes at runtime, call `refresh_volumes()`.
- `apply_forces = false` hands the body back to plain physics.

### Sinking

Turn on `sinking_enabled` and choose the triggers: `max_roll_degrees`,
`sinking_probe_paths` (physical probes that all have at least
`sink_submersion_threshold` of their column under water), and
`sink_on_destroyed_groups`. To sink on damage, connect
`HitboxHealthManager.group_destroyed` (or your own signal with the same
arguments) to `BuoyantBody._on_hitbox_group_destroyed` in the scene. Sinking
multiplies buoyancy by `sink_buoyancy_multiplier`, emits
`sinking_started(reason, data)` and frees `delete_root_path` after
`delete_delay`. From code: `start_sinking()`, `is_sinking()`.
