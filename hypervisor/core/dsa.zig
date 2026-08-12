// general-purpose data structures and algorithms for when std isn't appropriate or possible
//
// Copyright (c) 2024-2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

// define a linked list that can arbitrarily insert and remove nodes in O(1).
// nodes can be added and removed in a FIFO or LIFO manner, too.
// take care to allocate LinkedList and Node(s) on the heap
// and not the stack if you want your list to be long-living.
// also, locking is to be handled outside this structure
// T = type of the contents of each node
pub fn LinkedList(comptime T: type) type {
    return struct {
        const Self = @This();

        // describe the nodes we'll be adding to the double-linked list
        // next and previous will be defined when added to a list
        pub const Node = struct {
            next: ?*Node,
            previous: ?*Node,
            contents: T,
        };

        start: ?*Node,
        end: ?*Node,

        pub fn init(self: *Self) void {
            self.start = null;
            self.end = null;
        }

        // insert the given node at the start of the list
        pub fn pushStart(self: *Self, node: *Node) void {
            if (self.start) |start| {
                // list was non-empty
                start.previous = node;
                node.next = start;
            } else {
                // list was empty
                self.end = node;
                node.next = null;
            }

            node.previous = null;
            self.start = node;
        }

        // insert the given node at the end of the list
        pub fn pushEnd(self: *Self, node: *Node) void {
            if (self.end) |end| {
                // list was non-empty
                end.next = node;
                node.previous = end;
            } else {
                // list was empty
                self.start = node;
                node.previous = null;
            }

            node.next = null;
            self.end = node;
        }

        // remove and return the first node from the list, or null for empty list
        pub fn popStart(self: *Self) ?*Node {
            if (self.start) |start| {
                if (start.next) |next| {
                    next.previous = null;
                    self.start = next;
                } else {
                    // list is now empty
                    self.start = null;
                    self.end = null;
                }

                start.next = null;
                start.previous = null;
                return start;
            } else return null;
        }

        // remove and return the last node from the list, or null for empty list
        pub fn popEnd(self: *Self) ?*Node {
            if (self.end) |end| {
                if (end.previous) |previous| {
                    previous.next = null;
                    self.end = previous;
                } else {
                    // list is now empty
                    self.start = null;
                    self.end = null;
                }

                end.next = null;
                end.previous = null;
                return end;
            } else return null;
        }

        // insert an node into the list after the given node
        // after = item to insert after, or null to add at the start
        // node = the node to insert
        pub fn insert(self: *Self, after: ?*Node, node: *Node) void {
            if (after) |a| {
                if (a.next) |next| {
                    // clear to insert between two existing nodes
                    next.previous = node;
                    node.next = next;
                    a.next = node;
                    node.previous = after;
                } else return self.pushEnd(node);
            } else return self.pushStart(node);
        }

        // remove the given item from the list, which must have already been added to the list
        pub fn remove(self: *Self, node: *Node) void {
            if (self.start == node) {
                _ = self.popStart();
                return;
            }
            if (self.end == node) {
                _ = self.popEnd();
                return;
            }

            // clear to remove node from between two existing nodes
            if (node.previous) |p| p.next = node.next;
            if (node.next) |n| n.previous = node.previous;
            node.previous = null;
            node.next = null;
        }

        // count and return the number of items in the list
        pub fn count(self: *const Self) usize {
            var n: usize = 0;
            var it = self.start;
            while (it) |node| {
                n += 1;
                it = node.next;
            }
            return n;
        }
    };
}

