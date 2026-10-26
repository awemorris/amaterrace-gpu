#version 450
// Writes the last varying words (locations 13-15: words 52-63 of Vulkan 1.0's 64 components).
layout(location = 0) in vec4 position;
layout(location = 1) in vec3 normal;
layout(location = 13) out vec4 v13;
layout(location = 14) out vec4 v14;
layout(location = 15) out vec4 v15;
void main()
{
	gl_Position = position;
	v13 = position * 14.0 + vec4(13.0, normal);
	v14 = position * 15.0 + vec4(normal, 14.0);
	v15 = position * 16.0 + vec4(15.0, normal.zyx);
}
