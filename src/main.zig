const std = @import("std");
const builtin = @import("builtin");
const glfw = @import("glfw");
const wgpu = @import("webgpu");
const utils = @import("utils/utils.zig");
const camera = @import("camera.zig");
const zm = @import("zm");
const webgpu_utils = @import("webgpu.zig");
const mesh_handler = @import("mesh.zig");
const model_handler = @import("model.zig");
const zstbi = @import("zstbi");
const texture_handler = @import("texture.zig");

// const width = 1710 * 1;
// const height = 1107 * 1;
// const width = 1920;
// const height = 1080;
// const width = 1280;
// const height = 720;

pub var width: u32 = 1280;
pub var height: u32 = 720;
pub var framebuffer_resized = false;

pub var cam = camera.createCamera(.{ 0.0, 0.5, 3.0 }, -std.math.pi / 2.0, 0.0);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    zstbi.init(allocator);
    defer zstbi.deinit();

    zstbi.setFlipVerticallyOnLoad(true);

    // Initialize GLFW
    try glfw.init();
    defer glfw.terminate();

    // Create window
    glfw.windowHint(glfw.ClientAPI, glfw.NoAPI);
    const window = try glfw.createWindow(@intCast(width), @intCast(height), "WebGPU", null, null);
    defer glfw.destroyWindow(window);

    _ = glfw.setFramebufferSizeCallback(window, utils.framebufferResizeCallback);
    glfw.setInputMode(window, glfw.Cursor, glfw.CursorDisabled);
    _ = glfw.setCursorPosCallback(window, utils.mouseCallback);
    _ = glfw.setCharCallback(window, utils.character_callback);

    const sampler_descriptor = wgpu.sampler.SamplerDescriptor{
        .address_mode_u = .clamp_to_edge,
        .address_mode_v = .clamp_to_edge,
        .address_mode_w = .clamp_to_edge,
        .mag_filter = .linear,
        .min_filter = .linear,
        .mipmap_filter = .linear,
    };
    // var sampler = webgpu.device.createSampler(&sampler_descriptor);
    // defer sampler.release();

    var webgpu = try webgpu_utils.WebGPU.create(
        allocator,
        window,
        width,
        height,
        sampler_descriptor,
        null,
        zm.Mat4f.perspective(std.math.degreesToRadians(70.0), @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height)), 0.1, 100.0),
        cam.getViewMatrix(),
    );
    defer webgpu.destroy();

    // var lightmapTexture = try texture_handler.loadTexture("src/assets/textures/dust2lightmap.jpg", .color, webgpu.device, webgpu.queue);
    // defer lightmapTexture.release();

    var mesh_data = mesh_handler.Mesh.fromFile(allocator, @embedFile("assets/models/obamid.obj")) catch |err| {
        std.debug.print("Failed to load model: {}\n", .{err});
        return err;
    };
    defer mesh_data.destroy(allocator);

    var mesh = mesh_handler.WgpuMesh.create(mesh_data, webgpu.device);
    defer mesh.destroy();

    try webgpu.pipelines.put(.basic, webgpu.device.createRenderPipeline(&.{
        .label = wgpu.StringView.sliced("basic_pipeline"),
        .layout = null,
        .vertex = .{
            .module = webgpu.shader_module,
            .entry_point = wgpu.StringView.sliced("vs_main"),
            .constant_count = 0,
            .constants = null,
            .buffer_count = webgpu_utils.default_vertex_buffer_layout.len,
            .buffers = &webgpu_utils.default_vertex_buffer_layout,
        },
        .primitive = .{
            .topology = .triangle_list,
            .front_face = .counter_clockwise,
            .cull_mode = .back,
        },
        .depth_stencil = &.{
            .format = .depth24_plus,
            .depth_write_enabled = .true,
            .depth_compare = .less,
        },
        .multisample = .{},
        .fragment = &.{
            .module = webgpu.shader_module,
            .entry_point = wgpu.StringView.sliced("fs_unlit"),
            .constant_count = 0,
            .constants = null,
            .target_count = webgpu.color_targets.len,
            .targets = &webgpu.color_targets,
        },
    }));

    const texture_views = try texture_handler.texViewsFromPaths(1, .{"src/assets/textures/obama.png"}, .{.color}, webgpu.device, webgpu.queue);
    defer for (texture_views) |view| {
        view.release();
    };

    var projections = try std.ArrayList(webgpu_utils.Projection).initCapacity(allocator, 32);
    defer projections.deinit(allocator);

    for (0..32) |i| {
        var proj = webgpu_utils.Projection.createBasicModel(webgpu.device);
        proj.matrix = zm.Mat4f.translation(0.0, 0.0, -@as(f32, @floatFromInt(i)) * 2.0);
        webgpu.queue.writeBuffer(proj.buffer, f32, @as(*const [16]f32, @ptrCast(&proj.matrix)), 0);
        try projections.append(allocator, proj);
    }
    defer for (projections.items) |proj| {
        proj.buffer.release();
    };

    var models = try std.ArrayList(model_handler.Model).initCapacity(allocator, 32);
    defer models.deinit(allocator);

    const textures_bind_group = texture_handler.createTextureBindGroup(
        texture_views.len,
        webgpu.pipelines.get(.basic).?,
        webgpu.device,
        1,
        webgpu.sampler,
        &texture_views,
    );

    for (0..32) |i| {
        try models.append(allocator, try model_handler.Model.create(
            mesh,
            .{
                webgpu.projection,
                webgpu.view,
                projections.items[i],
            },
            webgpu.pipelines.get(.basic).?,
            model_handler.createProjectionsBindGroup(
                webgpu.pipelines.get(.basic).?,
                webgpu.device,
                0,
                .{ webgpu.projection.buffer, webgpu.view.buffer, projections.items[i].buffer },
            ),
            textures_bind_group,
        ));
    }
    for (models.items) |model| {
        try webgpu.appendModel(.basic, model);
    }

    // var model_proj = model_handler.Projection.createBasicModel(webgpu.device);
    // defer model_proj.buffer.release();

    // var model = model_handler.Model.create(
    //     mesh,
    //     .{
    //         .{ .projection = proj_data, .buffer = projBuffer },
    //         .{ .projection = view_data, .buffer = viewBuffer },
    //         projections.items[12],
    //     },
    //     webgpu.pipelines.get(.basic).?,
    //     webgpu.device,
    //     sampler,
    //     texture_views.len,
    //     &texture_views,
    // );
    // defer model.destroy();

    // try webgpu.setModels(.basic, &.{ model });

    std.debug.print("WebGPU initialized successfully!\n", .{});

    var lastFrame = glfw.getTime();
    var currentFrame: f64 = undefined;
    var deltaTime: f64 = undefined;

    // Main loop
    while (!glfw.windowShouldClose(window)) {
        glfw.pollEvents();

        utils.processInput(window, deltaTime);

        if (framebuffer_resized) {
            try webgpu.resize(width, height);
            framebuffer_resized = false;
        }

        currentFrame = glfw.getTime();
        deltaTime = currentFrame - lastFrame;
        lastFrame = currentFrame;

        // rotation_amount -= 0.03;
        // model.model_proj.projection = zm.Mat4f.rotation(zm.Vec3f{ 0.0, 1.0, 0.0 }, rotation_amount);
        // model2.model_proj.projection = zm.Mat4f.rotation(zm.Vec3f{ 0.0, 1.0, 0.0 }, std.math.pi);
        // model2.model_proj.projection.data[7] = 0.3;
        // model.model_proj.projection.data[7] = -0.1;

        // Update uniform buffers
        webgpu.updateView(cam.getViewMatrix());
        // webgpu.queue.writeBuffer(model.model_proj.buffer, f32, @as(*const [16]f32, @ptrCast(&model.model_proj.projection)), 0);
        // webgpu.queue.writeBuffer(model2.model_proj.buffer, f32, @as(*const [16]f32, @ptrCast(&model2.model_proj.projection)), 0);

        webgpu.draw(cam.Position) catch |err| {
            std.debug.print("Failed to draw frame: {}\n", .{err});
            continue;
        };
    }
}
