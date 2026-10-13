# Exposure System（曝光系统）

[English](README.md) · **简体中文**

像人眼一样工作的相机自动曝光。它测量落在场景上的光，随时间适应，让夜晚比白天更暗，
并在暗光下让颜色褪去。它不依赖任何插件。

## 工作原理

- **入射光测光。** `ExposureController` 每帧从光源（例如 `SkySystem`）读取相机处的
  照度（勒克斯），并选取合适的曝光，使这种光下 18% 的灰卡渲染为 0.18（白色表面为 1）。
  `exposure_compensation_ev` 在此基础上偏移。
- **适应。** 曝光随时间向目标值靠近。适应变亮（`brighten_seconds`）比适应变暗
  （`darken_seconds`）更快。
- **感知上的暗。** 在暗光下，人眼只会部分适应（Krawczyk 等，2005），所以黄昏和夜晚
  始终比白天暗。关闭 `perceptual_adaptation` 后，各种光照都会像相机那样被同等曝光。
- **适应画面**（`adapt_to_view`）。`ViewLuminanceEffect` 测量渲染画面的平均亮度。
  画面比测得的光更亮时（例如低空的太阳或月亮在雾霭中发光），曝光会进一步降低，就像
  人眼在眩光下那样。画面更暗时（海面、船体）不会提高曝光。
- **夜视**（`night_vision`）。`NightVisionEffect` 让暗处的像素褪向略带蓝色的灰，
  模拟视杆细胞接替视锥细胞。

结果只在运行时写入目标的 `CameraAttributes.exposure_multiplier`，由 Godot 应用到
灯光、自发光和天空上。上述两个效果会在运行时加入目标的合成器（Compositor），需要
`RenderingDevice`。

## 使用方法

1. 添加一个 `ExposureController` 节点。
2. 把 `light_source_path` 指向 `SkySystem`，或任何具有 `get_scene_illuminance()`
   （相机处的照度，单位勒克斯，未知时为负数）和 `get_illuminance_unit_lux()`
   （场景辐照度为 1 时对应的勒克斯数）的节点。
3. 把 `target_path` 指向 `WorldEnvironment` 或 `Camera3D`。相机自己的属性会覆盖
   世界的属性，所以如果相机有自己的属性，就以相机为目标。没有属性的目标会得到一个
   `CameraAttributesPractical`。
4. 保持物理灯光单位关闭，不要再开启另一个自动曝光。

设置：`exposure_compensation_ev`、`perceptual_adaptation`、`brighten_seconds`、
`darken_seconds`、`night_vision`、`night_vision_strength`、`adapt_to_view`。
`get_adapted_illuminance()` 返回眼睛当前适应的照度（勒克斯）。
