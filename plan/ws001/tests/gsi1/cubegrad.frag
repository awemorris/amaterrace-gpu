#version 450
// Gradients on a cube map and a 3D image, and a sample in a loop.
layout(set = 0, binding = 0) uniform samplerCube cube;
layout(set = 0, binding = 1) uniform sampler3D volume;
layout(location = 0) in vec4 uv;
layout(location = 0) out vec4 result;
void main()
{
	vec4 s = textureGrad(cube, uv.xyz, vec3(0.01), vec3(0.03)) + textureGrad(volume, uv.xyz, vec3(0.02), vec3(0.01));
	for (int k = 0; k < 3; k++)
		s += textureLod(volume, uv.xyz * float(k), float(k));
	result = s;
}
