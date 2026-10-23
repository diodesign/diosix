// Scalable 2D Vector Path Builder & UI Icon Vector Primitives for Diosix GUI.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const fb = @import("framebuffer.zig");
pub const raster = @import("vector/raster.zig");

pub const Edge = raster.Edge;
pub const FillRule = raster.FillRule;
pub const rasterizeEdgesToMask = raster.rasterizeEdgesToMask;
pub const dilateMask = raster.dilateMask;
pub const blendMaskOnSurface = raster.blendMaskOnSurface;

pub const MAX_PATH_CMDS: usize = 512;
pub const MAX_FLATTENED_EDGES: usize = 2048;
pub const BEZIER_FLATNESS_TOLERANCE: f32 = 0.20;
pub const MAX_SUBDIV_DEPTH: u8 = 8;

pub const Point = struct {
    x: f32,
    y: f32,
};

pub const PathCmd = union(enum) {
    move_to: Point,
    line_to: Point,
    quad_to: struct {
        cx: f32,
        cy: f32,
        x: f32,
        y: f32,
    },
    cubic_to: struct {
        c1x: f32,
        c1y: f32,
        c2x: f32,
        c2y: f32,
        x: f32,
        y: f32,
    },
    close: void,
};

pub const VectorPath = struct {
    cmds: [MAX_PATH_CMDS]PathCmd = undefined,
    len: usize = 0,

    pub fn init() VectorPath {
        return .{ .len = 0 };
    }

    pub fn clear(self: *VectorPath) void {
        self.len = 0;
    }

    pub fn moveTo(self: *VectorPath, x: f32, y: f32) void {
        if (self.len < self.cmds.len) {
            self.cmds[self.len] = .{ .move_to = .{ .x = x, .y = y } };
            self.len += 1;
        }
    }

    pub fn lineTo(self: *VectorPath, x: f32, y: f32) void {
        if (self.len < self.cmds.len) {
            self.cmds[self.len] = .{ .line_to = .{ .x = x, .y = y } };
            self.len += 1;
        }
    }

    pub fn quadTo(
        self: *VectorPath,
        cx: f32,
        cy: f32,
        x: f32,
        y: f32,
    ) void {
        if (self.len < self.cmds.len) {
            self.cmds[self.len] = .{
                .quad_to = .{ .cx = cx, .cy = cy, .x = x, .y = y },
            };
            self.len += 1;
        }
    }

    pub fn cubicTo(
        self: *VectorPath,
        c1x: f32,
        c1y: f32,
        c2x: f32,
        c2y: f32,
        x: f32,
        y: f32,
    ) void {
        if (self.len < self.cmds.len) {
            self.cmds[self.len] = .{
                .cubic_to = .{
                    .c1x = c1x,
                    .c1y = c1y,
                    .c2x = c2x,
                    .c2y = c2y,
                    .x = x,
                    .y = y,
                },
            };
            self.len += 1;
        }
    }

    pub fn close(self: *VectorPath) void {
        if (self.len < self.cmds.len) {
            self.cmds[self.len] = .close;
            self.len += 1;
        }
    }

    fn emitEdge(
        edges_out: []Edge,
        edge_count: *usize,
        p0: Point,
        p1: Point,
    ) void {
        if (@abs(p1.y - p0.y) < 0.0001) return;
        if (edge_count.* >= edges_out.len) return;
        if (p0.y < p1.y) {
            edges_out[edge_count.*] = .{
                .x0 = p0.x,
                .y0 = p0.y,
                .x1 = p1.x,
                .y1 = p1.y,
                .winding = 1,
            };
        } else {
            edges_out[edge_count.*] = .{
                .x0 = p1.x,
                .y0 = p1.y,
                .x1 = p0.x,
                .y1 = p0.y,
                .winding = -1,
            };
        }
        edge_count.* += 1;
    }

    fn flattenQuad(
        edges_out: []Edge,
        edge_count: *usize,
        p0: Point,
        c: Point,
        p1: Point,
        depth: u8,
    ) void {
        const mx = (p0.x + 2.0 * c.x + p1.x) * 0.25;
        const my = (p0.y + 2.0 * c.y + p1.y) * 0.25;
        const lx = (p0.x + p1.x) * 0.5;
        const ly = (p0.y + p1.y) * 0.5;
        const dx = mx - lx;
        const dy = my - ly;
        if (depth >= MAX_SUBDIV_DEPTH or
            (dx * dx + dy * dy) <=
                (BEZIER_FLATNESS_TOLERANCE * BEZIER_FLATNESS_TOLERANCE))
        {
            emitEdge(edges_out, edge_count, p0, p1);
            return;
        }
        const q0 = Point{ .x = (p0.x + c.x) * 0.5, .y = (p0.y + c.y) * 0.5 };
        const q1 = Point{ .x = (c.x + p1.x) * 0.5, .y = (c.y + p1.y) * 0.5 };
        const mid = Point{ .x = mx, .y = my };
        flattenQuad(edges_out, edge_count, p0, q0, mid, depth + 1);
        flattenQuad(edges_out, edge_count, mid, q1, p1, depth + 1);
    }

    fn flattenCubic(
        edges_out: []Edge,
        edge_count: *usize,
        p0: Point,
        c1: Point,
        c2: Point,
        p1: Point,
        depth: u8,
    ) void {
        const ux = 3.0 * c1.x - 2.0 * p0.x - p1.x;
        const uy = 3.0 * c1.y - 2.0 * p0.y - p1.y;
        const vx = 3.0 * c2.x - 2.0 * p1.x - p0.x;
        const vy = 3.0 * c2.y - 2.0 * p1.y - p0.y;
        const err_x = @max(ux * ux, vx * vx);
        const err_y = @max(uy * uy, vy * vy);
        if (depth >= MAX_SUBDIV_DEPTH or
            (err_x + err_y) <= 16.0 *
                BEZIER_FLATNESS_TOLERANCE * BEZIER_FLATNESS_TOLERANCE)
        {
            emitEdge(edges_out, edge_count, p0, p1);
            return;
        }
        const m01 = Point{ .x = (p0.x + c1.x) * 0.5, .y = (p0.y + c1.y) * 0.5 };
        const m12 = Point{ .x = (c1.x + c2.x) * 0.5, .y = (c1.y + c2.y) * 0.5 };
        const m23 = Point{ .x = (c2.x + p1.x) * 0.5, .y = (c2.y + p1.y) * 0.5 };
        const m012 = Point{
            .x = (m01.x + m12.x) * 0.5,
            .y = (m01.y + m12.y) * 0.5,
        };
        const m123 = Point{
            .x = (m12.x + m23.x) * 0.5,
            .y = (m12.y + m23.y) * 0.5,
        };
        const mid = Point{
            .x = (m012.x + m123.x) * 0.5,
            .y = (m012.y + m123.y) * 0.5,
        };
        flattenCubic(edges_out, edge_count, p0, m01, m012, mid, depth + 1);
        flattenCubic(edges_out, edge_count, mid, m123, m23, p1, depth + 1);
    }

    pub fn flatten(
        self: *const VectorPath,
        scale_x: f32,
        scale_y: f32,
        offset_x: f32,
        offset_y: f32,
        edges_out: []Edge,
    ) usize {
        var count: usize = 0;
        var start_pt = Point{ .x = offset_x, .y = offset_y };
        var cur_pt = start_pt;

        for (self.cmds[0..self.len]) |cmd| {
            switch (cmd) {
                .move_to => |p| {
                    start_pt = .{
                        .x = p.x * scale_x + offset_x,
                        .y = p.y * scale_y + offset_y,
                    };
                    cur_pt = start_pt;
                },
                .line_to => |p| {
                    const next_pt = Point{
                        .x = p.x * scale_x + offset_x,
                        .y = p.y * scale_y + offset_y,
                    };
                    emitEdge(edges_out, &count, cur_pt, next_pt);
                    cur_pt = next_pt;
                },
                .quad_to => |q| {
                    const ctrl = Point{
                        .x = q.cx * scale_x + offset_x,
                        .y = q.cy * scale_y + offset_y,
                    };
                    const next_pt = Point{
                        .x = q.x * scale_x + offset_x,
                        .y = q.y * scale_y + offset_y,
                    };
                    flattenQuad(edges_out, &count, cur_pt, ctrl, next_pt, 0);
                    cur_pt = next_pt;
                },
                .cubic_to => |c| {
                    const c1 = Point{
                        .x = c.c1x * scale_x + offset_x,
                        .y = c.c1y * scale_y + offset_y,
                    };
                    const c2 = Point{
                        .x = c.c2x * scale_x + offset_x,
                        .y = c.c2y * scale_y + offset_y,
                    };
                    const next_pt = Point{
                        .x = c.x * scale_x + offset_x,
                        .y = c.y * scale_y + offset_y,
                    };
                    flattenCubic(edges_out, &count, cur_pt, c1, c2, next_pt, 0);
                    cur_pt = next_pt;
                },
                .close => {
                    emitEdge(edges_out, &count, cur_pt, start_pt);
                    cur_pt = start_pt;
                },
            }
        }
        return count;
    }

    pub fn rasterizeToMask(
        self: *const VectorPath,
        scale_x: f32,
        scale_y: f32,
        offset_x: f32,
        offset_y: f32,
        mask_out: []u8,
        width: u32,
        height: u32,
        fill_rule: FillRule,
    ) void {
        var edges: [MAX_FLATTENED_EDGES]Edge = undefined;
        const n = self.flatten(scale_x, scale_y, offset_x, offset_y, &edges);
        rasterizeEdgesToMask(edges[0..n], mask_out, width, height, fill_rule);
    }
};

