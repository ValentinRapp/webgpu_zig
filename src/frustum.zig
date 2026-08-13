const zm = @import("zm");

// This file was written almost entirely by AI

/// Represents a plane in the form ax + by + cz + d = 0
const Plane = struct {
    normal: zm.Vec3f,
    d: f32,

    /// Normalize the plane equation
    pub fn normalize(self: *Plane) void {
        const len = self.normal.len();
        if (len > 0.0001) {
            self.normal = self.normal.norm();
            self.d /= len;
        }
    }

    /// Get signed distance from point to plane
    pub fn distanceToPoint(self: *const Plane, point: zm.Vec3f) f32 {
        return self.normal.dot(point) + self.d;
    }
};

/// Frustum with 6 planes: left, right, bottom, top, near, far
pub const Frustum = struct {
    planes: [6]Plane,

    /// Extract frustum planes from a view-projection matrix
    /// Uses the Gribb/Hartmann method for row-major matrices
    /// In row-major: data layout is [row0, row1, row2, row3]
    /// Row i is at indices i*4 to i*4+3
    pub fn fromViewProjection(vp: zm.Mat4f) Frustum {
        var frustum: Frustum = undefined;
        const m = vp.data;

        // For row-major matrix, data is [4][4]f32:
        // Row 0: m[0][0..3]
        // Row 1: m[1][0..3]
        // Row 2: m[2][0..3]
        // Row 3: m[3][0..3]

        // Gribb/Hartmann for row-major: use rows directly
        // Left plane: row3 + row0
        frustum.planes[0] = .{
            .normal = .{ .data = .{ m[3][0] + m[0][0], m[3][1] + m[0][1], m[3][2] + m[0][2] } },
            .d = m[3][3] + m[0][3],
        };
        // Right plane: row3 - row0
        frustum.planes[1] = .{
            .normal = .{ .data = .{ m[3][0] - m[0][0], m[3][1] - m[0][1], m[3][2] - m[0][2] } },
            .d = m[3][3] - m[0][3],
        };
        // Bottom plane: row3 + row1
        frustum.planes[2] = .{
            .normal = .{ .data = .{ m[3][0] + m[1][0], m[3][1] + m[1][1], m[3][2] + m[1][2] } },
            .d = m[3][3] + m[1][3],
        };
        // Top plane: row3 - row1
        frustum.planes[3] = .{
            .normal = .{ .data = .{ m[3][0] - m[1][0], m[3][1] - m[1][1], m[3][2] - m[1][2] } },
            .d = m[3][3] - m[1][3],
        };
        // Near plane: row3 + row2
        frustum.planes[4] = .{
            .normal = .{ .data = .{ m[3][0] + m[2][0], m[3][1] + m[2][1], m[3][2] + m[2][2] } },
            .d = m[3][3] + m[2][3],
        };
        // Far plane: row3 - row2
        frustum.planes[5] = .{
            .normal = .{ .data = .{ m[3][0] - m[2][0], m[3][1] - m[2][1], m[3][2] - m[2][2] } },
            .d = m[3][3] - m[2][3],
        };

        // Normalize all planes
        for (&frustum.planes) |*plane| {
            plane.normalize();
        }

        return frustum;
    }

    /// Check if an AABB intersects with the frustum
    /// Returns true if the AABB is at least partially inside the frustum
    pub fn containsAABB(self: *const Frustum, aabb: zm.AABBf) bool {
        for (self.planes) |plane| {
            // Find the positive vertex (the one furthest along the plane normal)
            const px: f32 = if (plane.normal.data[0] >= 0) aabb.max.data[0] else aabb.min.data[0];
            const py: f32 = if (plane.normal.data[1] >= 0) aabb.max.data[1] else aabb.min.data[1];
            const pz: f32 = if (plane.normal.data[2] >= 0) aabb.max.data[2] else aabb.min.data[2];

            // If the positive vertex is outside this plane, the AABB is fully outside
            if (plane.distanceToPoint(.{ .data = .{ px, py, pz } }) < 0) {
                return false;
            }
        }
        return true;
    }
};
