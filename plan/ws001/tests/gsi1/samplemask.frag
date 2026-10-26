#version 450
// The sample mask in and out, and a centroid input.
layout(location = 0) centroid in vec4 colour;
layout(location = 0) out vec4 result;
void main()
{
	result = colour;
	gl_SampleMask[0] = gl_SampleMaskIn[0] & (colour.x > 0.0 ? 0x5 : 0xa);
}
