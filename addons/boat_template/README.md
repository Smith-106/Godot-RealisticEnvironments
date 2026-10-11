# Boat Template

`boat.tscn` is a ready-wired boat: driving, stability, buoyancy and sinking,
hitbox health, hull cutout and wake, bow spray and camera anchors. Make a boat
by creating an **inherited scene** from it.

Depends on `core`, `buoyancy_system`, `hitbox_damage_system`, `ocean_system`
and `sky_system` (the spray is hazed by its atmosphere). Enable **Boat
Template** in Project Settings > Plugins to add the drive actions
`boat_forward`, `boat_back`, `boat_turn_left`, `boat_turn_right` (W S A D).

## Template tree

```
Boat (RigidBody3D, FloatingBoat)   drive input, stability, model animation
├─ CollisionShape3D           placeholder box — replace
├─ BuoyantBody                buoyancy + sinking  ← Hitboxes.group_destroyed
├─ BuoyancyProbeVolume
│  └─ GeneratedProbes         empty — generate per boat
├─ Hitboxes                   HitboxHealthManager (one `hull` group, 100 HP)
├─ HullWaterFootprint         cutout and wake — bake per boat
├─ CameraTargets/ThirdPersonFocus, FirstPersonSeat
└─ BowSpray                   stem spray and slam splashes
```

## Making a new boat

1. New Inherited Scene from `boat.tscn`; add your model (bow along −Z).
2. Replace the collision shape; set `mass` and `center_of_mass`.
3. On `BuoyancyProbeVolume`: set `source_paths`, `design_waterline_y` and the
   probe sizes, press **Generate All Probes**, save (see the buoyancy README).
4. Add `ProjectileHitbox` areas under `Hitboxes`; list their groups in
   `group_max_health`, and in `BuoyantBody.sink_on_destroyed_groups` if losing
   them should sink the boat.
5. Move `CameraTargets/*` to the deck and `BowSpray` to the stem, just below
   the waterline. Set its `emission_half_width` to about half the bow's width.
6. On `HullWaterFootprint`: set `bake_source_paths` to the hull only, press
   **Bake Profile**, save (see the ocean README).
7. Optional: `animation_player_path` and `autoplay_animation` loop a model
   animation (e.g. a sail).
8. Set `player_controlled` on the boat the player drives.

## Nodes

- **`FloatingBoat`** (root): throttle and turning forces (`max_forward_speed`,
  `max_reverse_speed`, `low_speed_turn_factor`), per-axis angular damping and a
  roll-righting spring. Only reads input while `player_controlled` is set; every
  boat still floats, takes damage, sinks and makes wakes.
- **`BowSpray`**: droplet sheets while the stem cuts the water (`spray_rate`,
  `spray_speed_min` / `spray_speed_full`), and on hard bow re-entries
  (`slam_speed_threshold`) jets of spray plus a splash ring in the water.
  Emits `slammed(impact_speed, position)`. Raise `particle_size` for large
  ships.
