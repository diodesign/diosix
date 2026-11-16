// Intrusive red-black tree providing O(log N) ordered storage and O(1) min.
//
// Copyright (c) 2024-2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub const RBColor = enum { red, black };

// Intrusive red-black tree with cached leftmost minimum node.
// compareFn returns -1 if a < b, 0 if a == b, and 1 if a > b.
pub fn RedBlackTree(
    comptime T: type,
    comptime compareFn: fn (a: T, b: T) i8,
) type {
    return struct {
        const Self = @This();

        pub const Node = struct {
            parent: ?*Node = null,
            left: ?*Node = null,
            right: ?*Node = null,
            color: RBColor = .red,
            contents: T,
        };

        root: ?*Node = null,
        leftmost: ?*Node = null,

        pub fn init(self: *Self) void {
            self.root = null;
            self.leftmost = null;
        }

        inline fn isBlack(node: ?*Node) bool {
            return node == null or node.?.color == .black;
        }

        // Insert the given node into the tree and update cached leftmost.
        pub fn insert(self: *Self, node: *Node) void {
            node.left = null;
            node.right = null;
            node.color = .red;

            var y: ?*Node = null;
            var x = self.root;
            var is_leftmost = true;
            var go_left = true;

            while (x) |ptr| {
                y = ptr;
                go_left = compareFn(node.contents, ptr.contents) < 0;
                if (go_left) {
                    x = ptr.left;
                } else {
                    x = ptr.right;
                    is_leftmost = false;
                }
            }

            node.parent = y;
            if (y == null) {
                self.root = node;
            } else if (go_left) {
                y.?.left = node;
            } else {
                y.?.right = node;
            }

            if (is_leftmost) self.leftmost = node;
            self.insertFixup(node);
        }

        fn insertFixup(self: *Self, node: *Node) void {
            var z = node;
            while (z.parent != null and z.parent.?.color == .red) {
                const p = z.parent.?;
                const gp = p.parent.?;
                if (p == gp.left) {
                    const y = gp.right;
                    if (y != null and y.?.color == .red) {
                        p.color = .black;
                        y.?.color = .black;
                        gp.color = .red;
                        z = gp;
                    } else {
                        if (z == p.right) {
                            z = p;
                            self.leftRotate(z);
                        }
                        z.parent.?.color = .black;
                        z.parent.?.parent.?.color = .red;
                        self.rightRotate(z.parent.?.parent.?);
                    }
                } else {
                    const y = gp.left;
                    if (y != null and y.?.color == .red) {
                        p.color = .black;
                        y.?.color = .black;
                        gp.color = .red;
                        z = gp;
                    } else {
                        if (z == p.left) {
                            z = p;
                            self.rightRotate(z);
                        }
                        z.parent.?.color = .black;
                        z.parent.?.parent.?.color = .red;
                        self.leftRotate(z.parent.?.parent.?);
                    }
                }
            }
            self.root.?.color = .black;
        }

        fn leftRotate(self: *Self, x: *Node) void {
            const y = x.right.?;
            x.right = y.left;
            if (y.left) |yl| yl.parent = x;
            y.parent = x.parent;
            if (x.parent == null) {
                self.root = y;
            } else if (x == x.parent.?.left) {
                x.parent.?.left = y;
            } else {
                x.parent.?.right = y;
            }
            y.left = x;
            x.parent = y;
        }

        fn rightRotate(self: *Self, y: *Node) void {
            const x = y.left.?;
            y.left = x.right;
            if (x.right) |xr| xr.parent = y;
            x.parent = y.parent;
            if (y.parent == null) {
                self.root = x;
            } else if (y == y.parent.?.right) {
                y.parent.?.right = x;
            } else {
                y.parent.?.left = x;
            }
            x.right = y;
            y.parent = x;
        }

        // Remove the given node from the tree and maintain cached leftmost.
        pub fn remove(self: *Self, z: *Node) void {
            if (self.leftmost == z) {
                self.leftmost = self.findNext(z);
            }

            var y = z;
            var y_original_color = y.color;
            var x: ?*Node = null;
            var x_parent: ?*Node = null;

            if (z.left == null) {
                x = z.right;
                x_parent = z.parent;
                self.transplant(z, z.right);
            } else if (z.right == null) {
                x = z.left;
                x_parent = z.parent;
                self.transplant(z, z.left);
            } else {
                y = self.minimum(z.right.?);
                y_original_color = y.color;
                x = y.right;
                if (y.parent == z) {
                    x_parent = y;
                    if (x) |xn| xn.parent = y;
                } else {
                    x_parent = y.parent;
                    self.transplant(y, y.right);
                    y.right = z.right;
                    y.right.?.parent = y;
                }
                self.transplant(z, y);
                y.left = z.left;
                y.left.?.parent = y;
                y.color = z.color;
            }

            z.parent = null;
            z.left = null;
            z.right = null;

            if (y_original_color == .black) {
                self.removeFixup(x, x_parent);
            }
        }

        fn transplant(self: *Self, u: *Node, v: ?*Node) void {
            if (u.parent == null) {
                self.root = v;
            } else if (u == u.parent.?.left) {
                u.parent.?.left = v;
            } else {
                u.parent.?.right = v;
            }
            if (v) |vn| vn.parent = u.parent;
        }

        fn removeFixup(self: *Self, x_in: ?*Node, parent_in: ?*Node) void {
            var x = x_in;
            var parent = parent_in;

            while (x != self.root and isBlack(x)) {
                const p = parent.?;
                if (x == p.left or (x == null and p.left == null)) {
                    var w = p.right;
                    if (!isBlack(w)) {
                        w.?.color = .black;
                        p.color = .red;
                        self.leftRotate(p);
                        w = p.right;
                    }
                    if (w == null or
                        (isBlack(w.?.left) and isBlack(w.?.right)))
                    {
                        if (w) |wn| wn.color = .red;
                        x = p;
                        parent = x.?.parent;
                    } else {
                        if (isBlack(w.?.right)) {
                            if (w.?.left) |wl| wl.color = .black;
                            w.?.color = .red;
                            self.rightRotate(w.?);
                            w = p.right;
                        }
                        w.?.color = p.color;
                        p.color = .black;
                        if (w.?.right) |wr| wr.color = .black;
                        self.leftRotate(p);
                        x = self.root;
                    }
                } else {
                    var w = p.left;
                    if (!isBlack(w)) {
                        w.?.color = .black;
                        p.color = .red;
                        self.rightRotate(p);
                        w = p.left;
                    }
                    if (w == null or
                        (isBlack(w.?.right) and isBlack(w.?.left)))
                    {
                        if (w) |wn| wn.color = .red;
                        x = p;
                        parent = x.?.parent;
                    } else {
                        if (isBlack(w.?.left)) {
                            if (w.?.right) |wr| wr.color = .black;
                            w.?.color = .red;
                            self.leftRotate(w.?);
                            w = p.left;
                        }
                        w.?.color = p.color;
                        p.color = .black;
                        if (w.?.left) |wl| wl.color = .black;
                        self.rightRotate(p);
                        x = self.root;
                    }
                }
            }
            if (x) |xn| xn.color = .black;
        }

        // Return the cached minimum node in O(1).
        pub inline fn findMin(self: *const Self) ?*Node {
            return self.leftmost;
        }

        fn minimum(_: *const Self, node: *Node) *Node {
            var x = node;
            while (x.left) |left| x = left;
            return x;
        }

        // Find and return the in-order successor of the given node.
        pub fn findNext(_: *const Self, node: *Node) ?*Node {
            if (node.right) |right| {
                var x = right;
                while (x.left) |left| x = left;
                return x;
            }
            var x = node;
            var y = node.parent;
            while (y != null and x == y.?.right) {
                x = y.?;
                y = y.?.parent;
            }
            return y;
        }
    };
}

