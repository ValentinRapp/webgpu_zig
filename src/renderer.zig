const std = @import("std");
const wgpu = @import("webgpu");
const utils = @import("utils/utils.zig");
const model_handler = @import("model.zig");
const zm = @import("zm");
const camera_handler = @import("camera.zig");
const frustum_handler = @import("frustum.zig");
const texture_handler = @import("texture.zig");
const mesh_handler = @import("mesh.zig");

pub const Pipelines = enum {
    skybox,
    basic,
};

pub const default_vertex_buffer_layout = [_]wgpu.render_pipeline.VertexBufferLayout{.{
    .array_stride = @sizeOf(f32) * 8,
    .step_mode = .vertex,
    .attribute_count = 3,
    .attributes = &[_]wgpu.render_pipeline.VertexAttribute{ .{
        .format = .float32x3,
        .offset = 0,
        .shader_location = 0,
    }, .{
        .format = .float32x3,
        .offset = @sizeOf(f32) * 3,
        .shader_location = 1,
    }, .{
        .format = .float32x2,
        .offset = @sizeOf(f32) * 6,
        .shader_location = 2,
    } },
}};

pub const Transformation_Mat = struct {
    matrix: zm.Mat4f = undefined,
    buffer: *wgpu.buffer.Buffer = undefined,

    pub fn createBasicModel(device: *wgpu.device.Device) Transformation_Mat {
        var proj = Transformation_Mat{
            .matrix = zm.Mat4f.identity(),
            .buffer = undefined,
        };
        proj.buffer = createBuffer(
            device,
            f32,
            @as(*const [16]f32, @ptrCast(&proj.matrix)),
            .{ .uniform = true, .copy_dst = true },
        );
        return proj;
    }

    pub fn createModel(device: *wgpu.device.Device, scale: f32, position: zm.Vec3f, rotation: zm.Mat4f) Transformation_Mat {
        var proj = Transformation_Mat{
            .matrix = zm.Mat4f.identity(),
            .buffer = undefined,
        };
        proj.matrix = zm.Mat4f.multiply(
            zm.Mat4f.translationVec3(position),
            zm.Mat4f.multiply(
                rotation,
                zm.Mat4f.scaling(scale, scale, scale),
            ),
        );
        proj.buffer = createBuffer(
            device,
            f32,
            @as(*const [16]f32, @ptrCast(&proj.matrix)),
            .{ .uniform = true, .copy_dst = true },
        );
        return proj;
    }
};

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

pub fn isInFrustum(model: *const model_handler.Model, viewProj: zm.Mat4f) bool {
    // const viewProj = zm.Mat4f.multiply(projectionMatrix, viewMatrix);
    const frustum = frustum_handler.Frustum.fromViewProjection(viewProj);
    return frustum.containsAABB(model.bounds);
}

