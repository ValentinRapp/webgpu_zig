const std = @import("std");
const builtin = @import("builtin");
const glfw = @import("glfw");
const wgpu = @import("webgpu");
const utils = @import("utils/utils.zig");
const camera = @import("camera.zig");
const zm = @import("zm");
const renderer_handler = @import("renderer.zig");
const mesh_handler = @import("mesh.zig");
const model_handler = @import("model.zig");
const zstbi = @import("zstbi");
const texture_handler = @import("texture.zig");
const pipeline_handler = @import("pipeline.zig");

// pub var width = 1710 * 1;
// pub var height = 1107 * 1;
pub var width: u32 = 1920;
pub var height: u32 = 1080;
// pub var width = 1280;
// pub var height = 720;

// pub var width: u32 = 1280;
// pub var height: u32 = 720;
pub var framebuffer_resized = false;

pub var cam = camera.createCamera(.{ .data = .{ 0.0, 0.5, 3.0 } }, -std.math.pi / 2.0, 0.0);

const pip_i = enum {
    skybox,
    basic,
    transparent,
};

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    zstbi.init(init.io, allocator);
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

    var renderer = try renderer_handler.Renderer.create(
        allocator,
        window,
        width,
        height,
        sampler_descriptor,
        zm.Mat4f.perspectiveRH(std.math.degreesToRadians(70.0), @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height)), 0.1, 100.0),
        cam.getViewMatrix(),
    );
    defer renderer.destroy();

    const pipelines = [_]pipeline_handler.Pipeline{
        try pipeline_handler.createSkyboxPipeline(renderer.device, renderer.surface_format),
        try pipeline_handler.createBasicPipeline(renderer.device, renderer.surface_format),
        // try pipeline_handler.createTransparencyPipeline(renderer.device, renderer.surface_format),
    };
    defer pipeline_handler.destroyBasicShaderModule(renderer.device);
    defer pipeline_handler.destroyPipelines(&pipelines);

    try renderer.setPipelines(&pipelines);

    try renderer.setSkybox(&pipelines[@intFromEnum(pip_i.skybox)], "src/assets/textures/skybox.jpg");

    // var lightmapTexture = try texture_handler.loadTexture("src/assets/textures/dust2lightmap.jpg", .color, renderer.device, renderer.queue);
    // defer lightmapTexture.release();

    var mesh_data = mesh_handler.Mesh.fromFile(allocator, @embedFile("assets/models/dragon.obj")) catch |err| {
        std.debug.print("Failed to load model: {}\n", .{err});
        return err;
    };
    defer mesh_data.destroy(allocator);

    var mesh = mesh_handler.WgpuMesh.create(mesh_data, renderer.device);
    defer mesh.destroy();

    const texture_views = try texture_handler.texViewsFromPaths(1, .{"src/assets/textures/obama.png"}, .{.color}, renderer.device, renderer.queue);
    defer for (texture_views) |view| {
        view.release();
    };

    var projection = renderer_handler.Transformation_Mat.createModel(
        renderer.device,
        1.0,
        .{ .data = .{ 0.0, 0.0, 0.0 } },
        zm.Mat4f.identity(),
    );
    defer projection.buffer.release();

    var model = try model_handler.Model.create(
        mesh,
        .{
            renderer.projection,
            renderer.view,
            projection,
        },
        pipelines[@intFromEnum(pip_i.basic)].pipeline,
        model_handler.createProjectionsBindGroup(
            pipelines[@intFromEnum(pip_i.basic)].pipeline,
            renderer.device,
            0,
            .{ renderer.projection.buffer, renderer.view.buffer, projection.buffer },
        ),
        texture_handler.createTextureBindGroup(
            texture_views.len,
            pipelines[@intFromEnum(pip_i.basic)].pipeline,
            renderer.device,
            1,
            renderer.sampler,
            &texture_views,
        ),
    );
    defer utils.releaseBindGroups(&model.bind_groups);

    try renderer.appendModel(&pipelines[@intFromEnum(pip_i.basic)], model);

    defer renderer.destroyModels();

    std.debug.print("WebGPU initialized successfully!\n", .{});

    var lastFrame = glfw.getTime();
    var currentFrame: f64 = undefined;
    var deltaTime: f64 = undefined;

    // Main loop
    while (!glfw.windowShouldClose(window)) {
        glfw.pollEvents();

        utils.processInput(window, deltaTime);

        if (framebuffer_resized) {
            try renderer.resize(width, height);
            framebuffer_resized = false;
        }

        currentFrame = glfw.getTime();
        deltaTime = currentFrame - lastFrame;
        lastFrame = currentFrame;

        // Update uniform buffers
        renderer.updateView(cam.getViewMatrix());

        renderer.draw(cam.Position) catch |err| {
            std.debug.print("Failed to draw frame: {}\n", .{err});
            continue;
        };
    }
}
