// general-purpose data structures and algorithms for when std isn't appropriate or possible
//
// Copyright (c) 2024, 2025, 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

// define a linked list that can arbitrarily insert and remove nodes in O(1).
// nodes can be added and removed in a FIFO or LIFO manner, too.
// take care to allocate LinkedList and Node(s) on the heap
// and not the stack if you want your list to be long-living.
// also, locking is to be handled outside this structure

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
            if (node.previous == null) {
                _ = self.popStart();
                return;
            }
            if (node.next == null) {
                _ = self.popEnd();
                return;
            }

            // clear to remove node from between two existing nodes
            if (node.previous) |p| p.next = node.next;
            if (node.next) |n| n.previous = node.previous;
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

    // 1. Test initial state and empty list operations
    try testing.expect(list.start == null);
    try testing.expect(list.end == null);
    try testing.expect(list.popStart() == null);
    try testing.expect(list.popEnd() == null);

    // 2. Test pushStart and popStart (LIFO)
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

    // 3. Test pushEnd and popEnd (LIFO from the other side)
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

    // 4. Test mixed push/pop (FIFO)
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

    // 5. Test insert
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

    // 6. Test remove
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
