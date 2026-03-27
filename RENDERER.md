# Quicksilver Shell Renderer

## Overview

The renderer is a **WGPU-based MSDF text renderer** with dynamic background and effects, written in Zig. It displays the string "HADES" using multi-channel signed distance fields (MSDF) for high-quality, resolution-independent text, set against an animated lava-lamp background. Fonts are loaded from Iosevka and Iosevka Aile families via a 2‑D texture array.

### Key Features

- **MSDF font rendering**: Crisp edges at any scale using distance fields.
- **Animated background**: Full-screen gradient + drifting metaballs (lava lamp effect).
- **Viscosity**: Text vertices distort in response to nearby blobs, simulating fluid motion.
- **Glow effect**: Distance-field based glow around the text.
- **Continuous animation**: Text floats, scales, and interacts with background.
- **Windows & Linux support**: Uses GLFW for windowing and WGPU for graphics.
- **Font caching**: Atlas cached to disk (`cache/`).
- **Texture array**: Up to 5 font layers (2048×2048 pixels each, currently layer 0 = Regular, layer 1 = Bold if available). The WGSL shader selects the layer via `uniforms.font_layer`.

## Architecture

```
+---------------------+
| Zig host (main.zig) |
+----------+----------+
            |
            | creates
            v
+-------------------------+      +------------------+
| WGPU Adapter/Device/Queue|----->| Texture, Sampler |
+-------------------------+      +------------------+
            |
            | uniform buffer (AppUniforms)
            v
+---------------------------+
| Two Render Pipelines      |
|  - Background (WGSL)      |
|  - Text (WGSL)            |
+---------------------------+
            |
            v
+---------------------+
| Surface (window)    |
+---------------------+
```

## Rendering Pipeline

### 1. Font Atlas Generation

- Uses **msdf-zig** to generate MSDF atlases for a set of fonts. The current configuration loads:
  - `fonts/Iosevka-Thin.ttc` (layer 0, weight 100)
  - `fonts/Iosevka-Heavy.ttc` (layer 1, weight 900)
  - `fonts/IosevkaAile-Regular.ttc` (layer 2, weight 400)
  - `fonts/IosevkaAile-SemiBold.ttc` (layer 3, weight 600)
- Atlas parameters:
  - Size: 2048×2048 pixels (per layer)
  - Glyph size: 36px
  - Padding: 4px
  - MSDF range: 8
- Atlases are cached in `cache/` with names like `Iosevka-Thin_2048x2048_36px_8rg.atlas`.
- Each font is uploaded to its own layer in a 5‑layer 2‑D texture array.
- The WGSL shader selects the active layer via `uniforms.font_layer`.
- The host code selects a default layer with the priority: Heavy (900) > Thin (100) > Aile‑SemiBold (600) > Aile‑Regular (400).
- The atlas produces 3-channel distance data (RGB) which is converted to RGBA for upload.

### 2. Vertex Generation

- For each character in the text string ("HADES"):
  - Look up glyph data (advance, bearing_x, bearing_y, width, height, texture coordinates).
  - Convert from EM units to pixels using `glyph_size_px`.
  - Construct a 6-vertex quad (two triangles) with positions and UVs.
  - Horizontal advance via scaled advance.
- Quids stored in a vertex buffer.
- The bounding box is computed to derive the static text center `(center_x, center_y)`.

### 3. Uniform Buffer (AppUniforms)

The uniform buffer is updated every frame and contains:

```
struct Vec2 { x: f32; y: f32; } align(8);
struct Blob { pos: Vec2; radius: f32; pad: f32; } align(8);
struct AppUniforms {
  resolution_x: f32;   // window width
  resolution_y: f32;   // window height
  center_x: f32;       // static text center X (original)
  center_y: f32;       // static text center Y
  time: f32;           // elapsed seconds
  viscosity: f32;      // 0..1, strength of blob repulsion
  glow: f32;           // glow intensity
  phase: f32;          // gradient color phase offset
  base_scale: f32;     // multiplier to fit text to window width
  font_layer: i32;     // texture array layer index
  pad1: f32;           // padding to align blobs
  pad2: f32;           // padding to align blobs
  blobs: [4]Blob;      // animated background blobs
}
```

Size: 112 bytes (matches WGSL std140 layout).

### 4. Background Pipeline

**Vertex Shader** (`bg.vert.wgsl`):
- Uses a full-screen triangle generated via `@builtin(vertex_index)`.
- No vertex buffer needed.

**Fragment Shader** (`bg.frag.wgsl`):
- Computes normalised screen coordinates `uv` from `frag_pos`.
- **Gradient**: `0.5 + 0.5 * cos(time * 0.2 + phase + uv.xyx + vec3(0,2,4))` – slow color cycling.
- **Metaballs**:
  - For each of 4 blobs, compute distance from fragment to blob center.
  - Soft edge using `smoothstep`.
  - Combine via `max` to get metaball merging.
- Blends a warm white blob color over the gradient.

### 5. Text Pipeline

**Vertex Shader** (`text.vert.wgsl`):
- **Text position animation**: Adds a sinusoidal offset to the static center to make the text float.
- **Scaling**: `scale = smoothstep(0..0.5, time) * (1 + 0.1 * sin(time * 2))` – entrance + continuous breathing.
- **Viscosity distortion**:
  - For each blob, compute distance from scaled vertex to blob.
  - If within `blob.radius + 80`, apply a repulsion force proportional to `(1 - d/influence) * viscosity * 40`.
  - Pushes vertices away, making text appear gooey around blobs.
- Convert to NDC and pass UVs.

**Fragment Shader** (`text.frag.wgsl`):
- Sample MSDF texture -> `d`.
- `alpha = smoothstep(0.5 ± width, d)` for edges.
- **Glow**:
  - `glow_width = 0.15 + glow * 0.2`
  - `glow_factor = smoothstep(0.5 ± glow_width, d) * exp(-abs(d-0.5)/glow_width)`
  - Add `glow_color * glow_factor * glow` to the white text color.
- Output `rgba(color, alpha)`.

### 6. Render Loop

- Update uniform buffer with time, computed blob positions (orbiting, varying radii), viscosity (sinusoidal), constant glow, and slowly increasing phase.
- Single render pass:
  1. Clear to dark color.
  2. Draw background (full-screen triangle, opaque).
  3. Draw text (alpha-blended).

## Current Status

- ✅ MSDF atlas generation with caching.
- ✅ Background: drifting metaballs, gradient color cycling.
- ✅ Text: floating, scaling, blob repulsion (viscosity), glow.
- ✅ Single-pass rendering with correct blending.
- ✅ Resize handling.
- ✅ **Multi‑font texture array**: Loads Iosevka (Thin, Heavy) and Iosevka Aile (Regular, SemiBold) into a 5‑layer texture array; selects active layer at runtime.
- ⚠️ **Baseline alignment**: baseline alignment may be off; currently using top-left reference for glyph placement.

## Known Issues

1. **Baseline alignment**: Glyphs might be vertically misaligned because `bearing_y` sign could be flipped. The current placement uses `baseline_y - bearing_y` (already corrected) but requires verification.
2. **Font coverage**: Some OTF/TTC fonts may lack required glyphs; atlas generation can fail and the font is skipped.

## Future Work

- [ ] Expose parameters (viscosity, glow intensity) via UI.
- [ ] Add more blob interactions (attraction, color variations).
- [ ] Add post-processing bloom (multi-pass).
- [ ] Interactive mouse influence on blobs.
- [ ] Expand to full "Hades" UI concept (Mercury agent, etc.).
- [ ] Support runtime font switching via messages.
