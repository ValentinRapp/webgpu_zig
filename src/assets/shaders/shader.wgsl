struct VertexIn {
    @location(0) position : vec3f,
    @location(1) normal: vec3f,
    @location(2) texcoord: vec2f,
}

struct VertexOut {
    @builtin(position) position : vec4f,
    @location(1) normal: vec3f,
    @location(2) texcoord: vec2f,
}

@group(0) @binding(0)
var<uniform> proj : mat4x4f;
@group(0) @binding(1)
var<uniform> view : mat4x4f;
@group(0) @binding(2)
var<uniform> model : mat4x4f;

@vertex
fn vs_main(
    in: VertexIn
) -> VertexOut {
    let proj_t = transpose(proj);
    let view_t = transpose(view);
    let model_t = transpose(model);
    let mvp = proj_t * view_t * model_t;
    return VertexOut(
        mvp * vec4f(in.position, 1.0),
        in.normal,
        in.texcoord
    );
}

@group(1) @binding(0) var mySampler: sampler;
@group(1) @binding(1) var albedo: texture_2d<f32>;
@group(1) @binding(2) var lightmap: texture_2d<f32>;

@fragment
fn fs_static(
    fragData: VertexOut
) -> @location(0) vec4f {
    return textureSample(albedo, mySampler, fragData.texcoord) *
        textureSample(lightmap, mySampler, fragData.texcoord);
}

@fragment
fn fs_unlit(
    fragData: VertexOut
) -> @location(0) vec4f {
    return textureSample(albedo, mySampler, fragData.texcoord);
    // return vec4f(fragData.normal, 1.0);
}
