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
const width = 1280;
const height = 720;

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

    // Create window (no OpenGL context for WebGPU)
    glfw.windowHint(glfw.ClientAPI, glfw.NoAPI);
    const window = try glfw.createWindow(width, height, "WebGPU", null, null);
    defer glfw.destroyWindow(window);

    glfw.setInputMode(window, glfw.Cursor, glfw.CursorDisabled);
    _ = glfw.setCursorPosCallback(window, utils.mouseCallback);
    _ = glfw.setCharCallback(window, utils.character_callback);

    var webgpu = try webgpu_utils.WebGPU.create(
        allocator,
        window,
        width,
        height,
        &cam.Position
    );
    defer webgpu.destroy();

    var texture = try texture_handler.loadTexture("src/assets/textures/obama.png", .color, webgpu.device, webgpu.queue);
    defer texture.release();
    // var lightmapTexture = try texture_handler.loadTexture("src/assets/textures/dust2lightmap.jpg", .color, webgpu.device, webgpu.queue);
    // defer lightmapTexture.release();

    const sampler_descriptor = wgpu.sampler.SamplerDescriptor{
        .address_mode_u = .clamp_to_edge,
        .address_mode_v = .clamp_to_edge,
        .address_mode_w = .clamp_to_edge,
        .mag_filter = .linear,
        .min_filter = .linear,
        .mipmap_filter = .linear,
    };
    var sampler = webgpu.device.createSampler(&sampler_descriptor);
    defer sampler.release();

    // Create shader module
    const shader_code = @embedFile("assets/shaders/shader.wgsl");
    var wgsl_source = wgpu.shader.ShaderSourceWGSL{
        .chain = .{ .type = .shader_source_wgsl },
        .code = wgpu.StringView.sliced(shader_code),
    };
    const shader_module = webgpu.device.createShaderModule(&.{
        .next = @ptrCast(&wgsl_source),
        .label = wgpu.StringView.sliced("shader"),
    });
    defer shader_module.release();

    var mesh_data = mesh_handler.Mesh.fromFile(allocator, @embedFile("assets/models/obamid.obj")) catch |err| {
        std.debug.print("Failed to load model: {}\n", .{err});
        return err;
    };
    defer mesh_data.destroy(allocator);

    var mesh = mesh_handler.WgpuMesh.create(mesh_data, webgpu.device);
    defer mesh.destroy();

    var proj_data = zm.Mat4f.perspective(70.0 * std.math.pi / 180.0, @as(f32, @floatCast(width)) / @as(f32, @floatCast(height)), 0.1, 100.0);
    const projBuffer = webgpu_utils.createBuffer(webgpu.device, f32, @as(*const [16]f32, @ptrCast(&proj_data)), .{ .uniform = true, .copy_dst = true });
    defer projBuffer.release();

    var view_data = cam.getViewMatrix();
    const viewBuffer = webgpu_utils.createBuffer(webgpu.device, f32, @as(*const [16]f32, @ptrCast(&view_data)), .{ .uniform = true, .copy_dst = true });
    defer viewBuffer.release();

    try webgpu.pipelines.put(.basic, webgpu.device.createRenderPipeline(&.{
        .label = wgpu.StringView.sliced("pipeline"),
        .layout = null,
        .vertex = .{
            .module = shader_module,
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
        .depth_stencil = &webgpu.depth_stencil_state,
        .multisample = .{},
        .fragment = &.{
            .module = shader_module,
            .entry_point = wgpu.StringView.sliced("fs_unlit"),
            .constant_count = 0,
            .constants = null,
            .target_count = webgpu.color_targets.len,
            .targets = &webgpu.color_targets,
        },
    }));
    defer webgpu.pipelines.get(.basic).?.release();

    var textureView = texture.createView(null);
    defer textureView.release();

    // var lightmapTextureView = lightmapTexture.createView(null);
    // defer lightmapTextureView.release();

    // var texture_views = [_]*wgpu.texture_view.TextureView{textureView, lightmapTextureView};
    var texture_views = [_]*wgpu.texture_view.TextureView{textureView};

    var projections = try std.ArrayList(model_handler.Projection).initCapacity(allocator, 32);
    defer projections.deinit(allocator);

    for (0..32) |i| {
        var proj = model_handler.Projection.createBasicModel(webgpu.device);
        proj.projection = zm.Mat4f.translation(0.0, 0.0, -@as(f32, @floatFromInt(i)) * 2.0);
        webgpu.queue.writeBuffer(proj.buffer, f32, @as(*const [16]f32, @ptrCast(&proj.projection)), 0);
        try projections.append(allocator, proj);
    }
    defer for (projections.items) |proj| {
        proj.buffer.release();
    };

    var models = try std.ArrayList(model_handler.Model).initCapacity(allocator, 32);
    defer models.deinit(allocator);

    for (0..32) |i| {
        try models.append(allocator, model_handler.Model.create(
            mesh,
            .{
                .{ .projection = proj_data, .buffer = projBuffer },
                .{ .projection = view_data, .buffer = viewBuffer },
                projections.items[i],
            },
            webgpu.pipelines.get(.basic).?,
            webgpu.device,
            sampler,
            texture_views.len,
            &texture_views
        ));
    }
    for (models.items) |model| {
        try webgpu.appendModel(.basic, model);
    }
    defer for (models.items) |*model| {
        model.destroy();
    };

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

        currentFrame = glfw.getTime();
        deltaTime = currentFrame - lastFrame;
        lastFrame = currentFrame;

        // const modelPos = model.getPos();
        // const camPos = cam.Position;
        // const dist = zm.vec.distance(modelPos, camPos);
        // std.debug.print("distance to camera: {}\n", .{dist});

        // rotation_amount -= 0.03;
        // model.model_proj.projection = zm.Mat4f.rotation(zm.Vec3f{ 0.0, 1.0, 0.0 }, rotation_amount);
        // model2.model_proj.projection = zm.Mat4f.rotation(zm.Vec3f{ 0.0, 1.0, 0.0 }, std.math.pi);
        // model2.model_proj.projection.data[7] = 0.3;
        // model.model_proj.projection.data[7] = -0.1;

        // Update uniform buffers
        view_data = cam.getViewMatrix();
        webgpu.queue.writeBuffer(viewBuffer, f32, @as(*const [16]f32, @ptrCast(&view_data)), 0);
        // webgpu.queue.writeBuffer(model.model_proj.buffer, f32, @as(*const [16]f32, @ptrCast(&model.model_proj.projection)), 0);
        // webgpu.queue.writeBuffer(model2.model_proj.buffer, f32, @as(*const [16]f32, @ptrCast(&model2.model_proj.projection)), 0);

        webgpu.draw() catch |err| {
            std.debug.print("Failed to draw frame: {}\n", .{err});
            continue;
        };
    }
}
