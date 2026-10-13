# Buoyancy System（浮力系统）

[English](README.md) · **简体中文**

让 `RigidBody3D` 漂浮在水面上。探针在编辑器中根据船体生成，每个物理帧采样一次水面。
它还提供接触水面的事件和沉没功能。

需要 `core` 插件，以及注册了 `WaterSurface` 的水体（例如 `ocean_system`）。

## 工作原理

- **探针。** `BuoyancyProbeVolume` 保存物体的探针。物理探针（`BuoyancyProbeNode`）
  是一根竖直水柱的顶端，带有 `volume`（体积）和 `buoyancy_height`（水柱高度）。
  接触探针（`BuoyancyFxProbeNode`）只报告自己是否在水中。在编辑器中，探针体积在设计
  水线处切开船体网格，并用探针填满切出的轮廓。探针随场景保存，运行时从不生成。
- **采样。** `BuoyantBody` 每个物理帧把所有探针的位置作为一次水面查询提交（见 `core`
  的 `WaterSurface`），并根据外推到当前时刻的最新结果施加力。第一个结果到达之前，
  物体保持冻结。
- **受力。** 每根水柱受到的向上浮力等于它排开的水的重量。每根水柱还受到相对于流动的
  水的阻力：沿物体三个轴的二次阻力、穿过水面时的阻尼（上下起伏的物体以波浪形式辐射
  出去的能量），以及垂荡方向的附加质量。每个物理帧，所有力合成为一个力和一个力矩。
- **接触状态。** 每个探针都有一个 `BuoyancyProbeState`（深度、浸没比例、带滞回的
  干湿状态、它施加的力、水面法线和水的速度）。探针穿过水面时会发出入水和出水信号。
- **沉没**（可选）。物体横摇过大、指定的探针被淹没，或某个受损分组被摧毁时，物体开始
  沉没。沉没会降低浮力、发出信号，并在延迟后释放物体。

## 使用方法

```
RigidBody3D
├─ CollisionShape3D
├─ <船体模型>
├─ BuoyantBody             施加力；可选的沉没
└─ BuoyancyProbeVolume     source_paths → 船体模型
   └─ GeneratedProbes      生成的探针
```

1. 在刚体下添加 `BuoyantBody`。它会自己找到最近的 `RigidBody3D` 祖先节点和水面。
2. 添加 `BuoyancyProbeVolume` 并设置：
   - `source_paths`：船体网格；
   - `design_waterline_y`：船体应该浮在的高度（局部坐标）；
   - `physical_probe_count` 和 `fx_probe_count`；
   - **New Probes**：`generated_probe_volume`、水柱高度和
     `generated_probe_freeboard`。干舷（freeboard）是甲板高出水线的高度，这样
     高过水线的浪仍然能托起船体。
3. 点击 **Generate All Probes** 并保存场景。探针是普通节点，可以随意移动、删除或复制。
4. 在 `BuoyantBody` 上调整 `buoyancy_strength` 和各阻力系数（流线型船体的
   `longitudinal_drag_coefficient` 应较低，约 0.05）。

所有探针完全浸没时提供的浮力应明显大于物体的重量（质量 ÷ 水的密度；演示场景中的划艇
是 2.4 倍）。如果碰撞形状被非均匀缩放，需要显式设置刚体的 `inertia`，否则它无法纵摇
或横摇。在探针体积上打开 `debug_enabled` 可以看到探针、水线和受力。

### 接触事件和探针状态

- 信号：`probe_entered_water(state)`、`probe_exited_water(state)`。
- `get_probe_states(tag)`、`get_wet_probe_states(tag)`、`get_probe_state(probe)`。
  生成的接触探针带有 `bow`、`side` 或 `stern` 标签（船头、船侧、船尾）。
- 运行时添加或删除探针体积后，调用 `refresh_volumes()`。
- `apply_forces = false` 会把物体交还给普通物理。

### 沉没

打开 `sinking_enabled` 并选择触发条件：`max_roll_degrees`、`sinking_probe_paths`
配合 `sink_probe_depth_threshold`，以及 `sink_on_destroyed_groups`。要在受损时沉没，
请在场景中把 `HitboxHealthManager.group_destroyed`（或参数相同的自定义信号）连接到
`BuoyantBody._on_hitbox_group_destroyed`。沉没时浮力乘以 `sink_buoyancy_multiplier`，
发出 `sinking_started(reason, data)`，并在 `delete_delay` 秒后释放 `delete_root_path`。
在代码中可以调用 `start_sinking()` 和 `is_sinking()`。
