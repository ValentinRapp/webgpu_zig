const std = @import("std");
const wgpu = @import("webgpu");
const mesh_handler = @import("mesh.zig");
const webgpu_utils = @import("webgpu.zig");
const texture_handler = @import("texture.zig");
const zm = @import("zm");

pub const Projection = struct {
    projection: zm.Mat4f,
    buffer: *wgpu.buffer.Buffer,

    pub fn createBasicModel(device: *wgpu.device.Device) Projection {
        var proj = Projection{
            .projection = zm.Mat4f.identity(),
            .buffer = undefined,
        };
        proj.buffer = webgpu_utils.createBuffer(
            device,
            f32,
            @as(*const [16]f32, @ptrCast(&proj.projection)),
            .{ .uniform = true, .copy_dst = true },
        );
        return proj;
    }
};

fn computeAABB(mesh: *const mesh_handler.Mesh) !zm.AABBf {
    const vertices = mesh.vertices;
    if (vertices.len < 3) return error.InvalidMesh;

    var aabb = zm.AABBf.init(
        .{ vertices[0], vertices[1], vertices[2] },
        .{ vertices[0], vertices[1], vertices[2] },
    );

    var i: usize = 3;
    while (i + 2 < vertices.len) : (i += 3) {
        const x = vertices[i];
        const y = vertices[i + 1];
        const z = vertices[i + 2];
        aabb.min = .{ @min(aabb.min[0], x), @min(aabb.min[1], y), @min(aabb.min[2], z) };
        aabb.max = .{ @max(aabb.max[0], x), @max(aabb.max[1], y), @max(aabb.max[2], z) };
    }
    return aabb;
}

fn updateBounds(bounds: *zm.AABBf, modelProj: zm.Mat4f) void {
    const modelT = modelProj;

    const corners = [8]zm.Vec4f{
        .{ bounds.min[0], bounds.min[1], bounds.min[2], 1.0 },
        .{ bounds.max[0], bounds.min[1], bounds.min[2], 1.0 },
        .{ bounds.min[0], bounds.max[1], bounds.min[2], 1.0 },
        .{ bounds.max[0], bounds.max[1], bounds.min[2], 1.0 },
        .{ bounds.min[0], bounds.min[1], bounds.max[2], 1.0 },
        .{ bounds.max[0], bounds.min[1], bounds.max[2], 1.0 },
        .{ bounds.min[0], bounds.max[1], bounds.max[2], 1.0 },
        .{ bounds.max[0], bounds.max[1], bounds.max[2], 1.0 },
    };

    // Transform first corner to initialize new min/max
    const first = zm.Mat4f.multiplyVec4(modelT, corners[0]);
    var newMin = zm.Vec3f{ first[0], first[1], first[2] };
    var newMax = newMin;

    // Transform the other corners and update min/max
    for (corners[1..]) |corner| {
        const transformed = zm.Mat4f.multiplyVec4(modelT, corner);
        newMin = .{
            @min(newMin[0], transformed[0]),
            @min(newMin[1], transformed[1]),
            @min(newMin[2], transformed[2]),
        };
        newMax = .{
            @max(newMax[0], transformed[0]),
            @max(newMax[1], transformed[1]),
            @max(newMax[2], transformed[2]),
        };
    }

    bounds.min = newMin;
    bounds.max = newMax;
}

pub const Model = struct {
    mesh: mesh_handler.WgpuMesh,

    model_proj: Projection,

    bind_groups: [2]*wgpu.bind_group.BindGroup,

    pipeline: *wgpu.render_pipeline.RenderPipeline,

    bounds: zm.AABBf,

    pub fn draw(self: *Model, render_pass: *wgpu.render_pass_encoder.RenderPassEncoder) void {
        render_pass.setVertexBuffer(0, self.mesh.vertex_buffer, 0, self.mesh.vertex_buffer.size());
        render_pass.setIndexBuffer(self.mesh.index_buffer, .uint16, 0, self.mesh.index_buffer.size());
        render_pass.drawIndexed(@intCast(self.mesh.mesh.indices.len), 1, 0, 0, 0);
    }

    pub fn getPos(self: *const Model) zm.Vec3f {
        return zm.Vec3f{
            self.model_proj.projection.data[3],
            self.model_proj.projection.data[7],
            self.model_proj.projection.data[11],
        };
    }

    pub fn create(
        mesh: mesh_handler.WgpuMesh,
        proj_matrices: [3]Projection,
        pipeline: *wgpu.render_pipeline.RenderPipeline,
        proj_bind_group: *wgpu.bind_group.BindGroup,
        textures_bind_group: *wgpu.bind_group.BindGroup,
    ) !Model {
        var bounds = try computeAABB(&mesh.mesh);
        updateBounds(&bounds, proj_matrices[2].projection);

        return Model{
            .mesh = mesh,
            .model_proj = proj_matrices[2],
            .bind_groups = .{ proj_bind_group, textures_bind_group },
            .pipeline = pipeline,
            .bounds = bounds,
        };
    }

    pub fn destroy(self: *Model) void {
        for (self.bind_groups) |bind_group| {
            bind_group.release();
        }
    }
};
