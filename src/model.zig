const std = @import("std");
const wgpu = @import("webgpu");
const mesh_handler = @import("mesh.zig");
const renderer_handler = @import("renderer.zig");
const texture_handler = @import("texture.zig");
const zm = @import("zm");

pub fn createProjectionsBindGroup(
    pipeline: *wgpu.render_pipeline.RenderPipeline,
    device: *wgpu.device.Device,
    comptime index: usize,
    matrices: [3]*wgpu.buffer.Buffer,
) *wgpu.bind_group.BindGroup {
    return renderer_handler.createBindGroup(
        pipeline,
        device,
        index,
        3,
        matrices,
        .{ zm.Mat4f, zm.Mat4f, zm.Mat4f },
    );
}

fn computeAABB(mesh: *const mesh_handler.Mesh) !zm.AABBf {
    const vertices = mesh.vertices;
    if (vertices.len < 3) return error.InvalidMesh;

    var aabb = zm.AABBf.init(
        .{ .data = .{ vertices[0], vertices[1], vertices[2] } },
        .{ .data = .{ vertices[0], vertices[1], vertices[2] } },
    );

    var i: usize = 3;
    while (i + 2 < vertices.len) : (i += 3) {
        const x = vertices[i];
        const y = vertices[i + 1];
        const z = vertices[i + 2];
        aabb.min = .{ .data = .{ @min(aabb.min.data[0], x), @min(aabb.min.data[1], y), @min(aabb.min.data[2], z) } };
        aabb.max = .{ .data = .{ @max(aabb.max.data[0], x), @max(aabb.max.data[1], y), @max(aabb.max.data[2], z) } };
    }
    return aabb;
}

fn updateBounds(bounds: *zm.AABBf, modelProj: zm.Mat4f) void {
    const modelT = modelProj;

    const corners = [8]zm.Vec4f{
        .{ .data = .{ bounds.min.data[0], bounds.min.data[1], bounds.min.data[2], 1.0 } },
        .{ .data = .{ bounds.max.data[0], bounds.min.data[1], bounds.min.data[2], 1.0 } },
        .{ .data = .{ bounds.min.data[0], bounds.max.data[1], bounds.min.data[2], 1.0 } },
        .{ .data = .{ bounds.max.data[0], bounds.max.data[1], bounds.min.data[2], 1.0 } },
        .{ .data = .{ bounds.min.data[0], bounds.min.data[1], bounds.max.data[2], 1.0 } },
        .{ .data = .{ bounds.max.data[0], bounds.min.data[1], bounds.max.data[2], 1.0 } },
        .{ .data = .{ bounds.min.data[0], bounds.max.data[1], bounds.max.data[2], 1.0 } },
        .{ .data = .{ bounds.max.data[0], bounds.max.data[1], bounds.max.data[2], 1.0 } },
    };

    // Transform first corner to initialize new min/max
    const first = zm.Mat4f.multiplyVec(modelT, corners[0]);
    var newMin = zm.Vec3f{ .data = .{ first.data[0], first.data[1], first.data[2] } };
    var newMax = newMin;

    // Transform the other corners and update min/max
    for (corners[1..]) |corner| {
        const transformed = zm.Mat4f.multiplyVec(modelT, corner);
        newMin = .{ .data = .{
            @min(newMin.data[0], transformed.data[0]),
            @min(newMin.data[1], transformed.data[1]),
            @min(newMin.data[2], transformed.data[2]),
        } };
        newMax = .{ .data = .{
            @max(newMax.data[0], transformed.data[0]),
            @max(newMax.data[1], transformed.data[1]),
            @max(newMax.data[2], transformed.data[2]),
        } };
    }

    bounds.min = newMin;
    bounds.max = newMax;
}

pub const Model = struct {
    mesh: mesh_handler.WgpuMesh,

    model_proj: renderer_handler.Transformation_Mat,

    bind_groups: [2]*wgpu.bind_group.BindGroup,

    pipeline: *wgpu.render_pipeline.RenderPipeline,

    bounds: zm.AABBf,

    pub fn draw(self: *Model, render_pass: *wgpu.render_pass_encoder.RenderPassEncoder) void {
        render_pass.setVertexBuffer(0, self.mesh.vertex_buffer, 0, self.mesh.vertex_buffer.size());
        render_pass.setIndexBuffer(self.mesh.index_buffer, .uint32, 0, self.mesh.index_buffer.size());
        render_pass.drawIndexed(@intCast(self.mesh.mesh.indices.len), 1, 0, 0, 0);
    }

    pub fn getPos(self: *const Model) zm.Vec3f {
        return zm.Vec3f{ .data = .{
            self.model_proj.matrix.data[0][3],
            self.model_proj.matrix.data[1][3],
            self.model_proj.matrix.data[2][3],
        } };
    }

    pub fn setModelMatrix(self: *Model, queue: *wgpu.queue.Queue, modelMatrix: zm.Mat4f) void {
        self.model_proj.matrix = modelMatrix;
        queue.writeBuffer(
            self.model_proj.buffer,
            f32,
            @as(*const [16]f32, @ptrCast(&self.model_proj.matrix)),
            0,
        );
        updateBounds(&self.bounds, modelMatrix);
    }

    pub fn multiplyModelMatrix(self: *Model, queue: *wgpu.queue.Queue, modelMatrix: zm.Mat4f) void {
        self.model_proj.projection = zm.Mat4f.multiply(modelMatrix, self.model_proj.projection);
        queue.writeBuffer(
            self.model_proj.buffer,
            f32,
            @as(*const [16]f32, @ptrCast(&self.model_proj.projection)),
            0,
        );
        updateBounds(&self.bounds, self.model_proj.projection);
    }

    pub fn create(
        mesh: mesh_handler.WgpuMesh,
        proj_matrices: [3]renderer_handler.Transformation_Mat,
        pipeline: *wgpu.render_pipeline.RenderPipeline,
        proj_bind_group: *wgpu.bind_group.BindGroup,
        textures_bind_group: *wgpu.bind_group.BindGroup,
    ) !Model {
        var bounds = try computeAABB(&mesh.mesh);
        updateBounds(&bounds, proj_matrices[2].matrix);

        return Model{
            .mesh = mesh,
            .model_proj = proj_matrices[2],
            .bind_groups = .{ proj_bind_group, textures_bind_group },
            .pipeline = pipeline,
            .bounds = bounds,
        };
    }
};
