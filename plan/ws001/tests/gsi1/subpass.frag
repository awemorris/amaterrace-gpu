#version 450
// An input attachment read at the fragment's pixel.
layout(input_attachment_index = 0, set = 0, binding = 0) uniform subpassInput previous;
layout(location = 0) out vec4 result;
void main()
{
	result = subpassLoad(previous) * 0.5 + vec4(0.125);
}
