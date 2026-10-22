# Boat Template

**English** · [简体中文](README.zh-CN.md)

`boat.tscn` is a boat with the systems already wired: buoyancy, driving, hit
health and camera anchors. To make a boat, create an **inherited scene** from
it.

Requires `core`, `buoyancy_system` and `hitbox_damage_system`. When enabled,
the plugin adds the
drive actions `boat_forward`, `boat_back`, `boat_turn_left` and
`boat_turn_right` (W S A D) to the project, unless they already exist.

## How it works

```
Boat (RigidBody3D, FloatingBoat)   drive input, model animation
├─ CollisionShape3D           placeholder box: replace it
├─ Hitboxes                   HitboxHealthManager (one "hull" group, 100 HP)
├─ CameraTargets/ThirdPersonFocus, FirstPersonSeat
└─ BuoyantBody                floats the boat (draft 0.3 m)
```

- **`BuoyantBody`** floats the boat (see `buoyancy_system`'s README). The
  body's `linear_damp_mode` is **Replace**, so only the water slows it.
- **`FloatingBoat`** (the root) drives the boat while `player_controlled` is
  on. The propeller pushes and the rudder pushes sideways at
  `propulsion_position`, at the stern below the waterline: the bow lifts a
  little as the boat speeds up, and the boat leans and slides into turns.
  Both fade out as that point leaves the water (`buoyancy_path`). Thrust eases
  off toward `max_forward_speed` / `max_reverse_speed`. `turn_acceleration`
  is the yaw acceleration at full rudder, whatever the boat's mass; the
  water's sideways drag sets the turn rate it settles at, and turning weakens
  at low speed (`low_speed_turn_factor`).
- Health comes from `hitbox_damage_system` (see its README).

## How to use

1. **Scene > New Inherited Scene** from `boat.tscn`. Add your model with the
   bow along −Z.
2. Replace the collision shape, and set the boat's `mass` and
   `center_of_mass`. On `BuoyantBody`, set `draft` (how deep the hull sits)
   and the drag; on the root, put `propulsion_position` at the stern, below
   the waterline.
3. Add `ProjectileHitbox` areas under `Hitboxes`, and list their groups in
   `group_max_health`.
4. Move `CameraTargets/*` onto the deck.
5. Optional: `animation_player_path` and `autoplay_animation` loop a model
   animation (e.g. sails).
6. Turn on `player_controlled` on the boat the player drives.

Keep the template's node names and order. Scenes inherited from it override
nodes by path.
