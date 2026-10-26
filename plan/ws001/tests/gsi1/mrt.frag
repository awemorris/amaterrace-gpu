#version 450
// Four colour attachments.
layout(location = 0) in vec4 colour;
layout(location = 0) out vec4 out0;
layout(location = 1) out vec4 out1;
layout(location = 2) out vec2 out2;
layout(location = 3) out float out3;
void main()
{
	out0 = colour;
	out1 = colour.wzyx;
	out2 = colour.xy * 2.0;
	out3 = colour.z;
}
