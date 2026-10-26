#version 450
// A multisampled array fetched by sample, and a texel buffer's size.
layout(set = 0, binding = 0) uniform sampler2DMSArray samples;
layout(set = 0, binding = 1) uniform samplerBuffer texels;
layout(location = 0) out vec4 result;
void main()
{
	result = texelFetch(samples, ivec3(1, 2, 3), 1) + vec4(float(textureSize(texels)));
}
