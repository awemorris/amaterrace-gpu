#version 450
// Writes every varying component (locations 0-15: the 64 of Vulkan 1.0's limit) besides the position.
layout(location = 0) in vec4 position;
layout(location = 1) in vec3 normal;
layout(location = 0) out vec4 v0;
layout(location = 1) out vec4 v1;
layout(location = 2) out vec4 v2;
layout(location = 3) out vec4 v3;
layout(location = 4) out vec4 v4;
layout(location = 5) out vec4 v5;
layout(location = 6) out vec4 v6;
layout(location = 7) out vec4 v7;
layout(location = 8) out vec4 v8;
layout(location = 9) out vec4 v9;
layout(location = 10) out vec4 v10;
layout(location = 11) out vec4 v11;
layout(location = 12) out vec4 v12;
layout(location = 13) out vec4 v13;
layout(location = 14) out vec4 v14;
layout(location = 15) out vec4 v15;
void main()
{
	gl_Position = position;
	v0 = position * 1.0 + vec4(0.0, normal);
	v1 = position * 2.0 + vec4(normal, 1.0);
	v2 = position * 3.0 + vec4(2.0, normal.zyx);
	v3 = position * 4.0 + vec4(normal.yzx, 3.0);
	v4 = position * 5.0 + vec4(4.0, normal);
	v5 = position * 6.0 + vec4(normal, 5.0);
	v6 = position * 7.0 + vec4(6.0, normal.zyx);
	v7 = position * 8.0 + vec4(normal.yzx, 7.0);
	v8 = position * 9.0 + vec4(8.0, normal);
	v9 = position * 10.0 + vec4(normal, 9.0);
	v10 = position * 11.0 + vec4(10.0, normal.zyx);
	v11 = position * 12.0 + vec4(normal.yzx, 11.0);
	v12 = position * 13.0 + vec4(12.0, normal);
	v13 = position * 14.0 + vec4(normal, 13.0);
	v14 = position * 15.0 + vec4(14.0, normal.zyx);
	v15 = position * 16.0 + vec4(normal.yzx, 15.0);
}
