#version 450
// A storage buffer read by a vertex program, at an index.
layout(location = 0) in vec4 position;
layout(std430, set = 0, binding = 0) readonly buffer In { vec4 offsets[]; } src;
void main()
{
	gl_Position = position + src.offsets[gl_VertexIndex & 15];
}
