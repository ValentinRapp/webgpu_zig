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

pub const Model = struct {
    mesh: mesh_handler.WgpuMesh,

    model_proj: Projection,

    bind_groups: [2]*wgpu.bind_group.BindGroup,

    pipeline: *wgpu.render_pipeline.RenderPipeline,

    pub fn draw(self: *Model, render_pass: *wgpu.render_pass_encoder.RenderPassEncoder) void {
        // render_pass.setPipeline(self.pipeline);
        // render_pass.setBindGroup(0, self.bind_groups[0], null);
        for (self.bind_groups, 0..) |bind_group, i| {
            render_pass.setBindGroup(@intCast(i), bind_group, null);
        }
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
        device: *wgpu.device.Device,
        sampler: *wgpu.sampler.Sampler,
        comptime num_textures: usize,
        texture_views: *const [num_textures]*wgpu.texture_view.TextureView,
    ) Model {
        const proj_bind_group = webgpu_utils.createBindGroup(
            pipeline,
            device,
            0,
            3,
            .{ proj_matrices[0].buffer, proj_matrices[1].buffer, proj_matrices[2].buffer },
            .{ zm.Mat4f, zm.Mat4f, zm.Mat4f },
        );

        const textures_bind_group = texture_handler.createTextureBindGroup(
            num_textures,
            pipeline,
            device,
            1,
            sampler,
            texture_views,
        );

        return Model{
            .mesh = mesh,
            .model_proj = proj_matrices[2],
            .bind_groups = .{ proj_bind_group, textures_bind_group },
            .pipeline = pipeline
        };
    }

    pub fn destroy(self: *Model) void {
        for (self.bind_groups) |bind_group| {
            bind_group.release();
        }
    }
};
