#version 450
// Attributes to the position, a varying and the point size.
layout(location = 0) in vec4 position;
layout(location = 1) in vec3 normal;
layout(location = 0) out vec4 colour;
layout(location = 1) out vec2 extra;
layout(push_constant) uniform Push { float scale; } push;
void main()
{
	gl_Position = position * vec4(2.0, 2.0, 1.0, 1.0);
	colour = vec4(normal, 1.0) * dot(normal, normal);
	extra = vec2(float(gl_VertexIndex), float(gl_InstanceIndex));
	gl_PointSize = 1.0;
}
