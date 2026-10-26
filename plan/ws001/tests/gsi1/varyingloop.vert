#version 450
// Writes varyings inside a loop whose length differs between lanes, and one again after it.
layout(location = 0) in vec4 position;
layout(location = 1) in vec3 normal;
layout(location = 0) out vec4 v0;
layout(location = 1) out vec4 v1;
layout(location = 2) out float v2;
void main()
{
	int count = int(abs(normal.x)) + 1;
	gl_Position = position;
	v0 = vec4(0.0);
	v1 = normal.xyzx;
	for (int i = 0; i < count; i++) {
		v0 += position * float(i + 1);
		v1.w = float(i) + normal.y;
	}
	v2 = float(count);
	v1.x = v0.x * 0.5;
}
