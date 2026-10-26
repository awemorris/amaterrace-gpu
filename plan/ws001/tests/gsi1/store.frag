#version 450
// A storage buffer written by the fragments the primitive covers.
layout(location = 0) flat in uvec2 slot;
layout(std430, set = 0, binding = 0) buffer Out { uint r[]; } dst;
layout(location = 0) out vec4 result;
void main()
{
	uint i = uint(gl_FragCoord.x) + 8u * uint(gl_FragCoord.y);
	dst.r[i] = i * 3u + 1u;
	result = vec4(1.0);
}