fn compareU32(a: u32, b: u32) i8 {
    return switch (std.math.order(a, b)) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

const TestTree = RedBlackTree(u32, compareU32);

fn verifySubtree(
    node_opt: ?*TestTree.Node,
    expected_parent: ?*TestTree.Node,
    min_bound: ?u32,
    max_bound: ?u32,
    count_out: *usize,
) !usize {
    const node = node_opt orelse return 1;
    try std.testing.expectEqual(expected_parent, node.parent);
    if (min_bound) |lo| try std.testing.expect(node.contents > lo);
    if (max_bound) |hi| try std.testing.expect(node.contents < hi);
    if (node.color == .red) {
        try std.testing.expect(
            node.left == null or node.left.?.color == .black,
        );
        try std.testing.expect(
            node.right == null or node.right.?.color == .black,
        );
    }
    count_out.* += 1;
    const bh_left = try verifySubtree(
        node.left,
        node,
        min_bound,
        node.contents,
        count_out,
    );
    const bh_right = try verifySubtree(
        node.right,
        node,
        node.contents,
        max_bound,
        count_out,
    );
    try std.testing.expectEqual(bh_left, bh_right);
    return bh_left + @as(usize, if (node.color == .black) 1 else 0);
}

fn verifyTreeInvariants(tree: *const TestTree, expected_count: usize) !void {
    if (tree.root) |r| {
        try std.testing.expectEqual(RBColor.black, r.color);
        try std.testing.expectEqual(tree.minimum(r), tree.findMin().?);
    } else {
        try std.testing.expect(tree.findMin() == null);
    }
    var count: usize = 0;
    _ = try verifySubtree(tree.root, null, null, null, &count);
    try std.testing.expectEqual(expected_count, count);
}

test "red-black tree invariants across root, internal, and traversal removals" {
    std.testing.refAllDecls(@This());
    const testing = std.testing;
    const n_items = 128;
    var tree = TestTree{};
    try verifyTreeInvariants(&tree, 0);

    var nodes: [n_items]TestTree.Node = undefined;
    for (0..n_items) |i| {
        const key: u32 = @intCast((i * 37 + 13) % n_items);
        nodes[i] = .{ .contents = key };
        tree.insert(&nodes[i]);
        try verifyTreeInvariants(&tree, i + 1);
    }

    var prev: ?u32 = null;
    var seen: usize = 0;
    var it = tree.findMin();
    while (it) |cur| : (it = tree.findNext(cur)) {
        if (prev) |p| try testing.expect(p < cur.contents);
        prev = cur.contents;
        seen += 1;
    }
    try testing.expectEqual(@as(usize, n_items), seen);

    // Remove every even key during an in-order findNext walk (hits root and
    // two-child successor y.parent != z cases with black y).
    var remaining: usize = n_items;
    it = tree.findMin();
    while (it) |cur| {
        const next_it = tree.findNext(cur);
        if ((cur.contents & 1) == 0) {
            tree.remove(cur);
            remaining -= 1;
            try verifyTreeInvariants(&tree, remaining);
        }
        it = next_it;
    }
    try testing.expectEqual(@as(usize, n_items / 2), remaining);

    // Remove remaining odd keys from the root repeatedly until empty.
    while (tree.root) |r| {
        tree.remove(r);
        remaining -= 1;
        try verifyTreeInvariants(&tree, remaining);
    }
    try testing.expectEqual(@as(usize, 0), remaining);
}
