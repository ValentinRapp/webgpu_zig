const std = @import("std");
const wgpu = @import("webgpu");
const utils = @import("utils/utils.zig");
const model_handler = @import("model.zig");
const zm = @import("zm");

pub const Pipelines = enum {
    basic,
};

pub const default_vertex_buffer_layout = [_]wgpu.render_pipeline.VertexBufferLayout{.{
    .array_stride = @sizeOf(f32) * 8,
    .step_mode = .vertex,
    .attribute_count = 3,
    .attributes = &[_]wgpu.render_pipeline.VertexAttribute{
        .{
            .format = .float32x3,
            .offset = 0,
            .shader_location = 0,
        },
        .{
            .format = .float32x3,
            .offset = @sizeOf(f32) * 3,
            .shader_location = 1,
        },
        .{
            .format = .float32x2,
            .offset = @sizeOf(f32) * 6,
            .shader_location = 2,
        }
    },
}};

pub fn createBuffer(device: *wgpu.device.Device, comptime T: type, data: []const T, usage: wgpu.buffer.BufferUsage) *wgpu.buffer.Buffer {
    const data_size = @sizeOf(T) * data.len;
    // Align to COPY_BUFFER_ALIGNMENT (4 bytes)
    const buffer_size = (data_size + 3) & ~@as(usize, 3);
    const aligned_len = buffer_size / @sizeOf(T);

    const buffer = device.createBuffer(&.{
        .size = buffer_size,
        .usage = usage,
        .mapped_at_creation = 1,
    });

    if (buffer.getMappedRange(u8, 0, buffer_size)) |mapped| {
        const src_bytes = std.mem.sliceAsBytes(data);
        @memcpy(mapped[0..src_bytes.len], src_bytes);
    }
    buffer.unmap();

    _ = aligned_len;
    return buffer;
}

// pub const BindingResource = union(enum) {
//     buffer: struct { buf: *wgpu.buffer.Buffer, size: u64 },
//     sampler: *wgpu.sampler.Sampler,
//     texture_view: *wgpu.texture_view.TextureView,
// };

// pub fn createBindGroupAdvanced(
//     pipeline: *wgpu.render_pipeline.RenderPipeline,
//     device: *wgpu.device.Device,
//     resources: []const BindingResource,
// ) *wgpu.bind_group.BindGroup {
//     var entries: [16]wgpu.bind_group.BindGroupEntry = undefined;
//     for (resources, 0..) |resource, index| {
//         entries[index] = switch (resource) {
//             .buffer => |b| wgpu.bind_group.BindGroupEntry{
//                 .binding = @intCast(index),
//                 .buffer = b.buf,
//                 .offset = 0,
//                 .size = b.size,
//             },
//             .sampler => |s| wgpu.bind_group.BindGroupEntry{
//                 .binding = @intCast(index),
//                 .sampler = s,
//             },
//             .texture_view => |tv| wgpu.bind_group.BindGroupEntry{
//                 .binding = @intCast(index),
//                 .texture_view = tv,
//             },
//         };
//     }
//     return device.createBindGroup(&.{
//         .layout = pipeline.getBindGroupLayout(0), // Group 0 for buffers
//         .entry_count = resources.len,
//         .entries = &entries,
//     });
// }

pub fn createBindGroup(pipeline: *wgpu.render_pipeline.RenderPipeline, device: *wgpu.device.Device, index: usize, comptime len: usize, args: [len]*wgpu.buffer.Buffer, types: [len]type) *wgpu.bind_group.BindGroup {
    var entries: [len]wgpu.bind_group.BindGroupEntry = undefined;
    inline for (args, types, 0..) |buffer, localtype, i| {
        entries[i] = wgpu.bind_group.BindGroupEntry{
            .binding = @intCast(i),
            .buffer = buffer,
            .offset = 0,
            .size = @sizeOf(localtype),
        };
    }
    return device.createBindGroup(&.{
        .layout = pipeline.getBindGroupLayout(@intCast(index)),
        .entry_count = @intCast(len),
        .entries = &entries,
    });
}

