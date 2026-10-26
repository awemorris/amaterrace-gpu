#version 450
// Every kind of texture instruction GSI1 has.
layout(set = 0, binding = 0) uniform sampler2D plain;
layout(set = 0, binding = 1) uniform sampler2DArray layered;
layout(set = 0, binding = 2) uniform samplerCube cube;
layout(set = 0, binding = 3) uniform sampler3D volume;
layout(set = 0, binding = 4) uniform sampler2DShadow shadow;
layout(set = 0, binding = 5) uniform sampler2DMS samples;
layout(set = 0, binding = 6) uniform usamplerBuffer texels;
layout(location = 0) in vec4 uv;
layout(location = 0) out vec4 result;
void main()
{
	vec4 a = texture(plain, uv.xy) + texture(plain, uv.xy, 1.5) + textureLod(plain, uv.zw, 2.0);
	vec4 b = textureOffset(plain, uv.xy, ivec2(-1, 2)) + textureGather(plain, uv.xy, 2);
	vec4 c = texture(layered, vec3(uv.xy, 3.0)) + texture(cube, uv.xyz) + texture(volume, uv.xyz);
	float d = texture(shadow, vec3(uv.xy, 0.5)) + textureGrad(plain, uv.xy, vec2(0.01), vec2(0.02)).x;
	vec4 e = texelFetch(plain, ivec2(uv.xy * 16.0), 1) + texelFetch(samples, ivec2(3, 4), 2);
	ivec2 s = textureSize(plain, 1) + textureSize(layered, 0).xy;
	uint f = texelFetch(texels, int(uv.x * 100.0)).x;
	result = a + b + c + e + vec4(d, float(s.x + s.y), float(textureSamples(samples)), float(f + uint(textureQueryLevels(plain))));
}