test "doubly linked list" {
    const std = @import("std");
    const testing = std.testing;
    const allocator = testing.allocator;

    const List = LinkedList(u32);
    const Node = List.Node;

    var list: List = undefined;
    list.init();

    // Test initial state and empty list operations
    try testing.expect(list.start == null);
    try testing.expect(list.end == null);
    try testing.expect(list.popStart() == null);
    try testing.expect(list.popEnd() == null);

    // Test pushStart and popStart (LIFO)
    const node1 = try allocator.create(Node);
    node1.* = .{ .next = null, .previous = null, .contents = 10 };
    list.pushStart(node1);

    try testing.expect(list.start == node1);
    try testing.expect(list.end == node1);

    const node2 = try allocator.create(Node);
    node2.* = .{ .next = null, .previous = null, .contents = 20 };
    list.pushStart(node2);

    try testing.expect(list.start == node2);
    try testing.expect(list.end == node1);
    try testing.expect(list.start.?.next == node1);
    try testing.expect(list.end.?.previous == node2);

    var popped = list.popStart();
    try testing.expect(popped == node2);
    try testing.expect(popped.?.contents == 20);
    try testing.expect(list.start == node1);
    try testing.expect(list.end == node1);

    popped = list.popStart();
    try testing.expect(popped == node1);
    try testing.expect(popped.?.contents == 10);
    try testing.expect(list.start == null);
    try testing.expect(list.end == null);

    allocator.destroy(node1);
    allocator.destroy(node2);

    // Test pushEnd and popEnd (LIFO from the other side)
    const node3 = try allocator.create(Node);
    node3.* = .{ .next = null, .previous = null, .contents = 30 };
    list.pushEnd(node3);

    try testing.expect(list.start == node3);
    try testing.expect(list.end == node3);

    const node4 = try allocator.create(Node);
    node4.* = .{ .next = null, .previous = null, .contents = 40 };
    list.pushEnd(node4);

    try testing.expect(list.start == node3);
    try testing.expect(list.end == node4);
    try testing.expect(list.start.?.next == node4);
    try testing.expect(list.end.?.previous == node3);

    popped = list.popEnd();
    try testing.expect(popped == node4);
    try testing.expect(popped.?.contents == 40);
    try testing.expect(list.start == node3);
    try testing.expect(list.end == node3);

    popped = list.popEnd();
    try testing.expect(popped == node3);
    try testing.expect(popped.?.contents == 30);
    try testing.expect(list.start == null);
    try testing.expect(list.end == null);

    allocator.destroy(node3);
    allocator.destroy(node4);

    // Test mixed push/pop (FIFO)
    const node5 = try allocator.create(Node);
    node5.* = .{ .next = null, .previous = null, .contents = 50 };
    const node6 = try allocator.create(Node);
    node6.* = .{ .next = null, .previous = null, .contents = 60 };

    list.pushEnd(node5);
    list.pushEnd(node6);

    popped = list.popStart();
    try testing.expect(popped == node5);
    try testing.expect(popped.?.contents == 50);

    popped = list.popStart();
    try testing.expect(popped == node6);
    try testing.expect(popped.?.contents == 60);
    try testing.expect(list.start == null);

    allocator.destroy(node5);
    allocator.destroy(node6);

    // Test insert
    const n100 = try allocator.create(Node);
    n100.* = .{ .next = null, .previous = null, .contents = 100 };
    const n200 = try allocator.create(Node);
    n200.* = .{ .next = null, .previous = null, .contents = 200 };
    const n300 = try allocator.create(Node);
    n300.* = .{ .next = null, .previous = null, .contents = 300 };
    const n400 = try allocator.create(Node);
    n400.* = .{ .next = null, .previous = null, .contents = 400 };

    // insert into empty list (should be like pushStart)
    list.insert(null, n200);
    try testing.expect(list.start == n200);
    try testing.expect(list.end == n200);

    // insert at the start
    list.insert(null, n100);
    try testing.expect(list.start == n100);
    try testing.expect(list.start.?.next == n200);
    try testing.expect(n200.previous == n100);

    // insert at the end
    list.insert(n200, n400);
    try testing.expect(list.end == n400);
    try testing.expect(n200.next == n400);
    try testing.expect(n400.previous == n200);

    // insert in the middle
    list.insert(n200, n300);
    try testing.expect(n200.next == n300);
    try testing.expect(n300.previous == n200);
    try testing.expect(n300.next == n400);
    try testing.expect(n400.previous == n300);

    // Test remove
    // remove from middle
    list.remove(n300);
    try testing.expect(n200.next == n400);
    try testing.expect(n400.previous == n200);

    // remove from start
    list.remove(n100);
    try testing.expect(list.start == n200);
    try testing.expect(n200.previous == null);

    // remove from end
    list.remove(n400);
    try testing.expect(list.end == n200);
    try testing.expect(n200.next == null);

    // remove last node
    list.remove(n200);
    try testing.expect(list.start == null);
    try testing.expect(list.end == null);

    allocator.destroy(n100);
    allocator.destroy(n200);
    allocator.destroy(n300);
    allocator.destroy(n400);
}

pub const RBColor = enum { red, black };

