const std = @import("std");
const wgpu = @import("webgpu");
const webgpu_utils = @import("webgpu.zig");
const obj = @import("obj");

pub const Mesh = struct {
    vertices: []const f32,
    indices: []const u16,

    // Only use when using dynamic allocation
    pub fn destroy(self: *Mesh, allocator: std.mem.Allocator) void {
        allocator.free(self.vertices);
        allocator.free(self.indices);
    }

    pub fn fromFile(
        allocator: std.mem.Allocator,
        fileData: []const u8,
    ) !Mesh {
        var mesh = try obj.parseObj(allocator, fileData);
        defer mesh.deinit(allocator);

        const vertexCount = mesh.meshes[0].indices.len;
        const vertices = try allocator.alloc(f32, vertexCount * 8);

        for (mesh.meshes[0].indices, 0..) |index, i| {
            const v_idx = index.vertex.?;
            const n_idx = index.normal.?;
            const t_idx = index.tex_coord.?;

            const pos_offset = v_idx * 3;
            const norm_offset = n_idx * 3;
            const tex_offset = t_idx * 2;

            // Position (x, y, z)
            vertices[i * 8 + 0] = mesh.vertices[pos_offset + 0];
            vertices[i * 8 + 1] = mesh.vertices[pos_offset + 1];
            vertices[i * 8 + 2] = mesh.vertices[pos_offset + 2];

            // Normals (nx, ny, nz)
            vertices[i * 8 + 3] = mesh.normals[norm_offset + 0];
            vertices[i * 8 + 4] = mesh.normals[norm_offset + 1];
            vertices[i * 8 + 5] = mesh.normals[norm_offset + 2];

            // Texture Coordinates (u, v)
            vertices[i * 8 + 6] = mesh.tex_coords[tex_offset + 0];
            vertices[i * 8 + 7] = mesh.tex_coords[tex_offset + 1];
        }

        const indices = try allocator.alloc(u16, vertexCount);
        for (indices, 0..) |*elem, i| {
            elem.* = @intCast(i);
        }

        return .{
            .vertices = vertices,
            .indices = indices,
        };
    }
};

pub const WgpuMesh = struct {
    mesh: Mesh,
    vertex_buffer: *wgpu.buffer.Buffer,
    index_buffer: *wgpu.buffer.Buffer,

    pub fn create(mesh_data: Mesh, device: *wgpu.device.Device) WgpuMesh {
        var wgpu_mesh: WgpuMesh = undefined;
        wgpu_mesh.mesh = mesh_data;

        wgpu_mesh.vertex_buffer = webgpu_utils.createBuffer(
            device,
            f32,
            mesh_data.vertices,
            .{ .vertex = true, .copy_dst = true }
        );
    
        wgpu_mesh.index_buffer = webgpu_utils.createBuffer(
            device,
            u16,
            mesh_data.indices,
            .{ .index = true, .copy_dst = true }
        );

        return wgpu_mesh;
    }

    pub fn destroy(self: *WgpuMesh) void {
        self.vertex_buffer.release();
        self.index_buffer.release();
        // self.mesh.destroy();
    }
};