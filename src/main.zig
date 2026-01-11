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

const pip_i = enum {
    skybox,
    basic,
    transparent,
};

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

    var renderer = try renderer_handler.Renderer.create(
        allocator,
        window,
        width,
        height,
        sampler_descriptor,
        zm.Mat4f.perspective(std.math.degreesToRadians(70.0), @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height)), 0.1, 100.0),
        cam.getViewMatrix(),
    );
    defer renderer.destroy();

    const pipelines = [_]pipeline_handler.Pipeline{
        try pipeline_handler.createSkyboxPipeline(renderer.device, renderer.surface_format),
        try pipeline_handler.createBasicPipeline(renderer.device, renderer.surface_format),
        try pipeline_handler.createTransparencyPipeline(renderer.device, renderer.surface_format),
    };
    defer pipeline_handler.destroyBasicShaderModule(renderer.device);
    defer pipeline_handler.destroyPipelines(&pipelines);

    try renderer.setPipelines(&pipelines);

    try renderer.setSkybox(&pipelines[@intFromEnum(pip_i.skybox)], "src/assets/textures/skybox.jpg");

    // var lightmapTexture = try texture_handler.loadTexture("src/assets/textures/dust2lightmap.jpg", .color, renderer.device, renderer.queue);
    // defer lightmapTexture.release();

    var mesh_data = mesh_handler.Mesh.fromFile(allocator, @embedFile("assets/models/obamid.obj")) catch |err| {
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

    var projections: [32]renderer_handler.Transformation_Mat = undefined;

    for (0..32) |i| {
        const proj = renderer_handler.Transformation_Mat.createModel(
            renderer.device,
            1.0,
            .{ 0.0, 0.0, -@as(f32, @floatFromInt(i)) * 2.0 },
            zm.Mat4f.identity(),
        );
        projections[i] = proj;
    }
    defer for (projections) |proj| {
        proj.buffer.release();
    };

    var models: [32]model_handler.Model = undefined;

    const textures_bind_group = texture_handler.createTextureBindGroup(
        texture_views.len,
        pipelines[@intFromEnum(pip_i.basic)].pipeline,
        renderer.device,
        1,
        renderer.sampler,
        &texture_views,
    );

    for (0..32) |i| {
        models[i] = try model_handler.Model.create(
            mesh,
            .{
                renderer.projection,
                renderer.view,
                projections[i],
            },
            pipelines[@intFromEnum(pip_i.basic)].pipeline,
            model_handler.createProjectionsBindGroup(
                pipelines[@intFromEnum(pip_i.basic)].pipeline,
                renderer.device,
                0,
                .{ renderer.projection.buffer, renderer.view.buffer, projections[i].buffer },
            ),
            textures_bind_group,
        );
    }
    try renderer.setModels(&pipelines[@intFromEnum(pip_i.basic)], &models);
    defer {
        var proj_bind_groups: [32]*wgpu.bind_group.BindGroup = undefined;
        for (0..32) |i| {
            proj_bind_groups[i] = models[i].bind_groups[0];
        }
        utils.releaseBindGroups(&proj_bind_groups);
    }

    const transparent_texture_views = try texture_handler.texViewsFromPaths(1, .{"src/assets/textures/amogos.png"}, .{.color}, renderer.device, renderer.queue);
    defer for (transparent_texture_views) |view| {
        view.release();
    };

    var trans_projections: [32]renderer_handler.Transformation_Mat = undefined;

    for (0..32) |i| {
        const proj = renderer_handler.Transformation_Mat.createModel(
            renderer.device,
            1.0,
            .{ @as(f32, @floatFromInt(i)) * 2.0, 0.0, -@as(f32, @floatFromInt(i)) * 2.0 },
            zm.Mat4f.identity(),
        );
        trans_projections[i] = proj;
    }
    defer for (trans_projections) |proj| {
        proj.buffer.release();
    };

    var trans_models: [32]model_handler.Model = undefined;

    const transparent_textures_bind_group = texture_handler.createTextureBindGroup(
        transparent_texture_views.len,
        pipelines[@intFromEnum(pip_i.transparent)].pipeline,
        renderer.device,
        1,
        renderer.sampler,
        &transparent_texture_views,
    );
    defer utils.releaseBindGroups(&.{ textures_bind_group, transparent_textures_bind_group });

    for (0..32) |i| {
        trans_models[i] = try model_handler.Model.create(
            mesh,
            .{
                renderer.projection,
                renderer.view,
                trans_projections[i],
            },
            pipelines[@intFromEnum(pip_i.transparent)].pipeline,
            model_handler.createProjectionsBindGroup(
                pipelines[@intFromEnum(pip_i.transparent)].pipeline,
                renderer.device,
                0,
                .{ renderer.projection.buffer, renderer.view.buffer, trans_projections[i].buffer },
            ),
            transparent_textures_bind_group,
        );
    }
    try renderer.setModels(&pipelines[@intFromEnum(pip_i.transparent)], &trans_models);
    defer {
        var proj_bind_groups: [32]*wgpu.bind_group.BindGroup = undefined;
        for (0..32) |i| {
            proj_bind_groups[i] = trans_models[i].bind_groups[0];
        }
        utils.releaseBindGroups(&proj_bind_groups);
    }
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

        // rotation_amount -= 0.03;
        // model.model_proj.projection = zm.Mat4f.rotation(zm.Vec3f{ 0.0, 1.0, 0.0 }, rotation_amount);
        // model2.model_proj.projection = zm.Mat4f.rotation(zm.Vec3f{ 0.0, 1.0, 0.0 }, std.math.pi);
        // model2.model_proj.projection.data[7] = 0.3;
        // model.model_proj.projection.data[7] = -0.1;

        // Update uniform buffers
        renderer.updateView(cam.getViewMatrix());
        // renderer.queue.writeBuffer(model.model_proj.buffer, f32, @as(*const [16]f32, @ptrCast(&model.model_proj.projection)), 0);
        // renderer.queue.writeBuffer(model2.model_proj.buffer, f32, @as(*const [16]f32, @ptrCast(&model2.model_proj.projection)), 0);

        renderer.draw(cam.Position) catch |err| {
            std.debug.print("Failed to draw frame: {}\n", .{err});
            continue;
        };
    }
}
