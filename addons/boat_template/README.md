# Boat Template

**English** · [简体中文](README.zh-CN.md)

`boat.tscn` is a boat with the systems already wired: driving, hit health and
camera anchors. To make a boat, create an **inherited scene** from it.

> **Rewrite in progress.** Buoyancy is being redone from scratch, so the
> template's body is frozen (`freeze = true`) and does not float yet.

Requires `core` and `hitbox_damage_system`. When enabled, the plugin adds the
drive actions `boat_forward`, `boat_back`, `boat_turn_left` and
`boat_turn_right` (W S A D) to the project, unless they already exist.

## How it works

```
Boat (RigidBody3D, FloatingBoat)   drive input, model animation
├─ CollisionShape3D           placeholder box: replace it
├─ Hitboxes                   HitboxHealthManager (one "hull" group, 100 HP)
└─ CameraTargets/ThirdPersonFocus, FirstPersonSeat
```

- **`FloatingBoat`** (the root) pushes the boat forward and turns it while
  `player_controlled` is on. Thrust stops above `max_forward_speed` /
  `max_reverse_speed`, and turning weakens at low speed.
- Health comes from `hitbox_damage_system` (see its README).

## How to use

1. **Scene > New Inherited Scene** from `boat.tscn`. Add your model with the
   bow along −Z.
2. Replace the collision shape, and set the boat's real `mass` and
   `center_of_mass`.
3. Add `ProjectileHitbox` areas under `Hitboxes`, and list their groups in
   `group_max_health`.
4. Move `CameraTargets/*` onto the deck.
5. Optional: `animation_player_path` and `autoplay_animation` loop a model
   animation (e.g. sails).
6. Turn on `player_controlled` on the boat the player drives.

Keep the template's node names and order. Scenes inherited from it override
nodes by path.
