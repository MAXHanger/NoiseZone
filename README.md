# Noise Zone — CRT Noise-Mask Shader for Godot 4

A `canvas_item` shader that renders a CRT-style effect confined to a black-and-white mask:
**turbulent mosaic + inner/outer glow + TV grain + screen refraction + turbulent dissolve**.

- This effect is inspired by the `Noisefield` in the game `phigros`; this shader aims to recreate it as faithfully as possible.

### TODO — Effects still to be optimized or added

1. The masked area should contain countless `tiny rectangular particles`, creating a chaotic, murky, glitchy feel. I've tried hash-based random generation and 3D-noise evolution along the Z axis to simulate the particles, but the result still isn't right.
2. The `scale ratio` doesn't seem right — the rectangle's distortion feels too weak, yet raising `displacement_scale` makes it chaotic instead. Not sure whether this is a window-size issue or a parameter issue.
3. The distortion method itself may be wrong — it could be the way the code warps the UVs, or it could be the `Noise Tex` texture.

- The code still needs refinement and optimization — feedback and criticism are welcome.

## Features

- Block-quantized ("mosaic") turbulence driven by a noise texture
- Soft **inner** and **outer** glow around the mask edges
- Selectable outline style: inner + outer 1 px (default), inner only, or outer only (`edge_mode`)
- CRT snow grain with configurable strength and refresh rate
- Screen-space refraction of the game view rendered beneath the node
- Turbulent dissolve that eats into the effect layer

## Requirements

- Godot **4.x** (4.2+ recommended)
- A 2D noise texture for the turbulence (e.g. `NoiseTexture2D` + `FastNoiseLite`)

## Quick Start

### 1. Draw the mask

1. Add a **`SubViewport`** node (e.g. `MaskView`) to your scene.
2. Set `transparent_bg = true` and give it the **same size** as the screen area you render to (otherwise the mask will stretch).
3. Set **Render Target → Update Mode = Always** (`render_target_update_mode = 4`). Without this, the mask may freeze at its first frame.
4. Add **`ColorRect`** children to paint the mask:
   - **White** — the effect is visible here.
   - **Black** — holes; the effect is discarded here.
   - Any area not covered by a rect is transparent and is treated as black (discarded).

### 2. Feed the mask into the shader

1. Add a **`TextureRect`** that covers the screen.
2. In its **Texture** slot, create a new **`ViewportTexture`** and set **Viewport Path** to the `MaskView` node (you can drag the SubViewport node into this property).
3. In **CanvasItem → Material**, create a new **`ShaderMaterial`** and load `noise_zone.gdshader`.
4. Assign the **`noise_tex`** parameter (a `NoiseTexture2D` built from `FastNoiseLite` works well). Without it the turbulence won't move.

### 3. Put the game view underneath

`screen_tex` uses `hint_screen_texture`, so the shader automatically captures everything rendered **beneath** the `TextureRect` in the same canvas/viewport. Keep your game content on nodes below it.

A ready-to-run example is provided in [`noise_show.tscn`](noise_show.tscn).

## How the mask works

- Only the mask's **red channel** is read and thresholded at `0.5`: white → inside, black / transparent → outside.
- Outside pixels are **discarded** (except the 1 px outline and the outer glow), so the effect never spills beyond the mask.
- Inside the mask, sampling is quantized into `block_size`-pixel mosaic blocks and displaced by the turbulence noise — this is what makes the edges boil.

## Parameters

| Name | Default | Range | Description |
|---|---|---|---|
| `block_color` | (0.5, 0.05, 0.05, 0.8) | color | Base color of the masked interior |
| `glow_color` | (1, 0.2, 0.2, 1) | color | Glow / outline color |
| `glow_intensity` | 2.0 | 1.0 – 5.0 | Glow brightness multiplier |
| `glow_width` | 8.0 | 0 – 32 | Glow width in pixels; `0` disables the glow |
| `glow_falloff` | 2.0 | 0.5 – 8.0 | Glow falloff exponent (larger = tighter falloff) |
| `glow_opacity` | 0.5 | 0 – 1 | Overall glow opacity |
| `edge_mode` | 0 | 0 – 2 | Outline style: `0` = inner + outer 1 px (default), `1` = inner edge only, `2` = outer edge only |
| `noise_tex` | — | texture | Turbulence noise texture (`NoiseTexture2D` recommended) |
| `evolution_speed` | 1.0 | — | Turbulence evolution speed |
| `turbulence_scale` | (2, 2) | vec2 | Noise sampling scale |
| `displacement_scale` | 0.04 | 0 – 1.2 | Edge displacement magnitude |
| `block_size` | 8.0 | 1 – 64 | Mosaic block size in pixels |
| `noise_grain_strength` | 0.35 | 0 – 3 | TV grain strength (0 = none, 1 = full static) |
| `noise_grain_speed` | 45.0 | 1 – 100 | Grain refresh rate in Hz (30 – 60 = CRT-like) |
| `noise_mode` | 0 | 0 – 1 | Grain sampling: `0` = raw UV (fine grain), `1` = block-quantized (blocky grain) |
| `screen_distortion_strength` | 0.035 | 0 – 5 | Refraction strength applied to the game view |
| `overlay_opacity` | 0.65 | 0 – 1 | Top-layer opacity (`0` = raw scene, `1` = full refraction) |
| `dissolve_threshold` | 0.45 | 0 – 1 | Dissolve threshold (how much area is eaten away) |
| `dissolve_contrast` | 0.15 | 0.01 – 5.5 | Dissolve contrast (smaller = softer edges) |
| `blend_mode` | 0 | 0 – 1 | Compositing: `0` = normal alpha blending, `1` = additive glow |
| `light_radius` | 400 | 0 – 2000 | `light()`: effective radius of 2D lights (px) |
| `light_falloff` | 2.0 | 0.5 – 5 | `light()`: attenuation exponent |
| `light_ambient` | 0.05 | 0 – 1 | `light()`: ambient floor |

## Notes & Tips

- **Performance**: the glow probes along 8 directions per pixel are the hot path. Keep `glow_width` modest (≤ 16) on large masks, or set it to `0` to skip the glow entirely.
- **Rotated masks**: because sampling is block-quantized, rotating a mask rectangle can weaken the edge turbulence on some edges. This is a known quirk of the mosaic approach.
- The `light_*` parameters only affect the `light()` function (i.e. how 2D lights illuminate the node).
- Large `block_size` values (32+) also make the glow look blocky, since the outline follows the block grid.

## License

CC0-1.0
