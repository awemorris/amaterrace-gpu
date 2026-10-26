#version 450
// Differences across the quad, coarse and fine.
layout(location = 0) in vec4 colour;
layout(location = 0) out vec4 result;
void main()
{
	result = vec4(dFdx(colour.x), dFdy(colour.y), dFdxFine(colour.z), dFdyFine(colour.w)) + fwidth(colour.xyxy);
}
