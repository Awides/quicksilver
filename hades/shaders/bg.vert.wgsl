struct VertexOutput {
  @builtin(position) position: vec4f,
};

@vertex
fn vs_main(@builtin(vertex_index) vertex_index: u32) -> VertexOutput {
  var pos = array<vec2f, 3>(
    vec2f(-1.0, -1.0),
    vec2f( 3.0, -1.0),
    vec2f(-1.0,  3.0)
  );
  return VertexOutput(vec4f(pos[vertex_index], 0.0, 1.0));
}
