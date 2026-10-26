#version 450
// Smooth, flat and noperspective inputs, FragCoord and the front face.
layout(location = 0) in vec4 colour;
layout(location = 1) flat in vec2 tag;
layout(location = 2) noperspective in float line;
layout(location = 0) out vec4 result;
void main()
{
	result = colour * 0.5 + vec4(tag, line, 0.0);
	result.w += gl_FragCoord.x * 0.01 + gl_FragCoord.y * 0.02 + gl_FragCoord.z + gl_FragCoord.w;
	if (!gl_FrontFacing)
		result.x = 9.0;
}
