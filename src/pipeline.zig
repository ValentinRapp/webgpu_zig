const wgpu = @import("webgpu");
const renderer_handler = @import("renderer.zig");

// That's how static local variables are maede in zig
pub fn getBasicShaderModule(device: *wgpu.device.Device) !*wgpu.shader.ShaderModule {
    const static = struct {
        var module: ?*wgpu.shader.ShaderModule = null;
        var _device: ?*wgpu.device.Device = null;
    };
    
    // lazy initialization
    if (static.module == null) {
        var wgsl_source = wgpu.shader.ShaderSourceWGSL{
            .chain = .{ .type = .shader_source_wgsl },
            .code = wgpu.StringView.sliced(@embedFile("assets/shaders/shader.wgsl")),
        };
        static.module = device.createShaderModule(&.{
            .next = @ptrCast(&wgsl_source),
            .label = wgpu.StringView.sliced("shader"),
        });
        static._device = device;
    }
    
    if (static._device != device) {
        return error.MultipleDevicesNotSupported;
    }
    
    return static.module.?;
}

pub fn destroyBasicShaderModule(device: *wgpu.device.Device) void {
    const module = getBasicShaderModule(device) catch return;
    module.release();
}

pub const Pipeline = struct {
    pipeline: *wgpu.render_pipeline.RenderPipeline,
    sort_front_to_back: bool,
    frustum_cull: bool,
};

pub fn destroyPipelines(pipelines: []const Pipeline) void {
    for (pipelines) |*pipeline| {
        pipeline.pipeline.release();
    }
}

pub fn createSkyboxPipeline(device: *wgpu.device.Device, surfaceFormat: wgpu.texture.TextureFormat) !Pipeline {
    const color_targets = [_]wgpu.render_pipeline.ColorTargetState{.{
        .format = surfaceFormat,
        .blend = null,
        .write_mask = wgpu.render_pipeline.ColorWriteMask.all,
    }};
    const pipeline = device.createRenderPipeline(&.{
        .label = wgpu.StringView.sliced("skybox_pipeline"),
        .layout = null,
        .vertex = .{
            .module = try getBasicShaderModule(device),
            .entry_point = wgpu.StringView.sliced("vs_skybox"),
            .constant_count = 0,
            .constants = null,
            .buffer_count = renderer_handler.default_vertex_buffer_layout.len,
            .buffers = &renderer_handler.default_vertex_buffer_layout,
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
            .module = try getBasicShaderModule(device),
            .entry_point = wgpu.StringView.sliced("fs_unlit"),
            .constant_count = 0,
            .constants = null,
            .target_count = color_targets.len,
            .targets = &color_targets,
        },
    });

    return .{
        .pipeline = pipeline,
        .sort_front_to_back = true,
        .frustum_cull = false,
    };
}

pub fn createBasicPipeline(device: *wgpu.device.Device, surfaceFormat: wgpu.texture.TextureFormat) !Pipeline {
    const color_targets = [_]wgpu.render_pipeline.ColorTargetState{.{
        .format = surfaceFormat,
        .blend = null,
        .write_mask = wgpu.render_pipeline.ColorWriteMask.all,
    }};
    const pipeline = device.createRenderPipeline(&.{
        .label = wgpu.StringView.sliced("basic_pipeline"),
        .layout = null,
        .vertex = .{
            .module = try getBasicShaderModule(device),
            .entry_point = wgpu.StringView.sliced("vs_main"),
            .constant_count = 0,
            .constants = null,
            .buffer_count = renderer_handler.default_vertex_buffer_layout.len,
            .buffers = &renderer_handler.default_vertex_buffer_layout,
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
            .module = try getBasicShaderModule(device),
            .entry_point = wgpu.StringView.sliced("fs_unlit"),
            .constant_count = 0,
            .constants = null,
            .target_count = color_targets.len,
            .targets = &color_targets,
        },
    });

    return .{
        .pipeline = pipeline,
        .sort_front_to_back = true,
        .frustum_cull = true,
    };
}

pub fn createTransparencyPipeline(device: *wgpu.device.Device, surfaceFormat: wgpu.texture.TextureFormat) !Pipeline {
    const color_targets = [_]wgpu.render_pipeline.ColorTargetState{.{
        .format = surfaceFormat,
        .blend = &.{
            .color = .{
                .src_factor = .src_alpha,
                .dst_factor = .one_minus_src_alpha,
                .operation = .add,
            },
            .alpha = .{
                .src_factor = .one,
                .dst_factor = .one_minus_src_alpha,
                .operation = .add,
            },
        },
        .write_mask = wgpu.render_pipeline.ColorWriteMask.all,
    }};
    const pipeline = device.createRenderPipeline(&.{
        .label = wgpu.StringView.sliced("transparent_pipeline"),
        .layout = null,
        .vertex = .{
            .module = try getBasicShaderModule(device),
            .entry_point = wgpu.StringView.sliced("vs_main"),
            .constant_count = 0,
            .constants = null,
            .buffer_count = renderer_handler.default_vertex_buffer_layout.len,
            .buffers = &renderer_handler.default_vertex_buffer_layout,
        },
        .primitive = .{
            .topology = .triangle_list,
            .front_face = .counter_clockwise,
            .cull_mode = .back,
        },
        .depth_stencil = &.{
            .format = .depth24_plus,
            .depth_write_enabled = .false,
            .depth_compare = .less,
        },
        .multisample = .{},
        .fragment = &.{
            .module = try getBasicShaderModule(device),
            .entry_point = wgpu.StringView.sliced("fs_unlit"),
            .constant_count = 0,
            .constants = null,
            .target_count = color_targets.len,
            .targets = &color_targets,
        },
    });

    return .{
        .pipeline = pipeline,
        .sort_front_to_back = false,
        .frustum_cull = true,
    };
}