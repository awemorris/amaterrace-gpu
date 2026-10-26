#version 450
// Computes all sixteen varyings (the 64 components) before it writes any of them.
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
	vec4 t0 = position * 1.0 + vec4(normal, 0.0);
	vec4 t1 = position * 2.0 + vec4(normal.zyx, 1.0);
	vec4 t2 = position * 3.0 + vec4(normal.yzx, 2.0);
	vec4 t3 = position * 4.0 + vec4(normal.xzy, 3.0);
	vec4 t4 = position * 5.0 + vec4(normal, 4.0);
	vec4 t5 = position * 6.0 + vec4(normal.zyx, 5.0);
	vec4 t6 = position * 7.0 + vec4(normal.yzx, 6.0);
	vec4 t7 = position * 8.0 + vec4(normal.xzy, 7.0);
	vec4 t8 = position * 9.0 + vec4(normal, 8.0);
	vec4 t9 = position * 10.0 + vec4(normal.zyx, 9.0);
	vec4 t10 = position * 11.0 + vec4(normal.yzx, 10.0);
	vec4 t11 = position * 12.0 + vec4(normal.xzy, 11.0);
	vec4 t12 = position * 13.0 + vec4(normal, 12.0);
	vec4 t13 = position * 14.0 + vec4(normal.zyx, 13.0);
	vec4 t14 = position * 15.0 + vec4(normal.yzx, 14.0);
	vec4 t15 = position * 16.0 + vec4(normal.xzy, 15.0);
	gl_Position = position;
	v0 = t0;
	v1 = t1;
	v2 = t2;
	v3 = t3;
	v4 = t4;
	v5 = t5;
	v6 = t6;
	v7 = t7;
	v8 = t8;
	v9 = t9;
	v10 = t10;
	v11 = t11;
	v12 = t12;
	v13 = t13;
	v14 = t14;
	v15 = t15;
}