const RenderFrame = struct {
    encoder: *wgpu.command_encoder.CommandEncoder,
    render_pass: *wgpu.render_pass_encoder.RenderPassEncoder,
    surface_view: *wgpu.texture_view.TextureView,

    pub fn submit(self: *RenderFrame, queue: *wgpu.queue.Queue, surface: *wgpu.surface.Surface) void {
        const command_buffer = self.encoder.finish(null);
        queue.submit(&.{command_buffer});
        command_buffer.release();
        self.encoder.release();

        _ = surface.present();

        self.surface_view.release();
    }
};

pub const WebGPU = struct {
    allocator: std.mem.Allocator,

    instance: *wgpu.instance.Instance,
    surface: *wgpu.surface.Surface,
    adapter: *wgpu.adapter.Adapter,
    device: *wgpu.device.Device,
    queue: *wgpu.queue.Queue,

    depth_texture: *wgpu.texture.Texture,
    depth_view: *wgpu.texture_view.TextureView,

    surface_format: wgpu.texture.TextureFormat,

    color_targets: [1]wgpu.render_pipeline.ColorTargetState,
    depth_stencil_state: wgpu.render_pipeline.DepthStencilState,

    pipelines: std.AutoHashMap(Pipelines, *wgpu.render_pipeline.RenderPipeline),
    models: std.AutoHashMap(Pipelines, std.ArrayList(model_handler.Model)),

    camPos: *zm.Vec3f,

    pub fn create(
        allocator: std.mem.Allocator,
        window: *c_long,
        width: u32,
        height: u32,
        camPos: *zm.Vec3f,
    ) !WebGPU {
        var webgpu: WebGPU = undefined;

        webgpu.allocator = allocator;
        webgpu.pipelines = std.AutoHashMap(Pipelines, *wgpu.render_pipeline.RenderPipeline).init(allocator);
        webgpu.models = std.AutoHashMap(Pipelines, std.ArrayList(model_handler.Model)).init(allocator);

        try webgpu.models.put(.basic, try std.ArrayList(model_handler.Model).initCapacity(allocator, 32));

        webgpu.instance = wgpu.instance.Instance.create(null);
        webgpu.surface = utils.createSurface(webgpu.instance, window);
        webgpu.adapter = try webgpu.instance.awaitAdapter(&.{ .compatible_surface = webgpu.surface, .power_preference = .high_performance, .feature_level = .compatibility });
        webgpu.device = try webgpu.adapter.awaitDevice(null);
        webgpu.queue = webgpu.device.getQueue();

        webgpu.depth_texture = webgpu.device.createTexture(&.{
            .usage = .{ .render_attachment = true },
            .dimension = .@"2d",
            .size = .{
                .width = width,
                .height = height,
                .depth_or_array_layers = 1,
            },
            .format = .depth24_plus,
            .mip_level_count = 1,
            .sample_count = 1,
            .view_format_count = 0,
            .view_formats = null,
        });
        webgpu.depth_view = webgpu.depth_texture.createView(null);

        // Get surface capabilities
        var caps: wgpu.surface.SurfaceCapabilities = undefined;
        _ = webgpu.surface.getCapabilities(webgpu.adapter, &caps);
        webgpu.surface_format = caps.formats[0];
        // webgpu.surface_format = .rgb10_a2_unorm;
        // for (caps.formats[0..caps.format_count]) |format| {
        //     std.debug.print("format: {}\n", .{format});
        // }

        // Configure surface
        webgpu.surface.configure(&.{
            .device = webgpu.device,
            .format = webgpu.surface_format,
            .usage = .{ .render_attachment = true },
            .width = width,
            .height = height,
            .view_format_count = 0,
            .view_formats = null,
            .alpha_mode = .auto,
            .present_mode = .fifo,
        });

        webgpu.color_targets = [_]wgpu.render_pipeline.ColorTargetState{.{
            .format = webgpu.surface_format,
            .blend = null,
            .write_mask = wgpu.render_pipeline.ColorWriteMask.all,
        }};

        webgpu.depth_stencil_state = wgpu.render_pipeline.DepthStencilState{
            .format = .depth24_plus,
            .depth_write_enabled = .true,
            .depth_compare = .less,
        };

        webgpu.camPos = camPos;

        return webgpu;
    }

    pub fn beginFrame(self: *WebGPU) !RenderFrame {
        // Get current texture
        var surface_texture: wgpu.surface.SurfaceTexture = undefined;
        self.surface.getCurrentTexture(&surface_texture);

        if (surface_texture.status != .success_optimal and surface_texture.status != .success_suboptimal) {
            return error.FailedToGetSurfaceTexture;
        }

        const view = surface_texture.texture.createView(null);

        const encoder = self.device.createCommandEncoder(&.{});

        // Begin render pass
        const color_attachments = [_]wgpu.render_pass_encoder.RenderPassColorAttachment{.{
            .view = view,
            .load_op = .clear,
            .store_op = .store,
            .clear_value = .{ .r = 0.5, .g = 0.5, .b = 0.8, .a = 1.0 },
        }};

        const depth_stencil_attachment = wgpu.render_pass_encoder.RenderPassDepthStencilAttachment{
            .view = self.depth_view,
            .depth_load_op = .clear,
            .depth_store_op = .store,
            .depth_clear_value = 1.0,
            .depth_read_only = 0,
            .stencil_load_op = .clear,
            .stencil_store_op = .store,
            .stencil_clear_value = 0,
            .stencil_read_only = 0,
        };

        const render_pass = encoder.beginRenderPass(&.{
            .color_attachment_count = color_attachments.len,
            .color_attachments = &color_attachments,
            .depth_stencil_attachment = &depth_stencil_attachment,
        });

        return .{
            .encoder = encoder,
            .render_pass = render_pass,
            .surface_view = view,
        };
    }

    pub fn draw(self: *WebGPU) !void {
        var frame = try self.beginFrame();

        var iterator = self.models.iterator();
        while (iterator.next()) |entry| {
            frame.render_pass.setPipeline(self.pipelines.get(entry.key_ptr.*).?);
            const models_array = entry.value_ptr.*;
            
            const Context = struct {
                camPos: *const zm.Vec3f,
                
                pub fn lessThan(ctx: @This(), a: model_handler.Model, b: model_handler.Model) bool {
                    const dist_a = zm.vec.distance(a.getPos(), ctx.camPos.*);
                    const dist_b = zm.vec.distance(b.getPos(), ctx.camPos.*);
                    return dist_a < dist_b;
                }
            };
            
            std.mem.sort(
                model_handler.Model,
                models_array.items,
                Context{ .camPos = self.camPos },
                Context.lessThan
            );
            
            for (models_array.items) |*model| {
                model.draw(frame.render_pass);
            }
        }

        frame.render_pass.end();
        frame.render_pass.release();

        frame.submit(self.queue, self.surface);
    }

    pub fn setModels(self: *WebGPU, pipeline: Pipelines, models: []const model_handler.Model) !void {
        const models_array = self.models.getPtr(pipeline).?;
        if (models.len > models_array.items.len) {
            try models_array.resize(self.allocator, models.len);
        }
        for (models, 0..) |model, i| {
            models_array.items[i] = model;
        }
    }

    pub fn appendModel(self: *WebGPU, pipeline: Pipelines, model: model_handler.Model) !void {
        const models_array = self.models.getPtr(pipeline).?;
        try models_array.append(self.allocator, model);
    }

    pub fn destroy(self: *WebGPU) void {
        self.instance.release();
        self.surface.release();
        self.adapter.release();
        self.device.release();
        self.queue.release();
        self.depth_texture.release();
        self.depth_view.release();
        self.pipelines.deinit();

        var iterator = self.models.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
        }
        self.models.deinit();
    }
};
