# Wind System

A tiny wind provider node. The ocean and the clouds read it; anything else can
too. No dependencies.

Add a `WindSystem` node and point `OceanSystem.wind_source_path` (and
`SkySystem.cloud_wind_source_path`) at it.

Exports: `wind_speed` (m/s), `wind_direction` (degrees the wind blows toward,
0 = +Z, 90 = +X), `gust_strength` (extra m/s), `gust_frequency` (cycles/s).
Gusts only run at runtime.

Methods: `get_wind_speed()` (gusts included), `get_wind_direction_degrees()`,
`get_wind_vector_2d()`, `get_wind_vector_3d()`. Signal `wind_changed` fires
when an export changes (not on every gust).

**Your own wind:** any node with `get_wind_speed()` and
`get_wind_direction_degrees()` (or `wind_speed` / `wind_direction`
properties) can replace it. `core`'s `WindSource` reads such a node.
