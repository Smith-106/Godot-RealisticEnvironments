# Boat Template

**English** · [简体中文](README.zh-CN.md)

`boat.tscn` is a boat with all the systems already wired: driving, buoyancy and
sinking, hit health, hull cutout and wake, and camera anchors. To make a boat, create an **inherited scene** from it.

Requires `core`, `ocean_system`, `sky_system` (the spray is hazed by its
atmosphere), `buoyancy_system` and `hitbox_damage_system`. When enabled, the
plugin adds the drive actions `boat_forward`, `boat_back`, `boat_turn_left`
and `boat_turn_right` (W S A D) to the project, unless they already exist.

## How it works

```
Boat (RigidBody3D, FloatingBoat)   drive input, model animation
├─ CollisionShape3D           placeholder box: replace it
├─ BuoyantBody                buoyancy and sinking  ← Hitboxes.group_destroyed
├─ BuoyancyProbeVolume
│  └─ GeneratedProbes         empty: generate probes for each boat
├─ Hitboxes                   HitboxHealthManager (one "hull" group, 100 HP)
├─ HullWaterFootprint         cutout and wake: bake a profile for each boat
└─ CameraTargets/ThirdPersonFocus, FirstPersonSeat
```

- **`FloatingBoat`** (the root) pushes the boat forward and turns it while
  `player_controlled` is on. Thrust stops above `max_forward_speed` /
  `max_reverse_speed`, and turning weakens at low speed. Staying upright, the
  water's grip on the hull and its drag all come from the buoyancy, from the
  hull's shape and the boat's mass: a hull without a keel skids in turns. Boats
  that are not player-controlled still float, take damage, sink and make wakes.
- Buoyancy, health and the wake come from the other addons' nodes (see their
  READMEs). Destroying the `hull` group sinks the boat.
- **`BowSpray`** (`bow_spray.gd`, stem spray and slam splashes) is in the addon
  but not in the template for now.

## How to use

1. **Scene > New Inherited Scene** from `boat.tscn`. Add your model with the
   bow along −Z.
2. Replace the collision shape, and set the boat's real `mass` and
   `center_of_mass`.
3. On `BuoyancyProbeVolume`: set `source_paths` to the hull, press
   **Generate All Probes**, and save. If its warnings say the boat floats
   tilted, move `center_of_mass` where they say (see `buoyancy_system`).
4. On `HullWaterFootprint`: set `bake_source_paths` to the hull only, press
   **Bake Profile**, and save (see `ocean_system`).
5. Add `ProjectileHitbox` areas under `Hitboxes`, and list their groups in
   `group_max_health`. Add a group to `BuoyantBody.sink_on_destroyed_groups`
   if losing it should sink the boat.
6. Move `CameraTargets/*` onto the deck.
7. Optional: `animation_player_path` and `autoplay_animation` loop a model
   animation (e.g. sails).
8. Turn on `player_controlled` on the boat the player drives.

Keep the template's node names and order. Scenes inherited from it override
nodes by path.
