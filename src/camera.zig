const std = @import("std");
const zm = @import("zm");

pub const Camera_Movement = enum {
    FORWARD,
    BACKWARD,
    LEFT,
    RIGHT
};

const PI = std.math.pi;
const SPEED = 10.0;
const SENSITIVITY = std.math.degreesToRadians(0.1);

fn updateCameraVectors(self: *Camera) void {
    self.Front = zm.vec.normalize(zm.Vec3f{
        std.math.cos(self.Yaw) * std.math.cos(self.Pitch),
        std.math.sin(self.Pitch),
        std.math.sin(self.Yaw) * std.math.cos(self.Pitch),
    });
    self.Right = zm.vec.normalize(zm.vec.cross(self.Front, self.WorldUp));
    self.Up = zm.vec.normalize(zm.vec.cross(self.Right, self.Front));
}

pub const Camera = struct {
    Position: zm.Vec3f = undefined,
    Front: zm.Vec3f = undefined,
    Up: zm.Vec3f = undefined,
    Right: zm.Vec3f = undefined,
    WorldUp: zm.Vec3f = undefined,

    Yaw: f32 = undefined,
    Pitch: f32 = undefined,

    MovementSpeed: f32 = SPEED,
    MouseSensitivity: f32 = SENSITIVITY,

    pub fn getViewMatrix(self: *Camera) zm.Mat4f {
        return zm.Mat4f.lookAt(self.Position, self.Position + self.Front, self.Up);
    }

    pub fn processKeyboard(self: *Camera, direction: Camera_Movement, deltaTime: f32) void {
        const velocity = self.MovementSpeed * deltaTime;
        const velocityVector = zm.Vec3f{velocity, velocity, velocity};
        switch (direction) {
            .FORWARD => {
                self.Position += self.Front * velocityVector;
            },
            .BACKWARD => {
                self.Position -= self.Front * velocityVector;
            },
            .LEFT => {
                self.Position -= self.Right * velocityVector;
            },
            .RIGHT => {
                self.Position += self.Right * velocityVector;
            }
        }
    }

    pub fn processMouseMovement(self: *Camera, xoffset: f32, yoffset: f32) void {
        self.Yaw += xoffset * self.MouseSensitivity;
        self.Pitch += yoffset * self.MouseSensitivity;

        if (self.Pitch > PI / 2.0) {
            self.Pitch = PI / 2.0;
        }
        if (self.Pitch < -PI / 2.0) {
            self.Pitch = -PI / 2.0;
        }

        updateCameraVectors(self);
    }
};

pub fn createCamera(position: zm.Vec3f, yaw: f32, pitch: f32) Camera {
    var camera = Camera{
        .Position = position,
        .WorldUp = .{0.0, 1.0, 0.0},
        .Front = .{0.0, 0.0, -1.0},
        .Yaw = yaw,
        .Pitch = pitch,
    };
    updateCameraVectors(&camera);
    return camera;
}