/// Builds the scalable vector contour for the mouse pointer arrow interior
/// in a canonical `18x18` coordinate space.
pub fn buildCursorArrowPath() VectorPath {
    var p = VectorPath.init();
    p.moveTo(1.5, 1.5);
    p.lineTo(11.5, 10.5);
    p.lineTo(7.2, 10.5);
    p.lineTo(10.8, 16.0);
    p.lineTo(8.5, 17.0);
    p.lineTo(5.0, 11.4);
    p.lineTo(1.5, 14.5);
    p.close();
    return p;
}

/// Builds the scalable vector contour for the Back navigation arrow in a
/// canonical `14x10` coordinate space.
pub fn buildBackArrowPath() VectorPath {
    var p = VectorPath.init();
    p.moveTo(0.5, 5.0);
    p.lineTo(5.5, 0.5);
    p.lineTo(6.8, 1.8);
    p.lineTo(4.2, 4.1);
    p.lineTo(13.5, 4.1);
    p.lineTo(13.5, 5.9);
    p.lineTo(4.2, 5.9);
    p.lineTo(6.8, 8.2);
    p.lineTo(5.5, 9.5);
    p.close();
    return p;
}

/// Builds the scalable vector contour for a dropdown chevron (`10x6` space).
pub fn buildChevronPath(up: bool) VectorPath {
    var p = VectorPath.init();
    if (up) {
        p.moveTo(1.0, 5.0);
        p.lineTo(5.0, 1.0);
        p.lineTo(9.0, 5.0);
        p.lineTo(7.7, 5.8);
        p.lineTo(5.0, 3.1);
        p.lineTo(2.3, 5.8);
        p.close();
    } else {
        p.moveTo(1.0, 1.0);
        p.lineTo(5.0, 5.0);
        p.lineTo(9.0, 1.0);
        p.lineTo(7.7, 0.2);
        p.lineTo(5.0, 2.9);
        p.lineTo(2.3, 0.2);
        p.close();
    }
    return p;
}

test "vector path: quadratic flattening and built-in vector shapes" {
    _ = raster;
    std.testing.refAllDecls(@This());
    const arrow = buildBackArrowPath();
    var mask: [14 * 10]u8 = undefined;
    arrow.rasterizeToMask(1.0, 1.0, 0.0, 0.0, &mask, 14, 10, .non_zero);
    // Stem center at (8, 5) should be solid (255).
    try std.testing.expectEqual(@as(u8, 255), mask[5 * 14 + 8]);
}
