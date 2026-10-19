// Intrusive red-black tree providing O(log N) ordered storage.
//
// Copyright (c) 2024-2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub const RBColor = enum { red, black };

// Intrusive red-black tree providing O(log N) ordered storage.
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

        root: ?*Node,

        pub fn init(self: *Self) void {
            self.root = null;
        }

        inline fn isBlack(node: ?*Node) bool {
            return node == null or node.?.color == .black;
        }

        // Insert the given node into the tree.
        pub fn insert(self: *Self, node: *Node) void {
            node.left = null;
            node.right = null;
            node.color = .red;

            var y: ?*Node = null;
            var x = self.root;

            while (x) |ptr| {
                y = ptr;
                if (compareFn(node.contents, ptr.contents) < 0) {
                    x = ptr.left;
                } else {
                    x = ptr.right;
                }
            }

            node.parent = y;
            if (y == null) {
                self.root = node;
            } else if (compareFn(node.contents, y.?.contents) < 0) {
                y.?.left = node;
            } else {
                y.?.right = node;
            }

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

        // Remove the given node from the tree.
        pub fn remove(self: *Self, z: *Node) void {
            var y = z;
            var y_original_color = y.color;
            var x: ?*Node = null;

            if (z.left == null) {
                x = z.right;
                self.transplant(z, z.right);
            } else if (z.right == null) {
                x = z.left;
                self.transplant(z, z.left);
            } else {
                y = self.minimum(z.right.?);
                y_original_color = y.color;
                x = y.right;
                if (y.parent == z) {
                    if (x) |xn| xn.parent = y;
                } else {
                    self.transplant(y, y.right);
                    y.right = z.right;
                    y.right.?.parent = y;
                }
                self.transplant(z, y);
                y.left = z.left;
                y.left.?.parent = y;
                y.color = z.color;
            }

            if (y_original_color == .black) {
                self.removeFixup(x, y.parent);
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

        // Find and return the node with the minimum value.
        pub fn findMin(self: *Self) ?*Node {
            if (self.root) |root| return self.minimum(root);
            return null;
        }

        fn minimum(_: *Self, node: *Node) *Node {
            var x = node;
            while (x.left) |left| x = left;
            return x;
        }

        // Find and return the in-order successor of the given node.
        pub fn findNext(_: *Self, node: *Node) ?*Node {
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

test "red-black tree basics" {
    std.testing.refAllDecls(@This());
    const testing = std.testing;
    const Tree = RedBlackTree(u32, compareU32);
    const Node = Tree.Node;
    var tree: Tree = undefined;
    tree.init();
    try testing.expect(tree.findMin() == null);
    const values = [_]u32{ 10, 20, 30, 15, 25, 5, 1 };
    var nodes: [values.len]Node = undefined;
    for (values, 0..) |v, i| {
        nodes[i] = .{ .contents = v };
        tree.insert(&nodes[i]);
    }
    const min = tree.findMin();
    try testing.expect(min != null and min.?.contents == 1);
    const next = tree.findNext(min.?);
    try testing.expect(next != null and next.?.contents == 5);
    for (&nodes) |*n| tree.remove(n);
    try testing.expect(tree.root == null);
}
