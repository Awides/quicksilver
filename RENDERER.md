# Quicksilver Shell Renderer

## Overview

The renderer is a **WGPU-based MSDF text renderer** with dynamic background and effects, written in Zig. It displays user-editable text using multi-channel signed distance fields (MSDF) for high-quality, resolution-independent text, set against an animated lava-lamp background. Fonts are pre-generated and embedded directly into the binary.

### Key Features

- **MSDF font rendering**: Crisp edges at any scale using distance fields.
- **Embedded atlases**: No runtime font baking; atlas data compiled into the executable via `@embedFile`.
- **Animated background**: Full-screen gradient + drifting metaballs (lava lamp effect).
- **Viscosity**: Text vertices distort in response to nearby blobs, simulating fluid motion.
- **Glow effect**: Distance-field based glow around the text.
- **Continuous animation**: Text floats, scales, and interacts with background.
- **Fullscreen toggle**: Press F11 to enter/exit fullscreen; starts in fullscreen.
- **Edge‑triggered input**: Number keys insert characters, up/down cycle fonts, left/right switch demos, backspace deletes. Debounced to avoid repeat.
- **Height constraint**: Text scales to fit within 50% of viewport height.
- **Windows & Linux support**: Uses GLFW for windowing and WGPU for graphics.

## Directory Layout

```
hades/
  main.zig              # entry point
  renderer/             # renderer subsystem
    splash.zig          # application loop, input handling
    renderer.zig        # WGPU init, pipelines, rendering
    render_types.zig    # shared types (AppUniforms, Vertex, FontInfo, Blob, Vec2)
    font_atlas.zig      # embedded atlas loader
    shaders.zig         # embedded WGSL shader sources
    demos.zig           # demo parameters and blob generation
    demos/              # demo effect implementations
      splash.zig
      drippy.zig
    embedded/           # .atlas files (Iosevka-Thin, Heavy, Aile-Regular, Aile-SemiBold)
```

## Rendering Pipeline

### 1. Embedded Font Atlases

- Atlases are generated offline using `msdf-zig` and stored in `hades/embedded/` as `.atlas` binary files.
- `font_atlas.zig` loads these atlases at runtime with a simple header format (`"CLTA"` magic).
- Currently four atlases are embedded (Iosevka Thin, Heavy; Aile Regular, SemiBold; 2048×2048, 128px SDF, 3 channels).
- Each atlas provides glyph metrics and texture coordinates; pixels are uploaded to a 5‑layer texture array.

### 2. Vertex Generation

- For each character in the message, glyph data is looked up from the active font's atlas.
- Glyph metrics are scaled by `glyph_size_px` and converted to floating‑point positions.
- A 6‑vertex quad (two triangles) is generated per glyph with positions and UVs.
- Pen advances by the scaled advance; the bounding box is tracked.
- Geometry is uploaded to a vertex buffer. If the message is empty, no buffer is created and rendering is skipped.

### 3. Uniform Buffer (AppUniforms)

```
struct Vec2 { x: f32; y: f32; } align(8);
struct Blob { pos: Vec2; radius: f32; pad: f32; } align(8);
struct AppUniforms {
  resolution_x: f32;   // window width
  resolution_y: f32;   // window height
  center_x: f32;       // static text center X
  center_y: f32;       // static text center Y
  time: f32;           // elapsed seconds
  viscosity: f32;      // 0..1, strength of blob repulsion
  glow: f32;           // glow intensity
  phase: f32;          // gradient color phase offset
  base_scale: f32;     // multiplier to fit text to window
  font_layer: i32;     // texture array layer index
  pad1: f32;           // padding to 16‑byte boundary
  pad2: f32;           // padding to 16‑byte boundary
  blobs: [4]Blob;      // animated background blobs
}
```
The uniform buffer is aligned to 256 bytes for GPU requirements.

### 4. Background Pipeline

**Vertex Shader** (`bg.vert.wgsl`): full‑screen triangle via `vertex_index`.
**Fragment Shader** (`bg.frag.wgsl`):
- Slow‑cycling gradient: `0.5 + 0.5 * cos(time * 0.2 + phase + uv.xyx + vec3(0,2,4))`.
- **Metaballs**: 4 blobs with smooth edges, combined by maximum.
- Blends warm white blobs over the gradient.

### 5. Text Pipeline

**Vertex Shader** (`text.vert.wgsl`):
- Floating: center offset by `sin(time)`.
- Scale: entrance + breathing.
- **Viscosity**: for each blob, repel vertices within influence zone by `(1‑d/influence)*viscosity*40`.
- Transforms to NDC, passes UVs.

**Fragment Shader** (`text.frag.wgsl`):
- Sample MSDF texture → `d`.
- `alpha = smoothstep(0.5±width, d)`.
- **Glow**: `glow_width = 0.15 + glow*0.2`, `glow_factor = smoothstep(0.5±glow_width, d) * exp(-abs(d-0.5)/glow_width)`.
- Add `glow_color * glow_factor * glow` to white text.

### 6. Render Loop

- Update uniforms: time, blob positions (orbiting, varying radii), demo‑dependent viscosity/glow/phase.
- Single render pass:
  1. Clear to dark.
  2. Draw background (opaque).
  3. Draw text (alpha‑blended).
- If the message is empty, text draw call is skipped (no vertex buffer bound).

## Input Handling (splash.zig)

- **Char callback**: printable codepoints appended to a static 256‑codepoint buffer; rebuild geometry.
- **Key polling** (edge‑triggered):
  - `Backspace`: delete last character (rebuild).
  - `Up/Down`: cycle through available font layers.
  - `Left/Right`: switch between `Demo.splash` and `Demo.drippy`.
  - `F11`: toggle fullscreen; updates `windowed_state` and reconfigures surface.
- Fullscreen starts on launch using the primary monitor's video mode dimensions.

## Implementation Notes

- Zig 0.15.2 and `wgpu-native-zig` 6.5.0 are required.
- Boolean fields in wgpu structs use `@intFromBool(false)`.
- `std.mem.copy` replaced by `@memcpy`.
- `hash_map.deinit()` called without allocator.
- `surface.getCapabilities` uses the two‑argument signature.
- Vertex buffer and uniform buffer sizes are aligned properly.
- The `renderPassEncoder` ends before `finish`.

## Building

```bash
# Install Zig 0.15.2 and dependencies (see deps/)
tools/zig build -Dtarget=x86_64-windows-gnu   # cross‑compile for Windows
tools/zig build                               # native Linux build
```

The executable is `zig-out/bin/hades` (or `hades.exe`).

## Regenerating Atlases (Optional)

If you need to regenerate the atlases from source fonts, run `./download_fonts.sh` to fetch the required TTC files, then use `msdf-zig` tools. The embedded atlases are already committed; this step is only for font updates.

## License

[Your License Here]
