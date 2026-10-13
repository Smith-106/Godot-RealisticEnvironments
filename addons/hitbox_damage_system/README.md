# Hitbox Damage System

`Area3D` hitboxes that detect projectiles, a manager that turns hits into
grouped health (e.g. `hull`, `mast`), a smoke hit effect and an optional debug
health panel. No dependencies.

## Setup

```
Ship (RigidBody3D)
└─ Hitboxes (HitboxHealthManager)
   ├─ HullHitbox  (ProjectileHitbox, hitbox_group = "hull") + CollisionShape3D
   └─ MastHitbox  (ProjectileHitbox, hitbox_group = "mast") + CollisionShape3D
```

- Each hitbox finds the nearest `HitboxHealthManager` above it (or its
  `manager_path`) and warns in the editor without one.
- Set each hitbox's own `collision_mask` to the projectiles' physics layer
  (the demo: hitboxes on layer 3 "Hitbox", mask 2 "Projectile").
- A projectile is anything in group `projectile` or with a `launch()` method.
  Hits from the ship's own projectiles are ignored (`ignore_own_projectiles`).
- Set health per group in `group_max_health` (the debug panel shows these)
  and multipliers in `group_damage_multipliers`; other groups use
  `default_group_max_health`.
- Damage is `hit_data.damage` if given, else projectile momentum ×
  `damage_per_momentum` × multipliers (at least `minimum_hit_damage`).
- Connect `group_destroyed` to whatever reacts, e.g.
  `BuoyantBody._on_hitbox_group_destroyed`.

Signals: `projectile_hit` (hitbox), `hitbox_hit`, `group_health_changed`,
`group_destroyed` (manager). Methods: `handle_projectile_hit(hitbox,
projectile, hit_data)` (also for damage from your own code: pass the group and
`damage` in `hit_data`), `get_group_health()`, `get_group_max_health()`,
`set_group_health()`, `is_group_destroyed()`, `reset_health()`.

`hit_effect_scene` (default: smoke puff) spawns at each impact.
`debug_ui_enabled` shows a health bar per group.
