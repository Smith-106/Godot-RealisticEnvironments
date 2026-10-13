# Boat Template（船只模板）

[English](README.md) · **简体中文**

`boat.tscn` 是一艘已经接好所有系统的船：驾驶、稳定性、浮力和沉没、受击生命值、船体
挖空和尾迹、船头浪花，以及相机锚点。要做一艘船，从它创建一个**继承场景**。

需要 `core`、`ocean_system`、`sky_system`（浪花使用它的大气雾霭）、`buoyancy_system`
和 `hitbox_damage_system`。启用后，插件会把驾驶动作 `boat_forward`、`boat_back`、
`boat_turn_left` 和 `boat_turn_right`（W S A D）加入项目（已存在的不会改动）。

## 工作原理

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

- **`FloatingBoat`**（根节点）在 `player_controlled` 打开时推动船前进并转向。速度超过
  `max_forward_speed` / `max_reverse_speed` 后不再加推力，低速时转向变弱。可选的分轴
  角阻尼和横摇回正弹簧用来增加稳定性。不受玩家控制的船照样漂浮、受伤、沉没并激起尾迹。
- 浮力、生命值和尾迹来自其他插件的节点（见它们的 README）。`hull` 分组被摧毁时，
  船会沉没。
- **`BowSpray`** 读取船艏柱处的水面。船艏切开水面时，它甩出一片片水滴；船头猛地扎进
  浪里时，它喷出水柱，在水面上加入一圈水花波纹，并发出
  `slammed(impact_speed, position)` 信号。

## 使用方法

1. 通过 **场景 > 新建继承场景** 从 `boat.tscn` 创建场景，加入你的模型，船头朝 −Z。
2. 替换碰撞形状，设置 `mass` 和 `center_of_mass`。
3. 在 `BuoyancyProbeVolume` 上设置 `source_paths`、`design_waterline_y` 和探针尺寸，
   点击 **Generate All Probes**，然后保存（见 `buoyancy_system`）。
4. 在 `HullWaterFootprint` 上把 `bake_source_paths` 设为只包含船体，点击
   **Bake Profile**，然后保存（见 `ocean_system`）。
5. 在 `Hitboxes` 下添加 `ProjectileHitbox` 区域，并在 `group_max_health` 中列出它们的
   分组。如果失去某个分组应该让船沉没，就把它加入
   `BuoyantBody.sink_on_destroyed_groups`。
6. 把 `CameraTargets/*` 移到甲板上，把 `BowSpray` 移到船艏柱处、水线略下方。把
   `emission_half_width` 设为船头宽度的一半左右；大船要调大 `particle_size`。
7. 可选：`animation_player_path` 和 `autoplay_animation` 用来循环播放模型动画
   （例如船帆）。
8. 在玩家驾驶的船上打开 `player_controlled`。

请保持模板中节点的名称和顺序不变，继承它的场景是按路径覆盖节点的。
