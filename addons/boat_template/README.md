# Boat Template

**English** · [简体中文](README.zh-CN.md)

`boat.tscn` is a boat with all the systems already wired: driving, stability,
buoyancy and sinking, hit health, hull cutout and wake, bow spray, and camera
anchors. To make a boat, create an **inherited scene** from it.

Requires `core`, `ocean_system`, `sky_system` (the spray is hazed by its
atmosphere), `buoyancy_system` and `hitbox_damage_system`. When enabled, the
plugin adds the drive actions `boat_forward`, `boat_back`, `boat_turn_left`
and `boat_turn_right` (W S A D) to the project, unless they already exist.

## How it works

```
Boat (RigidBody3D, FloatingBoat)   drive input, stability, model animation
├─ CollisionShape3D           placeholder box: replace it
├─ BuoyantBody                buoyancy and sinking  ← Hitboxes.group_destroyed
├─ BuoyancyProbeVolume
│  └─ GeneratedProbes         empty: generate probes for each boat
├─ Hitboxes                   HitboxHealthManager (one "hull" group, 100 HP)
├─ HullWaterFootprint         cutout and wake: bake a profile for each boat
├─ CameraTargets/ThirdPersonFocus, FirstPersonSeat
└─ BowSpray                   stem spray and slam splashes
```

- **`FloatingBoat`** (the root) pushes the boat forward and turns it while
  `player_controlled` is on. Thrust stops above `max_forward_speed` /
  `max_reverse_speed`, and turning weakens at low speed. Optional per-axis
  angular damping and a roll-righting spring add stability. Boats that are not
  player-controlled still float, take damage, sink and make wakes.
- Buoyancy, health and the wake come from the other addons' nodes (see their
  READMEs). Destroying the `hull` group sinks the boat.
- **`BowSpray`** reads the water at the stem. While the stem cuts through the
  water it throws sheets of droplets. When the bow slams down into a wave it
  shoots jets of spray, adds a splash ring to the water and emits
  `slammed(impact_speed, position)`.

## How to use

1. **Scene > New Inherited Scene** from `boat.tscn`. Add your model with the
   bow along −Z.
2. Replace the collision shape, and set `mass` and `center_of_mass`.
3. On `BuoyancyProbeVolume`: set `source_paths`, `design_waterline_y` and the
   probe sizes, press **Generate All Probes**, and save (see
   `buoyancy_system`).
4. On `HullWaterFootprint`: set `bake_source_paths` to the hull only, press
   **Bake Profile**, and save (see `ocean_system`).
5. Add `ProjectileHitbox` areas under `Hitboxes`, and list their groups in
   `group_max_health`. Add a group to `BuoyantBody.sink_on_destroyed_groups`
   if losing it should sink the boat.
6. Move `CameraTargets/*` onto the deck, and `BowSpray` to the stem just below
   the waterline. Set `emission_half_width` to about half the bow's width, and
   raise `particle_size` for large ships.
7. Optional: `animation_player_path` and `autoplay_animation` loop a model
   animation (e.g. sails).
8. Turn on `player_controlled` on the boat the player drives.

Keep the template's node names and order. Scenes inherited from it override
nodes by path.
