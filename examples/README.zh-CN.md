# 示例

[English](README.md) · **简体中文**

只使用开源插件的小场景。打开其中一个，点击 **运行当前场景**（F6）。每个示例都以
`ocean_environment.tscn` 为基础。相机直接读取鼠标和键盘，不需要配置输入动作。

| 场景 | 内容 | 操作 |
| --- | --- | --- |
| `ocean_only.tscn` | 拿来即用的环境：天空、云、风和海浪。 | 按住鼠标右键环顾；W A S D 飞行，Q / E 下降 / 上升，Shift 加速，滚轮调整速度。 |
| `floating_objects.tscn` | 靠探针浮力漂浮的箱子和木桶。 | 同上。 |
| `boat.tscn` | 一艘可驾驶的船，带尾迹、船头浪花和船体挖空，另有两个箱子。 | W A S D 驾驶；按住鼠标右键环绕，滚轮缩放。 |

要修改时间、天气或海浪，选中 `OceanEnvironment`，右键打开 **子节点可编辑**，然后编辑
`SkySystem`、`WindSystem` 或 `Ocean`。

## 制作方法

**漂浮物。** `crate.tscn` 和 `barrel.tscn` 都是一个 `RigidBody3D`（质量、网格、碰撞
形状），带有 `BuoyantBody` 和 `BuoyancyProbeVolume`。探针体积的 `source_paths` 指向
网格，探针由 **Generate All Probes** 根据网格烘焙，并随场景保存。物体排开的水与它自身
一样重时达到平衡：250 千克、1 立方米的箱子有四分之一浸在水中。这么轻的立方体平面朝上
并不稳定，所以会像真实的箱子一样翻到一条棱上。

**船。** `simple_boat.tscn` 是 `addons/boat_template/boat.tscn` 的继承场景：

1. `Model` 是 `assets/simple_hull.obj`，由 `tools/make_example_hull.py` 生成
   （船头朝 −Z）。
2. 根节点设置 `mass`、`center_of_mass`（位于船体浮心上方，由探针体积的警告给出）以及
   驾驶参数。`CollisionShape3D`
   使用由网格生成的凸形状。
3. `BuoyancyProbeVolume`：`source_paths` → `Model`，然后
   **Generate All Probes**。
4. `HullWaterFootprint`：`bake_source_paths` → `Model`，然后 **Bake Profile**
   （保存为 `simple_boat_hull_profile.tres`）。
5. 把 `CameraTargets` 移到船上。

`boat.tscn` 为它驾驶的船打开了 `player_controlled`。W A S D 动作由 Boat Template
插件添加。