// define a red-black tree that can provide efficient ordered storage.
// take care to allocate RedBlackTree and Node(s) on the heap
// and not the stack if you want your tree to be long-living.
// locking is to be handled outside this structure.
// T = type of the contents of each node
// compareFn = function that returns -1 if a < b, 0 if a == b, and 1 if a > b
pub fn RedBlackTree(comptime T: type, comptime compareFn: fn (a: T, b: T) i8) type {
    return struct {
        const Self = @This();

        pub const Node = struct {
            parent: ?*Node,
            left: ?*Node,
            right: ?*Node,
            color: RBColor,
            contents: T,
        };

        root: ?*Node,

        pub fn init(self: *Self) void {
            self.root = null;
        }

        // insert the given node into the tree
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
                if (z.parent == z.parent.?.parent.?.left) {
                    const y = z.parent.?.parent.?.right;
                    if (y != null and y.?.color == .red) {
                        z.parent.?.color = .black;
                        y.?.color = .black;
                        z.parent.?.parent.?.color = .red;
                        z = z.parent.?.parent.?;
                    } else {
                        if (z == z.parent.?.right) {
                            z = z.parent.?;
                            self.leftRotate(z);
                        }
                        z.parent.?.color = .black;
                        z.parent.?.parent.?.color = .red;
                        self.rightRotate(z.parent.?.parent.?);
                    }
                } else {
                    const y = z.parent.?.parent.?.left;
                    if (y != null and y.?.color == .red) {
                        z.parent.?.color = .black;
                        y.?.color = .black;
                        z.parent.?.parent.?.color = .red;
                        z = z.parent.?.parent.?;
                    } else {
                        if (z == z.parent.?.left) {
                            z = z.parent.?;
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
            if (y.left != null) {
                y.left.?.parent = x;
            }
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
            if (x.right != null) {
                x.right.?.parent = y;
            }
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

        // remove the given node from the tree
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
                    if (x != null) x.?.parent = y;
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
            if (v != null) {
                v.?.parent = u.parent;
            }
        }

        fn removeFixup(self: *Self, x_in: ?*Node, parent_in: ?*Node) void {
            var x = x_in;
            var parent = parent_in;

            while (x != self.root and (x == null or x.?.color == .black)) {
                if (x == parent.?.left or (x == null and parent.?.left == null)) {
                    var w = parent.?.right;
                    if (w != null and w.?.color == .red) {
                        w.?.color = .black;
                        parent.?.color = .red;
                        self.leftRotate(parent.?);
                        w = parent.?.right;
                    }
                    if (w == null or ((w.?.left == null or w.?.left.?.color == .black) and (w.?.right == null or w.?.right.?.color == .black))) {
                        if (w != null) w.?.color = .red;
                        x = parent;
                        parent = x.?.parent;
                    } else {
                        if (w.?.right == null or w.?.right.?.color == .black) {
                            if (w.?.left) |wl| wl.color = .black;
                            w.?.color = .red;
                            self.rightRotate(w.?);
                            w = parent.?.right;
                        }
                        w.?.color = parent.?.color;
                        parent.?.color = .black;
                        if (w.?.right) |wr| wr.color = .black;
                        self.leftRotate(parent.?);
                        x = self.root;
                    }
                } else {
                    var w = parent.?.left;
                    if (w != null and w.?.color == .red) {
                        w.?.color = .black;
                        parent.?.color = .red;
                        self.rightRotate(parent.?);
                        w = parent.?.left;
                    }
                    if (w == null or ((w.?.right == null or w.?.right.?.color == .black) and (w.?.left == null or w.?.left.?.color == .black))) {
                        if (w != null) w.?.color = .red;
                        x = parent;
                        parent = x.?.parent;
                    } else {
                        if (w.?.left == null or w.?.left.?.color == .black) {
                            if (w.?.right) |wr| wr.color = .black;
                            w.?.color = .red;
                            self.leftRotate(w.?);
                            w = parent.?.left;
                        }
                        w.?.color = parent.?.color;
                        parent.?.color = .black;
                        if (w.?.left) |wl| wl.color = .black;
                        self.rightRotate(parent.?);
                        x = self.root;
                    }
                }
            }
            if (x != null) x.?.color = .black;
        }

        // find and return the node with the minimum value
        pub fn findMin(self: *Self) ?*Node {
            if (self.root) |root| {
                return self.minimum(root);
            }
            return null;
        }

        fn minimum(self: *Self, node: *Node) *Node {
            _ = self;
            var x = node;
            while (x.left) |left| {
                x = left;
            }
            return x;
        }

        // find and return the in-order successor of the given node
        pub fn findNext(self: *Self, node: *Node) ?*Node {
            _ = self;
            if (node.right) |right| {
                var x = right;
                while (x.left) |left| {
                    x = left;
                }
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
    if (a < b) return -1;
    if (a > b) return 1;
    return 0;
}

pub fn compareU64(a: u64, b: u64) i8 {
    if (a < b) return -1;
    if (a > b) return 1;
    return 0;
}

test "red-black tree basics" {
    const std = @import("std");
    const testing = std.testing;
    const allocator = testing.allocator;

    const Tree = RedBlackTree(u32, compareU32);
    const Node = Tree.Node;

    var tree: Tree = undefined;
    tree.init();

    try testing.expect(tree.findMin() == null);

    const values = [_]u32{ 10, 20, 30, 15, 25, 5, 1 };
    var nodes: [values.len]*Node = undefined;

    for (values, 0..) |v, i| {
        const n = try allocator.create(Node);
        n.* = .{
            .parent = null,
            .left = null,
            .right = null,
            .color = .red,
            .contents = v,
        };
        tree.insert(n);
        nodes[i] = n;
    }

    const min = tree.findMin();
    try testing.expect(min != null);
    try testing.expect(min.?.contents == 1);

    // remove nodes
    for (nodes) |n| {
        tree.remove(n);
        allocator.destroy(n);
    }

    try testing.expect(tree.root == null);
}
