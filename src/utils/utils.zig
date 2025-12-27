const builtin = @import("builtin");
const wgpu = @import("webgpu");
const glfw = @import("glfw");
const main = @import("../main.zig");

/// Creates a WebGPU surface from a GLFW window (cross-platform)
pub fn createSurface(instance: *wgpu.instance.Instance, window: *glfw.Window) *wgpu.surface.Surface {
    if (comptime builtin.os.tag == .macos) {
        return createMacOSSurface(instance, window);
    } else if (comptime builtin.os.tag == .windows) {
        return createWindowsSurface(instance, window);
    } else if (comptime builtin.os.tag == .linux) {
        return createLinuxSurface(instance, window);
    } else {
        @compileError("Unsupported platform");
    }
}

fn createMacOSSurface(instance: *wgpu.instance.Instance, window: *glfw.Window) *wgpu.surface.Surface {
    const native = @cImport({
        @cDefine("GLFW_EXPOSE_NATIVE_COCOA", "1");
        @cInclude("GLFW/glfw3.h");
        @cInclude("GLFW/glfw3native.h");
        @cInclude("objc/runtime.h");
        @cInclude("objc/message.h");
    });

    const ns_window = native.glfwGetCocoaWindow(@ptrCast(window));

    const MsgSendFn = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque;
    const MsgSendFn3 = *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) void;
    const msgSend: MsgSendFn = @ptrCast(&native.objc_msgSend);
    const msgSend3: MsgSendFn3 = @ptrCast(&native.objc_msgSend);

    const contentView = msgSend(ns_window, native.sel_registerName("contentView"));
    const cls = native.objc_getClass("CAMetalLayer");
    const layer = msgSend(cls, native.sel_registerName("layer"));
    msgSend3(contentView, native.sel_registerName("setLayer:"), layer);

    const SurfaceSourceMetalLayer = extern struct {
        chain: wgpu.ChainedStruct,
        layer: ?*anyopaque,
    };

    var metal_surface = SurfaceSourceMetalLayer{
        .chain = .{ .type = .surface_source_metal_layer },
        .layer = layer,
    };

    return instance.createSurface(&.{
        .next = @ptrCast(&metal_surface),
        .label = "surface",
    });
}

fn createWindowsSurface(instance: *wgpu.instance.Instance, window: *glfw.Window) *wgpu.surface.Surface {
    const native = @cImport({
        @cDefine("GLFW_EXPOSE_NATIVE_WIN32", "1");
        @cInclude("GLFW/glfw3.h");
        @cInclude("GLFW/glfw3native.h");
    });

    const hwnd = native.glfwGetWin32Window(@ptrCast(window));
    const hinstance = native.GetModuleHandleW(null);

    const SurfaceSourceWindowsHWND = extern struct {
        chain: wgpu.ChainedStruct,
        hinstance: ?*anyopaque,
        hwnd: ?*anyopaque,
    };

    var win_surface = SurfaceSourceWindowsHWND{
        .chain = .{ .type = .surface_source_windows_hwnd },
        .hinstance = hinstance,
        .hwnd = hwnd,
    };

    return instance.createSurface(&.{
        .next = @ptrCast(&win_surface),
        .label = "surface",
    });
}

fn createLinuxSurface(instance: *wgpu.instance.Instance, window: *glfw.Window) *wgpu.surface.Surface {
    const native = @cImport({
        @cDefine("GLFW_EXPOSE_NATIVE_X11", "1");
        @cDefine("GLFW_EXPOSE_NATIVE_WAYLAND", "1");
        @cInclude("GLFW/glfw3.h");
        @cInclude("GLFW/glfw3native.h");
    });

    // Try X11 first (more common)
    if (native.glfwGetX11Display()) |display| {
        const x11_window = native.glfwGetX11Window(@ptrCast(window));

        const SurfaceSourceXlibWindow = extern struct {
            chain: wgpu.ChainedStruct,
            display: ?*anyopaque,
            window: u64,
        };

        var x11_surface = SurfaceSourceXlibWindow{
            .chain = .{ .type = .surface_source_xlib_window },
            .display = display,
            .window = x11_window,
        };

        return instance.createSurface(&.{
            .next = @ptrCast(&x11_surface),
            .label = "surface",
        });
    }

    // Fallback to Wayland
    const display = native.glfwGetWaylandDisplay();
    const wayland_surface = native.glfwGetWaylandWindow(@ptrCast(window));

    const SurfaceSourceWaylandSurface = extern struct {
        chain: wgpu.ChainedStruct,
        display: ?*anyopaque,
        surface: ?*anyopaque,
    };

    var wl_surface = SurfaceSourceWaylandSurface{
        .chain = .{ .type = .surface_source_wayland_surface },
        .display = display,
        .surface = wayland_surface,
    };

    return instance.createSurface(&.{
        .next = @ptrCast(&wl_surface),
        .label = "surface",
    });
}

var cursor_enabled: bool = false;

pub fn character_callback(window: ?*glfw.Window, codepoint: u32) callconv(.c) void {
    if (codepoint == 99) { // 'c' key to toggle cursor (idk which macro it refers to)
        cursor_enabled = !cursor_enabled;
        if (cursor_enabled) {
            glfw.setInputMode(window, glfw.Cursor, glfw.CursorNormal);
        } else {
            glfw.setInputMode(window, glfw.Cursor, glfw.CursorDisabled);
        }
    }
}

pub fn processInput(window: ?*glfw.Window, deltaTime: f64) void {
    if (glfw.getKey(window, glfw.KeyEscape) == glfw.Press) {
        glfw.setWindowShouldClose(window, true);
    }

    if (glfw.getKey(window, glfw.KeyW) == glfw.Press) {
        main.cam.processKeyboard(.FORWARD, @floatCast(deltaTime));
    }
    if (glfw.getKey(window, glfw.KeyS) == glfw.Press) {
        main.cam.processKeyboard(.BACKWARD, @floatCast(deltaTime));
    }
    if (glfw.getKey(window, glfw.KeyA) == glfw.Press) {
        main.cam.processKeyboard(.LEFT, @floatCast(deltaTime));
    }
    if (glfw.getKey(window, glfw.KeyD) == glfw.Press) {
        main.cam.processKeyboard(.RIGHT, @floatCast(deltaTime));
    }
}

var lastX: f32 = undefined;
var lastY: f32 = undefined;
var firstMouse = true;

pub fn mouseCallback(window: ?*glfw.Window, xpos: f64, ypos: f64) callconv(.c) void {
    _ = window;
    if (firstMouse) {
        lastX = @floatCast(xpos);
        lastY = @floatCast(ypos);
        firstMouse = false;
    }

    const xoffset = @as(f32, @floatCast(xpos)) - lastX;
    const yoffset = lastY - @as(f32, @floatCast(ypos));
    lastX = @floatCast(xpos);
    lastY = @floatCast(ypos);

    main.cam.processMouseMovement(xoffset, yoffset);
}