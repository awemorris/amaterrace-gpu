#version 450
// Reads the 16 input locations: the 64 varying components of Vulkan 1.0's limit.
layout(location = 0) in vec4 v0;
layout(location = 1) in vec4 v1;
layout(location = 2) in vec4 v2;
layout(location = 3) in vec4 v3;
layout(location = 4) in vec4 v4;
layout(location = 5) in vec4 v5;
layout(location = 6) in vec4 v6;
layout(location = 7) in vec4 v7;
layout(location = 8) in vec4 v8;
layout(location = 9) in vec4 v9;
layout(location = 10) in vec4 v10;
layout(location = 11) in vec4 v11;
layout(location = 12) in vec4 v12;
layout(location = 13) in vec4 v13;
layout(location = 14) in vec4 v14;
layout(location = 15) in vec4 v15;
layout(location = 0) out vec4 result;
void main()
{
	result = v0 * 1.0 +
		v1 * 2.0 +
		v2 * 3.0 +
		v3 * 4.0 +
		v4 * 5.0 +
		v5 * 1.0 +
		v6 * 2.0 +
		v7 * 3.0 +
		v8 * 4.0 +
		v9 * 5.0 +
		v10 * 1.0 +
		v11 * 2.0 +
		v12 * 3.0 +
		v13 * 4.0 +
		v14 * 5.0 +
		v15 * 1.0;
}
