# Buoyancy System（浮力系统）

[English](README.md) · **简体中文**

让 `RigidBody3D` 漂浮在水面上。在编辑器中，船体网格被烘焙成测量其形状的水柱。所有物理
力都来自这个形状、物体的质量和水，因此没有需要调节的参数：船体按它的几何形状浮起、
纵倾、横摇和减速。它还提供接触水面的事件和沉没功能。

需要 `core` 插件，以及注册了 `WaterSurface` 的水体（例如 `ocean_system`）。

## 工作原理

- **烘焙。** `BuoyancyProbeVolume` 在许多高度上切开船体。在每个高度上，开阔的水从侧面
  无法到达的部分都会排开水：实心部分，以及船体侧壁围住的空气（敞口船舷缘以下的内部），
  但不包括水能从中流过的格架塔。一组水柱（`BuoyancyProbeNode`）铺满船体的平面投影，
  每根水柱记录它在每个高度上的横截面积（`area_profile`）和它所属的船体侧面及其真实的
  外法线（`side_panels`）。接触探针（`BuoyancyFxProbeNode`）放在物体实际漂浮的水线上。
  探针随场景保存，运行时从不生成。
- **报告。** 探针体积的配置警告会根据物体的质量和重心，计算它在平静水面上如何漂浮：
  会沉没、浮起时横倾或纵倾（并指出重心应放在哪里）、几乎没有干舷，或正浮不稳定（稳心
  高度为负）时发出警告。点击 **Generate** 会打印完整摘要：吃水、干舷、储备浮力、稳心
  高度、横倾和纵倾。
- **采样。** `BuoyantBody` 每个物理帧把所有探针的位置作为一次水面查询提交（见 `core`
  的 `WaterSurface`），并根据外推到当前时刻的最新结果施加力。第一个结果到达之前，物体
  保持冻结（最多 5 秒）。
- **受力**，每根水柱相对于流动的水计算，最后合成为一个力和一个力矩：
  - 浮力：浸没部分排开的水的重量，作用在该部分的形心；
  - 迎水面的压差阻力 ½·ρ·C·A·u²，u 是沿该面法线的速度，C 取平板的 1。尖细的船头斜着
    迎水，阻力很小；平直的侧面阻力很大：船向前滑行，侧向则被水"抓住"；
  - 船体升力：以小漂角运动的船体相当于展弦比为 2·吃水 / 船长的机翼，侧向力为
    (π/2)·ρ·T²·U·v（细长体理论）——吃水深的船体和龙骨抓水，平底船会侧滑；
  - 浸湿面积上的摩擦阻力（ITTC 1957 曲线）；
  - 水柱穿过水面时的兴波阻尼（`wave_damping_ratio`，上下起伏的物体以波浪形式辐射出去
    的能量）；
  - 垂荡附加质量：把水线面当作水面上的平板，取与其长度和面积相同的椭圆的三维精确解。
- **接触状态。** 每个探针都有一个 `BuoyancyProbeState`（深度、浸没比例、带滞回的
  干湿状态、它施加的力、水面法线和水的速度）。探针穿过水面时会发出入水和出水信号。
- **沉没**（可选）。物体横摇过大、指定的探针被淹没，或某个受损分组被摧毁时，物体开始
  沉没。沉没会降低浮力、发出信号，并在延迟后释放物体。

## 使用方法

```
RigidBody3D                mass、center_of_mass（自定义）、碰撞形状
├─ <船体模型>
├─ BuoyantBody             施加力；可选的沉没
└─ BuoyancyProbeVolume     source_paths → 船体模型
   └─ GeneratedProbes      烘焙出的探针
```

1. 给刚体设置真实的 `mass`。船还要设置自定义的 `center_of_mass`（货物和压舱物在低处）。
   如果碰撞形状被非均匀缩放，需要显式设置 `inertia`，否则它无法纵摇或横摇。
2. 在刚体下添加 `BuoyantBody`。它会自己找到最近的 `RigidBody3D` 祖先节点和水面。
3. 添加 `BuoyancyProbeVolume`，把 `source_paths` 设为船体网格；如果上层建筑会进水，
   把 `watertight_top_y` 设为甲板高度。
4. 点击 **Generate All Probes** 并保存场景。阅读它打印的摘要和探针体积的警告：如果物体
   浮起时是倾斜的，按警告把 `center_of_mass` 移到指定位置。

`physical_probe_count`（约 24）决定水柱贴合船体的精细程度，`fx_probe_count` 决定沿水线
放置多少个接触探针。`water_density` 海水为 1025，淡水为 1000。修改船体后要重新烘焙；
`tools/bake_buoyancy_probes.gd` 可以在命令行中重新烘焙场景。在探针体积上打开
`debug_enabled` 可以看到探针、水线和受力。

### 接触事件和探针状态

- 信号：`probe_entered_water(state)`、`probe_exited_water(state)`。
- `get_probe_states(tag)`、`get_wet_probe_states(tag)`、`get_probe_state(probe)`。
  生成的接触探针带有 `bow`、`side` 或 `stern` 标签（船头、船侧、船尾）。
- 运行时添加或删除探针体积后，调用 `refresh_volumes()`。
- `apply_forces = false` 会把物体交还给普通物理。

### 沉没

打开 `sinking_enabled` 并选择触发条件：`max_roll_degrees`、`sinking_probe_paths`
（这些物理探针的水柱都至少有 `sink_submersion_threshold` 浸在水下）以及
`sink_on_destroyed_groups`。要在受损时沉没，请在场景中把
`HitboxHealthManager.group_destroyed`（或参数相同的自定义信号）连接到
`BuoyantBody._on_hitbox_group_destroyed`。沉没时浮力乘以 `sink_buoyancy_multiplier`，
发出 `sinking_started(reason, data)`，并在 `delete_delay` 秒后释放 `delete_root_path`。
在代码中可以调用 `start_sinking()` 和 `is_sinking()`。
