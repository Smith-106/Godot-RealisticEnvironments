# Core（核心）

[English](README.md) · **简体中文**

海洋各插件共用的基础。它不依赖任何插件；`ocean_system`、`sky_system`、
`buoyancy_system` 和 `boat_template` 依赖它，请先启用它。

## 工作原理

各系统之间从不直接使用对方的类型。两个系统需要协作时，它们之间的约定放在这里：

| 类 | 作用 |
| --- | --- |
| `WaterSurface` | 水面约定。水体模拟（`OceanSystem`）为每个 `World3D` 注册一个；漂浮物、水花等通过 `WaterSurface.find(node)` 找到它。 |
| `WaterSurfaceQueryResult`、`WaterSurfaceSample` | 水面查询的结果：每个点的水面高度、法线、位移和水的速度。 |
| `WindSource` | 通过方法或属性读取任意风源（`WindSystem` 或你自己的节点）。 |
| `ProjectSetup` | 供各插件补充缺少的项目设置（全局着色器 uniform、输入动作），不改动已有设置。 |
| `RenderingContext` | 管理一个计算功能的 `RenderingDevice` 资源，统一释放并记录创建失败。 |
| `HullSlicer` | 编辑器中的网格切片工具，用于生成浮力探针和船体轮廓。 |

水面查询是异步的：所有使用者的查询点在 GPU 上一次批量采样，几帧之后才回读到 CPU。
因此结果总是稍旧一些，每个采样都可以把高度外推到当前时刻。

## 使用方法

### 读取水面高度

```gdscript
var _water : WaterSurface

func _ready() -> void:
	_water = WaterSurface.find(self)  # 这个世界里没有注册水面时为 null

func _physics_process(_delta : float) -> void:
	if _water == null:
		return
	_water.submit_query(self, PackedVector3Array([global_position]))  # 每个物理帧提交
	var result := _water.get_query_result(self)  # 第一次回读之前为 null
	if result != null and result.samples.size() == 1:
		var sample := result.samples[0]
		var height := sample.extrapolated_height(_water.get_query_age(result))
		# 还有 sample.normal、sample.surface_velocity 等

func _exit_tree() -> void:
	if _water != null:
		_water.release_query(self)
```

- 每个物理帧都提交；同一个查询者只保留最新一次提交。
- 一个结果对应的是它那次派发的点（`result.points`）。如果你改变了点的数量，
  请检查采样数。
- 始终用 `get_query_age(result)` 外推。

### 制造水花

```gdscript
if _water.can_add_impulses():
	_water.add_impulse(position, 1.5, 0.4)  # 半径和高度，单位为米
```

水面先隆起一个高斯形的鼓包，然后向外扩散成一圈波纹。

### 提供或读取风

风源是任何具有 `get_wind_speed()`（m/s）和 `get_wind_direction_degrees()`
方法的节点，或具有 `wind_speed` 和 `wind_direction` 属性的节点。方向是风吹向的
方向，单位为度：0 = +Z，90 = +X。读取风源请用 `WindSource.is_valid(node)`、
`get_speed(node)`、`get_direction(node)` 和 `get_velocity(node)`。

### 实现自己的水体

继承 `WaterSurface` 并实现它的抽象方法。在 `_enter_tree()` 中调用
`WaterSurface.register(get_world_3d(), surface)`，在 `_exit_tree()` 中调用
`unregister()`。每个世界只能有一个水面。
