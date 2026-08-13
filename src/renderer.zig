const std = @import("std");
const builtin = @import("builtin");
const wgpu = @import("webgpu");
const utils = @import("utils/utils.zig");
const model_handler = @import("model.zig");
const zm = @import("zm");
const camera_handler = @import("camera.zig");
const frustum_handler = @import("frustum.zig");
const texture_handler = @import("texture.zig");
const mesh_handler = @import("mesh.zig");
const pipeline_handler = @import("pipeline.zig");

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

    pipelines: []const pipeline_handler.Pipeline = undefined,
    models: std.AutoHashMap(*const pipeline_handler.Pipeline, std.ArrayList(model_handler.Model)) = undefined,

    projection: Transformation_Mat,
    view: Transformation_Mat,

    sampler: *wgpu.sampler.Sampler,

    // Skybox resources
    skybox_mesh: ?mesh_handler.WgpuMesh,
    skybox_texture_view: ?*wgpu.texture_view.TextureView,
    skybox_proj_buffer: ?*wgpu.buffer.Buffer,

    pub fn create(
        allocator: std.mem.Allocator,
        window: *c_long,
        width: u32,
        height: u32,
        sampler_descriptor: wgpu.sampler.SamplerDescriptor,
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
        renderer.skybox_mesh = null;
        renderer.skybox_texture_view = null;
        renderer.skybox_proj_buffer = null;

        return renderer;
    }

    pub fn setSkybox(
        self: *Renderer,
        pipeline: *const pipeline_handler.Pipeline,
        texture_path: [:0]const u8
    ) !void {
        var skybox_mesh_data = mesh_handler.Mesh.fromFile(self.allocator, @embedFile("assets/models/skybox.obj")) catch |err| {
            std.debug.print("Failed to load model: {}\n", .{err});
            return err;
        };
        defer skybox_mesh_data.destroy(self.allocator);
        self.skybox_mesh = mesh_handler.WgpuMesh.create(skybox_mesh_data, self.device);
        const proj = Transformation_Mat.createBasicModel(self.device);
        self.skybox_proj_buffer = proj.buffer;
        const tex_views = try texture_handler.texViewsFromPaths(
            1,
            .{texture_path},
            .{.color},
            self.device,
            self.queue
        );
        self.skybox_texture_view = tex_views[0];
        try self.setModels(pipeline, &.{try model_handler.Model.create(
            self.skybox_mesh.?,
            .{
                self.projection,
                self.view,
                proj,
            },
            pipeline.pipeline,
            model_handler.createProjectionsBindGroup(
                pipeline.pipeline,
                self.device,
                0,
                .{ self.projection.buffer, self.view.buffer, proj.buffer },
            ),
            texture_handler.createTextureBindGroup(
                tex_views.len,
                pipeline.pipeline,
                self.device,
                1,
                self.sampler,
                &tex_views,
            ),
        )});
    }

    pub fn setPipelines(self: *Renderer, pipelines: []const pipeline_handler.Pipeline) !void {
        self.pipelines = pipelines;
        self.models = std.AutoHashMap(*const pipeline_handler.Pipeline, std.ArrayList(model_handler.Model)).init(self.allocator);
        for (self.pipelines) |*pipeline| {
            try self.models.put(pipeline, try std.ArrayList(model_handler.Model)
                .initCapacity(self.allocator, 32));
        }
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
        const fov = 2.0 * std.math.atan(1.0 / self.projection.matrix.data[1][1]);
        const aspect_ratio = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));
        self.projection.matrix.data[0][0] = 1.0 / (aspect_ratio * @tan(fov / 2.0));

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

        // make explicit render order
        // const render_order = [_]Pipelines{ .skybox, .basic, .transparent };

        for (self.pipelines) |*pipeline| {
            // const pipeline = self.pipelines.get(pipeline_type) orelse continue;
            const models_array = self.models.getPtr(pipeline) orelse continue;

            if (models_array.items.len == 0) continue;

            frame.render_pass.setPipeline(pipeline.pipeline);

            const Context = struct {
                camPos: *const zm.Vec3f,

                pub fn lessThan(ctx: @This(), a: model_handler.Model, b: model_handler.Model) bool {
                    const dist_a = a.getPos().distance(ctx.camPos.*);
                    const dist_b = b.getPos().distance(ctx.camPos.*);
                    return dist_a < dist_b;
                }

                pub fn moreThan(ctx: @This(), a: model_handler.Model, b: model_handler.Model) bool {
                    const dist_a = a.getPos().distance(ctx.camPos.*);
                    const dist_b = b.getPos().distance(ctx.camPos.*);
                    return dist_a > dist_b;
                }
            };

            if (pipeline.sort_front_to_back) {
                std.mem.sort(
                    model_handler.Model,
                    models_array.items,
                    Context{
                        .camPos = &camPos,
                    },
                    Context.lessThan,
                );
            } else {
                std.mem.sort(
                    model_handler.Model,
                    models_array.items,
                    Context{
                        .camPos = &camPos,
                    },
                    Context.moreThan,
                );
            }

            var last_bind_groups = [2]*wgpu.bind_group.BindGroup{
                models_array.items[0].bind_groups[0],
                models_array.items[0].bind_groups[1],
            };
            frame.render_pass.setBindGroup(0, last_bind_groups[0], null);
            frame.render_pass.setBindGroup(1, last_bind_groups[1], null);

            for (models_array.items) |*model| {
                if (!isInFrustum(model, viewProj) and pipeline.frustum_cull) {
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

                model.draw(frame.render_pass);
            }
        }

        frame.render_pass.end();
        frame.render_pass.release();

        frame.submit(self.queue, self.surface);
    }

    pub fn setModels(self: *Renderer, pipeline: *const pipeline_handler.Pipeline, models: []const model_handler.Model) !void {
        const models_array = self.models.getPtr(pipeline).?;
        if (models.len > models_array.items.len) {
            try models_array.resize(self.allocator, models.len);
        }
        for (models, 0..) |model, i| {
            models_array.items[i] = model;
        }
    }

    pub fn appendModel(self: *Renderer, pipeline: *const pipeline_handler.Pipeline, model: model_handler.Model) !void {
        const models_array = self.models.getPtr(pipeline).?;
        try models_array.append(self.allocator, model);
    }

    pub fn destroyModels(self: *Renderer) void {
        var iterator = self.models.iterator();
        while (iterator.next()) |entry| {
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
    }

    pub fn destroy(self: *Renderer) void {
        self.projection.buffer.release();
        self.view.buffer.release();
        self.sampler.release();
        self.depth_texture.release();
        self.depth_view.release();
        self.queue.release();

        self.surface.unconfigure();
        self.surface.release();
        self.device.destroy();
        self.adapter.release();
        self.instance.release();
    }
};
