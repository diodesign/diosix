// general-purpose data structures and algorithms for when std isn't appropriate
//
// Copyright (c) 2024, 2025 Chris Williams <chrisw@diosix.org>
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
