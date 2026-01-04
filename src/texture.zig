const std = @import("std");
const wgpu = @import("webgpu");
const zstbi = @import("zstbi");
const webgpu_utils = @import("webgpu.zig");

const TextureType = enum {
    color, // sRGB (diffuse, albedo, UI textures)
    data, // Linear (normal maps, roughness, etc.)
};

pub fn getTextureFormat(texture_type: TextureType) wgpu.texture.TextureFormat {
    return switch (texture_type) {
        .color => .rgba8_unorm_srgb,
        .data => .rgba8_unorm,
    };
}

pub fn texViewsFromPaths(
    comptime len: usize,
    paths: [len][:0]const u8,
    texture_types: [len]TextureType,
    device: *wgpu.device.Device,
    queue: *wgpu.queue.Queue,
) ![len]*wgpu.texture_view.TextureView {
    var texture_views: [len]*wgpu.texture_view.TextureView = undefined;

    inline for (paths, 0..) |path, i| {
        var texture = try loadTexture(
            path,
            texture_types[i],
            device,
            queue
        );
        defer texture.release();

        texture_views[i] = texture.createView(null);
    }

    return texture_views;
}

pub fn loadTexture(
    path: [:0]const u8,
    texture_type: TextureType,
    device: *wgpu.device.Device,
    queue: *wgpu.queue.Queue,
) !*wgpu.texture.Texture {
    var image = try zstbi.Image.loadFromFile(path, 4);
    defer image.deinit();

    const texture_descriptor = wgpu.texture.TextureDescriptor{
        .size = .{ .width = image.width, .height = image.height, .depth_or_array_layers = 1 },
        .format = getTextureFormat(texture_type),
        .usage = .{ .texture_binding = true, .copy_dst = true },
        .dimension = .@"2d",
        .mip_level_count = 1,
        .sample_count = 1,
        .view_formats = null,
    };
    const texture = device.createTexture(&texture_descriptor);
    // defer texture.destroy();

    const destination = wgpu.texel.TexelCopyTextureInfo{
        .texture = texture,
        .mip_level = 0,
        .origin = .{ .x = 0, .y = 0, .z = 0 },
        .aspect = .all,
    };

    const data_layout = wgpu.texel.TexelCopyBufferLayout{
        .offset = 0,
        .bytes_per_row = image.width * 4,
        .rows_per_image = image.height,
    };

    const write_size = wgpu.Extent3D{
        .width = image.width,
        .height = image.height,
        .depth_or_array_layers = 1,
    };

    queue.writeTexture(
        &destination,
        image.data.ptr,
        image.data.len,
        &data_layout,
        &write_size,
    );

    return texture;
}

pub fn loadTextures(
    allocator: std.mem.Allocator,
    paths: [][:0]const u8,
    texture_type: TextureType,
    device: *wgpu.device.Device,
    queue: *wgpu.queue.Queue,
) ![]*wgpu.texture.Texture {
    var textures: []*wgpu.texture.Texture = try allocator.alloc(*wgpu.texture.Texture, paths.len);
    for (paths, 0..) |path, i| {
        textures[i] = try loadTexture(path, texture_type, device, queue);
    }
    return textures;
}

pub fn destroyTextures(textures: []*wgpu.texture.Texture) void {
    for (textures) |texture| {
        texture.release();
    }
}

pub fn createTextureBindGroup(
    comptime num_textures: usize,
    pipeline: *wgpu.render_pipeline.RenderPipeline,
    device: *wgpu.device.Device,
    index: usize,
    sampler: *wgpu.sampler.Sampler,
    texture_views: *const [num_textures]*wgpu.texture_view.TextureView,
) *wgpu.bind_group.BindGroup {
    var entries: [1 + num_textures]wgpu.bind_group.BindGroupEntry = undefined;

    entries[0] = wgpu.bind_group.BindGroupEntry{
        .binding = 0,
        .sampler = sampler,
    };

    inline for (texture_views, 0..) |texture_view, i| {
        entries[i + 1] = wgpu.bind_group.BindGroupEntry{
            .binding = @intCast(i + 1),
            .texture_view = texture_view,
        };
    }

    return device.createBindGroup(&.{
        .layout = pipeline.getBindGroupLayout(@intCast(index)),
        .entry_count = 1 + num_textures,
        .entries = &entries,
    });
}