pub const Renderer = struct {
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

    pipelines: std.AutoHashMap(Pipelines, *wgpu.render_pipeline.RenderPipeline),
    models: std.AutoHashMap(Pipelines, std.ArrayList(model_handler.Model)),

    projection: Transformation_Mat,
    view: Transformation_Mat,

    sampler: *wgpu.sampler.Sampler,
    shader_module: *wgpu.shader.ShaderModule,

    // Skybox resources
    skybox_mesh: ?mesh_handler.WgpuMesh = null,
    skybox_texture_view: ?*wgpu.texture_view.TextureView = null,
    skybox_proj_buffer: ?*wgpu.buffer.Buffer = null,

    pub fn create(
        allocator: std.mem.Allocator,
        window: *c_long,
        width: u32,
        height: u32,
        sampler_descriptor: wgpu.sampler.SamplerDescriptor,
        skybox_texture_path: ?[:0]const u8,
        projection: zm.Mat4f,
        view: zm.Mat4f,
    ) !Renderer {
        var renderer: Renderer = undefined;

        renderer.allocator = allocator;

        renderer.instance = wgpu.instance.Instance.create(null);
        renderer.surface = utils.createSurface(renderer.instance, window);
        renderer.adapter = try renderer.instance.awaitAdapter(&.{ .compatible_surface = renderer.surface, .power_preference = .high_performance, .feature_level = .compatibility });
        renderer.device = try renderer.adapter.awaitDevice(null);
        renderer.queue = renderer.device.getQueue();

        var caps: wgpu.surface.SurfaceCapabilities = undefined;
        _ = renderer.surface.getCapabilities(renderer.adapter, &caps);
        renderer.surface_format = caps.formats[0];
        renderer.surface.configure(&.{
            .device = renderer.device,
            .format = renderer.surface_format,
            .usage = .{ .render_attachment = true },
            .width = width,
            .height = height,
            .view_format_count = 0,
            .view_formats = null,
            .alpha_mode = .auto,
            .present_mode = .fifo,
        });

        renderer.color_targets = [_]wgpu.render_pipeline.ColorTargetState{.{
            .format = renderer.surface_format,
            .blend = null,
            .write_mask = wgpu.render_pipeline.ColorWriteMask.all,
        }};

        // Create depth texture
        renderer.depth_texture = renderer.device.createTexture(&.{
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
        renderer.depth_view = renderer.depth_texture.createView(null);

        // Create sampler and shader module
        renderer.sampler = renderer.device.createSampler(&sampler_descriptor);

        const shader_code = @embedFile("assets/shaders/shader.wgsl");
        var wgsl_source = wgpu.shader.ShaderSourceWGSL{
            .chain = .{ .type = .shader_source_wgsl },
            .code = wgpu.StringView.sliced(shader_code),
        };
        renderer.shader_module = renderer.device.createShaderModule(&.{
            .next = @ptrCast(&wgsl_source),
            .label = wgpu.StringView.sliced("shader"),
        });

        // Create projection and view buffers
        renderer.projection.matrix = projection;
        renderer.projection.buffer = createBuffer(
            renderer.device,
            f32,
            @as(*const [16]f32, @ptrCast(&renderer.projection.matrix)),
            .{ .uniform = true, .copy_dst = true },
        );
        renderer.view.matrix = view;
        renderer.view.buffer = createBuffer(
            renderer.device,
            f32,
            @as(*const [16]f32, @ptrCast(&renderer.view.matrix)),
            .{ .uniform = true, .copy_dst = true },
        );

        // Initialize pipelines and models hashmaps
        renderer.pipelines = std.AutoHashMap(Pipelines, *wgpu.render_pipeline.RenderPipeline).init(allocator);
        renderer.models = std.AutoHashMap(Pipelines, std.ArrayList(model_handler.Model)).init(allocator);

        inline for (@typeInfo(Pipelines).@"enum".fields) |f| {
            try renderer.models.put(@enumFromInt(f.value), try std.ArrayList(model_handler.Model)
                .initCapacity(allocator, 32));
        }

        // Create skybox if texture path provided
        if (skybox_texture_path) |texture_path| {
            try renderer.pipelines.put(.skybox, renderer.device.createRenderPipeline(&.{
                .label = wgpu.StringView.sliced("skybox_pipeline"),
                .layout = null,
                .vertex = .{
                    .module = renderer.shader_module,
                    .entry_point = wgpu.StringView.sliced("vs_skybox"),
                    .constant_count = 0,
                    .constants = null,
                    .buffer_count = default_vertex_buffer_layout.len,
                    .buffers = &default_vertex_buffer_layout,
                },
                .primitive = .{
                    .topology = .triangle_list,
                    .front_face = .counter_clockwise,
                    .cull_mode = .none,
                },
                .depth_stencil = &.{
                    .format = .depth24_plus,
                    .depth_write_enabled = .false,
                    .depth_compare = .always,
                },
                .multisample = .{},
                .fragment = &.{
                    .module = renderer.shader_module,
                    .entry_point = wgpu.StringView.sliced("fs_unlit"),
                    .constant_count = 0,
                    .constants = null,
                    .target_count = renderer.color_targets.len,
                    .targets = &renderer.color_targets,
                },
            }));

            var skybox_mesh_data = mesh_handler.Mesh.fromFile(allocator, @embedFile("assets/models/skybox.obj")) catch |err| {
                std.debug.print("Failed to load model: {}\n", .{err});
                return err;
            };
            defer skybox_mesh_data.destroy(allocator);

            renderer.skybox_mesh = mesh_handler.WgpuMesh.create(skybox_mesh_data, renderer.device);

            const proj = Transformation_Mat.createBasicModel(renderer.device);
            renderer.skybox_proj_buffer = proj.buffer;

            const tex_views = try texture_handler.texViewsFromPaths(1, .{texture_path}, .{.color}, renderer.device, renderer.queue);
            renderer.skybox_texture_view = tex_views[0];

            try renderer.setModels(.skybox, &.{try model_handler.Model.create(
                renderer.skybox_mesh.?,
                .{
                    renderer.projection,
                    renderer.view,
                    proj,
                },
                renderer.pipelines.get(.skybox).?,
                model_handler.createProjectionsBindGroup(
                    renderer.pipelines.get(.skybox).?,
                    renderer.device,
                    0,
                    .{ renderer.projection.buffer, renderer.view.buffer, proj.buffer },
                ),
                texture_handler.createTextureBindGroup(
                    tex_views.len,
                    renderer.pipelines.get(.skybox).?,
                    renderer.device,
                    1,
                    renderer.sampler,
                    &tex_views,
                ),
            )});
        } else {
            renderer.skybox_mesh = null;
            renderer.skybox_texture_view = null;
            renderer.skybox_proj_buffer = null;
        }

        return renderer;
    }

    pub fn updateView(self: *Renderer, viewMatrix: zm.Mat4f) void {
        self.view.matrix = viewMatrix;
        self.queue.writeBuffer(self.view.buffer, f32, @as(*const [16]f32, @ptrCast(&self.view.matrix)), 0);
    }

    pub fn resize(self: *Renderer, width: u32, height: u32) !void {
        if (width == 0 or height == 0) return;

        self.depth_texture.release();
        self.depth_view.release();

        self.depth_texture = self.device.createTexture(&.{
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
        self.depth_view = self.depth_texture.createView(null);

        self.surface.configure(&.{
            .device = self.device,
            .format = self.surface_format,
            .usage = .{ .render_attachment = true },
            .width = width,
            .height = height,
            .view_format_count = 0,
            .view_formats = null,
            .alpha_mode = .auto,
            .present_mode = .fifo,
        });

        // Update projection matrix
        const fov = 2.0 * std.math.atan(1.0 / self.projection.matrix.data[5]);
        const aspect_ratio = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));
        self.projection.matrix.data[0] = 1.0 / (aspect_ratio * @tan(fov / 2.0));

        self.queue.writeBuffer(self.projection.buffer, f32, @as(*const [16]f32, @ptrCast(&self.projection.matrix)), 0);
    }

    pub fn beginFrame(self: *Renderer) !RenderFrame {
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

    pub fn draw(self: *Renderer, camPos: zm.Vec3f) !void {
        const viewProj = zm.Mat4f.multiply(self.projection.matrix, self.view.matrix);
        var frame = try self.beginFrame();

        var iterator = self.models.iterator();
        while (iterator.next()) |entry| {
            frame.render_pass.setPipeline(self.pipelines.get(entry.key_ptr.*) orelse continue);
            const models_array = entry.value_ptr.*;

            const Context = struct {
                camPos: *const zm.Vec3f,

                pub fn lessThan(ctx: @This(), a: model_handler.Model, b: model_handler.Model) bool {
                    const dist_a = zm.vec.distance(a.getPos(), ctx.camPos.*);
                    const dist_b = zm.vec.distance(b.getPos(), ctx.camPos.*);
                    return dist_a < dist_b;
                }
            };

            std.mem.sort(model_handler.Model, models_array.items, Context{ .camPos = &camPos }, Context.lessThan);

            var last_bind_groups = [2]*wgpu.bind_group.BindGroup{
                models_array.items[0].bind_groups[0],
                models_array.items[0].bind_groups[1],
            };
            frame.render_pass.setBindGroup(0, last_bind_groups[0], null);
            frame.render_pass.setBindGroup(1, last_bind_groups[1], null);

            for (models_array.items) |*model| {
                if (!isInFrustum(model, viewProj) and entry.key_ptr.* != .skybox) {
                    // std.debug.print("0 ", .{});
                    continue;
                }

                if (model.bind_groups[0] != last_bind_groups[0]) {
                    frame.render_pass.setBindGroup(0, model.bind_groups[0], null);
                    last_bind_groups[0] = model.bind_groups[0];
                }
                if (model.bind_groups[1] != last_bind_groups[1]) {
                    frame.render_pass.setBindGroup(1, model.bind_groups[1], null);
                    last_bind_groups[1] = model.bind_groups[1];
                }

                // std.debug.print("1 ", .{});
                model.draw(frame.render_pass);
            }
            // std.debug.print("\n", .{});
        }

        frame.render_pass.end();
        frame.render_pass.release();

        frame.submit(self.queue, self.surface);
    }

    pub fn setModels(self: *Renderer, pipeline: Pipelines, models: []const model_handler.Model) !void {
        const models_array = self.models.getPtr(pipeline).?;
        if (models.len > models_array.items.len) {
            try models_array.resize(self.allocator, models.len);
        }
        for (models, 0..) |model, i| {
            models_array.items[i] = model;
        }
    }

    pub fn appendModel(self: *Renderer, pipeline: Pipelines, model: model_handler.Model) !void {
        const models_array = self.models.getPtr(pipeline).?;
        try models_array.append(self.allocator, model);
    }

    pub fn destroy(self: *Renderer) void {
        // Release all pipelines
        var pipeline_iterator = self.pipelines.iterator();
        while (pipeline_iterator.next()) |entry| {
            entry.value_ptr.*.release();
        }
        self.pipelines.deinit();

        // Release all models
        var iterator = self.models.iterator();
        while (iterator.next()) |entry| {
            for (entry.value_ptr.*.items) |*model| {
                model.destroy();
            }
            entry.value_ptr.*.deinit(self.allocator);
        }
        self.models.deinit();

        // Release skybox resources
        if (self.skybox_mesh != null) {
            self.skybox_mesh.?.destroy();
        }
        if (self.skybox_texture_view) |view| {
            view.release();
        }
        if (self.skybox_proj_buffer) |buffer| {
            buffer.release();
        }

        self.projection.buffer.release();
        self.view.buffer.release();
        self.sampler.release();
        self.shader_module.release();
        self.depth_texture.release();
        self.depth_view.release();
        self.queue.release();
        self.device.release();
        self.adapter.release();
        self.surface.release();
        self.instance.release();
    }
};
