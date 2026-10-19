// General-purpose data structures and algorithms for M-mode components.
//
// Copyright (c) 2024-2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");

// Doubly linked list with O(1) arbitrary insertion and removal, plus FIFO and
// LIFO push/pop operations. Allocate LinkedList and Node(s) on the heap if the
// list outlives the current stack frame. External synchronization is required.
pub fn LinkedList(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Node = struct {
            next: ?*Node = null,
            previous: ?*Node = null,
            contents: T,
        };

        start: ?*Node,
        end: ?*Node,

        pub fn init(self: *Self) void {
            self.start = null;
            self.end = null;
        }

        // Insert the given node at the start of the list.
        pub fn pushStart(self: *Self, node: *Node) void {
            if (self.start) |start| {
                start.previous = node;
                node.next = start;
            } else {
                self.end = node;
                node.next = null;
            }
            node.previous = null;
            self.start = node;
        }

        // Insert the given node at the end of the list.
        pub fn pushEnd(self: *Self, node: *Node) void {
            if (self.end) |end| {
                end.next = node;
                node.previous = end;
            } else {
                self.start = node;
                node.previous = null;
            }
            node.next = null;
            self.end = node;
        }

        // Remove and return the first node from the list, or null if empty.
        pub fn popStart(self: *Self) ?*Node {
            if (self.start) |start| {
                if (start.next) |next| {
                    next.previous = null;
                    self.start = next;
                } else {
                    self.start = null;
                    self.end = null;
                }
                start.next = null;
                start.previous = null;
                return start;
            }
            return null;
        }

        // Remove and return the last node from the list, or null if empty.
        pub fn popEnd(self: *Self) ?*Node {
            if (self.end) |end| {
                if (end.previous) |previous| {
                    previous.next = null;
                    self.end = previous;
                } else {
                    self.start = null;
                    self.end = null;
                }
                end.next = null;
                end.previous = null;
                return end;
            }
            return null;
        }

        // Insert a node into the list after `after` (or at the start if null).
        pub fn insert(self: *Self, after: ?*Node, node: *Node) void {
            if (after) |a| {
                if (a.next) |next| {
                    next.previous = node;
                    node.next = next;
                    a.next = node;
                    node.previous = after;
                } else return self.pushEnd(node);
            } else return self.pushStart(node);
        }

        // Remove the given node from the list.
        pub fn remove(self: *Self, node: *Node) void {
            if (self.start == node) {
                _ = self.popStart();
                return;
            }
            if (self.end == node) {
                _ = self.popEnd();
                return;
            }
            if (node.previous) |p| p.next = node.next;
            if (node.next) |n| n.previous = node.previous;
            node.previous = null;
            node.next = null;
        }

        // Count and return the number of items in the list.
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

pub const rbtree = @import("dsa/rbtree.zig");
pub const RBColor = rbtree.RBColor;
pub const RedBlackTree = rbtree.RedBlackTree;

pub fn compareU64(a: u64, b: u64) i8 {
    return switch (std.math.order(a, b)) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

test "doubly linked list push, pop, insert, remove, and count" {
    _ = @import("dsa/rbtree.zig");
    std.testing.refAllDecls(@This());
    const testing = std.testing;
    const List = LinkedList(u32);
    const Node = List.Node;

    var list: List = undefined;
    list.init();

    try testing.expect(list.start == null and list.end == null);
    try testing.expect(list.popStart() == null and list.popEnd() == null);
    try testing.expectEqual(@as(usize, 0), list.count());

    var n1 = Node{ .contents = 10 };
    var n2 = Node{ .contents = 20 };
    list.pushStart(&n1);
    list.pushStart(&n2);
    try testing.expect(list.start == &n2 and list.end == &n1);
    try testing.expectEqual(@as(usize, 2), list.count());
    try testing.expect(list.popStart() == &n2);
    try testing.expect(list.popStart() == &n1);
    try testing.expect(list.start == null and list.end == null);

    var n3 = Node{ .contents = 30 };
    var n4 = Node{ .contents = 40 };
    list.pushEnd(&n3);
    list.pushEnd(&n4);
    try testing.expect(list.start == &n3 and list.end == &n4);
    try testing.expect(list.popEnd() == &n4);
    try testing.expect(list.popEnd() == &n3);

    // FIFO ordering.
    list.pushEnd(&n1);
    list.pushEnd(&n2);
    try testing.expect(list.popStart() == &n1);
    try testing.expect(list.popStart() == &n2);

    // Arbitrary insert and remove.
    var n100 = Node{ .contents = 100 };
    var n200 = Node{ .contents = 200 };
    var n300 = Node{ .contents = 300 };
    var n400 = Node{ .contents = 400 };

    list.insert(null, &n200);
    list.insert(null, &n100);
    list.insert(&n200, &n400);
    list.insert(&n200, &n300);
    try testing.expectEqual(@as(usize, 4), list.count());
    try testing.expect(n200.next == &n300 and n300.next == &n400);

    list.remove(&n300);
    try testing.expect(n200.next == &n400 and n400.previous == &n200);
    list.remove(&n100);
    try testing.expect(list.start == &n200 and n200.previous == null);
    list.remove(&n400);
    try testing.expect(list.end == &n200 and n200.next == null);
    list.remove(&n200);
    try testing.expect(list.start == null and list.end == null);
}
