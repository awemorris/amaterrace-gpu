#version 450
// A discard in a loop and a depth written.
layout(location = 0) in vec4 colour;
layout(location = 0) out vec4 result;
void main()
{
	float s = 0.0;
	for (int k = 0; k < int(abs(colour.x) * 4.0); k++)
		s += colour.y * float(k);
	if (s > 1.0)
		discard;
	result = vec4(s, colour.zw, 1.0);
	gl_FragDepth = clamp(colour.w * 0.25 + 0.5, 0.0, 1.0);
}
