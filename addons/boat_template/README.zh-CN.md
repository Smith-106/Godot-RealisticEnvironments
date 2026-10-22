# Boat Template（船只模板）

[English](README.md) · **简体中文**

`boat.tscn` 是一艘已经接好系统的船：驾驶、受击生命值和相机锚点。要做一艘船，从它创建
一个**继承场景**。

> **正在重写。** 浮力正在从头重做，所以模板的刚体被冻结（`freeze = true`），暂时不会
> 漂浮。

需要 `core` 和 `hitbox_damage_system`。启用后，插件会把驾驶动作 `boat_forward`、
`boat_back`、`boat_turn_left` 和 `boat_turn_right`（W S A D）加入项目（已存在的不会
改动）。

## 工作原理

```
Boat (RigidBody3D, FloatingBoat)   drive input, model animation
├─ CollisionShape3D           placeholder box: replace it
├─ Hitboxes                   HitboxHealthManager (one "hull" group, 100 HP)
└─ CameraTargets/ThirdPersonFocus, FirstPersonSeat
```

- **`FloatingBoat`**（根节点）在 `player_controlled` 打开时推动船前进并转向。速度超过
  `max_forward_speed` / `max_reverse_speed` 后不再加推力，低速时转向变弱。
- 生命值来自 `hitbox_damage_system`（见它的 README）。

## 使用方法

1. 通过 **场景 > 新建继承场景** 从 `boat.tscn` 创建场景，加入你的模型，船头朝 −Z。
2. 替换碰撞形状，设置船真实的 `mass` 和 `center_of_mass`。
3. 在 `Hitboxes` 下添加 `ProjectileHitbox` 区域，并在 `group_max_health` 中列出它们的
   分组。
4. 把 `CameraTargets/*` 移到甲板上。
5. 可选：`animation_player_path` 和 `autoplay_animation` 用来循环播放模型动画
   （例如船帆）。
6. 在玩家驾驶的船上打开 `player_controlled`。

请保持模板中节点的名称和顺序不变，继承它的场景是按路径覆盖节点的。
