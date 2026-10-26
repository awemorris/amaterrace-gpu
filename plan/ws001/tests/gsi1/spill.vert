#version 450
// A chain of sixteen vec4 values, each made from the one before, and every varying made from
// its own and the last one: all sixteen are live at once, more than the registers hold.
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
	vec4 t0 = position * 0.5 + vec4(normal, 1.0);
	vec4 t1 = t0 * 0.75 + position.wzyx * 1.0;
	vec4 t2 = t1 * 0.75 + position.wzyx * 2.0;
	vec4 t3 = t2 * 0.75 + position.wzyx * 3.0;
	vec4 t4 = t3 * 0.75 + position.wzyx * 4.0;
	vec4 t5 = t4 * 0.75 + position.wzyx * 5.0;
	vec4 t6 = t5 * 0.75 + position.wzyx * 6.0;
	vec4 t7 = t6 * 0.75 + position.wzyx * 7.0;
	vec4 t8 = t7 * 0.75 + position.wzyx * 8.0;
	vec4 t9 = t8 * 0.75 + position.wzyx * 9.0;
	vec4 t10 = t9 * 0.75 + position.wzyx * 10.0;
	vec4 t11 = t10 * 0.75 + position.wzyx * 11.0;
	vec4 t12 = t11 * 0.75 + position.wzyx * 12.0;
	vec4 t13 = t12 * 0.75 + position.wzyx * 13.0;
	vec4 t14 = t13 * 0.75 + position.wzyx * 14.0;
	vec4 t15 = t14 * 0.75 + position.wzyx * 15.0;
	gl_Position = position;
	v0 = t0 - t15.wzyx * 0.0625;
	v1 = t1 - t15.wzyx * 0.0625;
	v2 = t2 - t15.wzyx * 0.0625;
	v3 = t3 - t15.wzyx * 0.0625;
	v4 = t4 - t15.wzyx * 0.0625;
	v5 = t5 - t15.wzyx * 0.0625;
	v6 = t6 - t15.wzyx * 0.0625;
	v7 = t7 - t15.wzyx * 0.0625;
	v8 = t8 - t15.wzyx * 0.0625;
	v9 = t9 - t15.wzyx * 0.0625;
	v10 = t10 - t15.wzyx * 0.0625;
	v11 = t11 - t15.wzyx * 0.0625;
	v12 = t12 - t15.wzyx * 0.0625;
	v13 = t13 - t15.wzyx * 0.0625;
	v14 = t14 - t15.wzyx * 0.0625;
	v15 = t15 - t15.wzyx * 0.0625;
}
