// Guest Virtual Machine control block (Guest)
//
// Manages VM lifecycle, parent/child hierarchical trees, relative Context IDs
// (CIDs), resource quotas, manifest attachments, and inter-VM IPC mailboxes.
// Memory address translation is delegated to GuestSpace in core/vm.zig.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const atomic = @import("atomic.zig");

const vcore = @import("vcore.zig");
const physmem = @import("physmem.zig");
const dsa = @import("dsa.zig");
const vm_space = @import("vm.zig");
const riscv = @import("../hardware/native/cpu/riscv64/mod.zig");
const scheduler = @import("scheduler.zig");
const pcore = @import("pcore.zig");
const debug = @import("debug.zig");
const interface = @import("interface");
const sbi = interface.sbi;
const emulation = @import("emulation");
const vsock_mod = struct {
    pub const VirtioVsock = emulation.VirtioVsock;
    pub const global_vsock_router = emulation.global_vsock_router;
};

pub const GuestID = usize;

pub const GuestState = enum {
    valid, // healthy and running
    dying, // being terminated
    restarting, // being reset
};

pub const QuotaSet = struct {
    max_ram_pages: usize = std.math.maxInt(usize),
    used_ram_pages: usize = 0,
    max_vcpus: usize = std.math.maxInt(usize),
    used_vcpus: usize = 0,
    max_priority: u8 = std.math.maxInt(u8),
    max_child_depth: usize = std.math.maxInt(usize),
    current_depth: usize = 0,
    max_descendants: usize = std.math.maxInt(usize),
    used_descendants: usize = 0,
};

pub const TargetArch = sbi.TargetArch;

pub const CID_PARENT: usize = sbi.CID_PARENT;
pub const CID_SELF: usize = sbi.CID_SELF;
pub const CID_FIRST_CHILD: usize = sbi.CID_FIRST_CHILD;

pub const STATIC_CHILD_HANDLES: usize = 32;
pub const DYNAMIC_CHILD_BUCKETS: usize = 32;
pub const MAX_CHILD_HANDLES: usize = 4096;
pub const max_child_handles: usize = MAX_CHILD_HANDLES;
pub const max_events: usize = 32;
pub const max_ipc_messages: usize = 16;
pub const max_ipc_msg_len: usize = 4096;
pub const max_vcores: usize = 4096;
pub const STATIC_VCORES: usize = 32;
pub const VCORE_HASH_BUCKETS: usize = 32;
pub const max_vmids: u16 = 4096;

pub const DEFAULT_ROOT_MAX_VCPUS: usize = 16;
pub const MAX_MANIFEST_SIZE_BYTES: usize = 1024 * 1024;
pub const IOAPIC_PAGE_SIZE: usize = physmem.PageSize;
pub const X86_EARLY_PGT_GPA_OFFSET: usize = 0x70000;

pub const PIT_NUM_CHANNELS: usize = 3;
pub const PIT_ACCESS_LSB_MSB: u8 = 3;
pub const PIT_PORT61_GATE2_ENABLED: u8 = 0x01;
pub const PIC_ALL_IRQS_MASKED: u8 = 0xFF;

pub const BITS_PER_WORD: usize = @bitSizeOf(u64);
pub const VMID_BITMAP_WORDS: usize = max_vmids / BITS_PER_WORD;

pub const PitChannel = struct {
    latch: u16 = 0,
    count_latched: bool = false,
    latched_val: u16 = 0,
    read_state: u8 = 0, // 0 = LSB, 1 = MSB
    write_state: u8 = 0, // 0 = LSB, 1 = MSB
    mode: u8 = 0,
    access: u8 = PIT_ACCESS_LSB_MSB,
    start_time: u64 = 0,
    period_ticks: u64 = 0,
    gate: u8 = 1,
};

pub const PitState = struct {
    channels: [PIT_NUM_CHANNELS]PitChannel = [_]PitChannel{ .{}, .{}, .{} },
    port_61: u8 = PIT_PORT61_GATE2_ENABLED,
    pic_master_imr: u8 = PIC_ALL_IRQS_MASKED,
    pic_slave_imr: u8 = PIC_ALL_IRQS_MASKED,
};

pub const EventQueue = struct {
    events: [max_events]sbi.Event = std.mem.zeroes([max_events]sbi.Event),
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,
    lock: atomic.SpinLock = atomic.SpinLock.init(),

    pub fn push(self: *EventQueue, ev: sbi.Event) void {
        const s = self.lock.lock();
        defer self.lock.unlock(s);
        if (self.count >= max_events) {
            self.tail = (self.tail + 1) % max_events;
            self.count -= 1;
        }
        self.events[self.head] = ev;
        self.head = (self.head + 1) % max_events;
        self.count += 1;
    }

    fn peekFilteredLocked(self: *const EventQueue, filter_cid: usize) ?sbi.Event {
        if (self.count == 0) return null;
        if (filter_cid == 0) return self.events[self.tail];
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            const idx = (self.tail + i) % max_events;
            if (self.events[idx].cid == filter_cid) {
                return self.events[idx];
            }
        }
        return null;
    }

    pub fn peek(self: *EventQueue) ?sbi.Event {
        return self.peekFiltered(0);
    }

    pub fn peekFiltered(self: *EventQueue, filter_cid: usize) ?sbi.Event {
        const s = self.lock.lock();
        defer self.lock.unlock(s);
        return self.peekFilteredLocked(filter_cid);
    }

    fn popFilteredLocked(self: *EventQueue, filter_cid: usize) ?sbi.Event {
        if (self.count == 0) return null;
        if (filter_cid == 0) {
            const ev = self.events[self.tail];
            self.tail = (self.tail + 1) % max_events;
            self.count -= 1;
            return ev;
        }
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            const idx = (self.tail + i) % max_events;
            if (self.events[idx].cid == filter_cid) {
                const found = self.events[idx];
                var j = i;
                while (j + 1 < self.count) : (j += 1) {
                    const cur_slot = (self.tail + j) % max_events;
                    const next_slot = (self.tail + j + 1) % max_events;
                    self.events[cur_slot] = self.events[next_slot];
                }
                self.head = (self.head + max_events - 1) % max_events;
                self.count -= 1;
                return found;
            }
        }
        return null;
    }

    pub fn pop(self: *EventQueue) ?sbi.Event {
        return self.popFiltered(0);
    }

    pub fn popFiltered(self: *EventQueue, filter_cid: usize) ?sbi.Event {
        const s = self.lock.lock();
        defer self.lock.unlock(s);
        return self.popFilteredLocked(filter_cid);
    }

    pub fn popIfWritten(self: *EventQueue, filter_cid: usize, g: *Guest, event_gpa: usize) !bool {
        const s = self.lock.lock();
        defer self.lock.unlock(s);

        const ev = self.peekFilteredLocked(filter_cid) orelse return false;
        try g.space.writeGuestStruct(sbi.Event, event_gpa, ev);
        _ = self.popFilteredLocked(filter_cid);
        return true;
    }

    pub fn getCount(self: *EventQueue) usize {
        const s = self.lock.lock();
        defer self.lock.unlock(s);
        return self.count;
    }
};

pub const MAX_PACKET_LEN: usize = 1536;
pub const MAX_NET_PACKETS: usize = 64;

pub const Packet = struct {
    len: u16 = 0,
    data: [MAX_PACKET_LEN]u8 = undefined,
};

pub const PacketQueue = struct {
    packets: [MAX_NET_PACKETS]Packet = undefined,
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,
    lock: atomic.SpinLock = atomic.SpinLock.init(),

    pub fn push(self: *PacketQueue, data: []const u8) bool {
        if (data.len == 0 or data.len > MAX_PACKET_LEN) return false;
        const s = self.lock.lock();
        defer self.lock.unlock(s);
        if (self.count >= MAX_NET_PACKETS) {
            // Drop oldest packet on overflow
            self.tail = (self.tail + 1) % MAX_NET_PACKETS;
            self.count -= 1;
        }
        var pkt = &self.packets[self.head];
        pkt.len = @truncate(data.len);
        @memcpy(pkt.data[0..data.len], data);
        self.head = (self.head + 1) % MAX_NET_PACKETS;
        self.count += 1;
        return true;
    }

    pub fn peek(self: *PacketQueue) ?*const Packet {
        const s = self.lock.lock();
        defer self.lock.unlock(s);
        if (self.count == 0) return null;
        return &self.packets[self.tail];
    }

    pub fn drop(self: *PacketQueue) void {
        const s = self.lock.lock();
        defer self.lock.unlock(s);
        if (self.count == 0) return;
        self.tail = (self.tail + 1) % MAX_NET_PACKETS;
        self.count -= 1;
    }

    pub fn pop(self: *PacketQueue, out_buf: []u8) ?usize {
        const s = self.lock.lock();
        defer self.lock.unlock(s);
        if (self.count == 0) return null;
        const pkt = &self.packets[self.tail];
        const copy_len = @min(out_buf.len, @as(usize, pkt.len));
        @memcpy(out_buf[0..copy_len], pkt.data[0..copy_len]);
        self.tail = (self.tail + 1) % MAX_NET_PACKETS;
        self.count -= 1;
        return copy_len;
    }

    pub fn popToGuest(self: *PacketQueue, space: *vm_space.GuestSpace, gpa: usize, max_len: usize) !usize {
        const s = self.lock.lock();
        defer self.lock.unlock(s);
        if (self.count == 0) return 0;
        const pkt = &self.packets[self.tail];
        const copy_len = @min(max_len, @as(usize, pkt.len));
        try space.copyToGuest(gpa, pkt.data[0..copy_len]);
        self.tail = (self.tail + 1) % MAX_NET_PACKETS;
        self.count -= 1;
        return copy_len;
    }

    pub fn getCount(self: *PacketQueue) usize {
        const s = self.lock.lock();
        defer self.lock.unlock(s);
        return self.count;
    }
};

pub const Guest = struct {
    id: GuestID,
    state: GuestState,
    is_trusted: bool, // Can map MMIO and route interrupts
    is_root: bool, // Is the progenitor VM (PID 1)
    target_arch: TargetArch,

    // Subtree resource tracking
    quotas: QuotaSet,

    // Lineage tracking
    parent: ?*Guest,
    children: dsa.LinkedList(*Guest),
    child_node: ?*dsa.LinkedList(*Guest).Node = null,

    // Context ID assigned by parent (1 for Root VM)
    local_cid: usize = CID_SELF,

    // Two-column child handle lookup table:
    // Column 1: Static array for child handles 0..31 -> CIDs 2..33 (wait-free, O(1), zero allocation)
    child_static_handles: [STATIC_CHILD_HANDLES]?*Guest = @splat(null),
    // Column 2: Dynamic hash bucket chains for child handles >= 32 (keyed by handle_idx % 32, intrusive linking)
    child_dynamic_buckets: [DYNAMIC_CHILD_BUCKETS]?*Guest = @splat(null),
    // Intrusive pointer for dynamic child handle bucket chaining
    child_handle_next: ?*Guest = null,
    // Next candidate index for dynamic child CID allocation (32..4095)
    next_dynamic_handle: usize = STATIC_CHILD_HANDLES,

    // Event queue for asynchronous child notifications
    events: EventQueue = .{},

    // Virtual network packet RX queue
    net_rx: PacketQueue = .{},

    // Exit code recorded upon termination
    exit_code: usize = 0,

    // Virtual CPU cores belonging to this guest
    vcores: dsa.LinkedList(*vcore.VirtualCore),

    // Memory space (paging or PMP)
    space: vm_space.GuestSpace,

    // Virtual memory ID for this guest
    vmid: u16,

    // Early page table physical address (GPA) for x86_64 boot
    early_pgt_gpa: usize,

    // Two-column virtual core lookup table:
    // Column 1: Static array for guest hart IDs 0..31 (wait-free, O(1), zero allocation)
    vcore_static: [STATIC_VCORES]?*vcore.VirtualCore = @splat(null),
    // Column 2: Dynamic hash bucket chains for guest hart IDs >= 32 (keyed by vid % 32, intrusive linking)
    vcore_dynamic_buckets: [VCORE_HASH_BUCKETS]?*vcore.VirtualCore = @splat(null),

    // PIT (Programmable Interval Timer) State
    pit: PitState,

    // Shared IO-APIC backing memory for x86_64 guests
    ioapic_mem: [IOAPIC_PAGE_SIZE]u8,

    // Attenuated guest VM manifest buffer
    manifest: ?[]u8 = null,
    manifest_lock: atomic.SpinLock = atomic.SpinLock.init(),

    // Lock protecting child tree hierarchy mutations (child_handles and children list)
    tree_lock: atomic.SpinLock = atomic.SpinLock.init(),

    // VirtIO-vsock device for this guest
    vsock: vsock_mod.VirtioVsock = .{},

    // Virtual devices for emulated guests
    uart: emulation.VirtualUart = .{},
    timer: emulation.VirtualTimer = .{},
    pic: emulation.VirtualPlic = .{},

    // allocator for heap-allocated Guest structures
    allocator: std.mem.Allocator,

    pub fn setManifest(self: *Guest, data: []const u8) !void {
        if (data.len > MAX_MANIFEST_SIZE_BYTES) {
            return error.ManifestTooLarge;
        }
        const new_buf = try self.allocator.alloc(u8, data.len);
        @memcpy(new_buf, data);

        const old_buf = blk: {
            const s = self.manifest_lock.lock();
            defer self.manifest_lock.unlock(s);
            const old = self.manifest;
            self.manifest = new_buf;
            break :blk old;
        };

        if (old_buf) |m| {
            self.allocator.free(m);
        }
    }

    pub fn readManifest(self: *Guest, out_buf: []u8) ?usize {
        const s = self.manifest_lock.lock();
        defer self.manifest_lock.unlock(s);
        if (self.manifest) |m| {
            const copy_len = @min(out_buf.len, m.len);
            @memcpy(out_buf[0..copy_len], m[0..copy_len]);
            return m.len;
        }
        return null;
    }

    pub fn getManifestLength(self: *Guest) usize {
        const s = self.manifest_lock.lock();
        defer self.manifest_lock.unlock(s);
        return if (self.manifest) |m| m.len else 0;
    }

    pub fn getManifest(self: *const Guest) ?[]const u8 {
        return self.manifest;
    }

    pub fn allocChildHandle(self: *Guest, child: *Guest) !usize {
        const s = self.tree_lock.lock();
        defer self.tree_lock.unlock(s);

        // Column 1: fast static array for handles 0..31 (CIDs 2..33)
        for (&self.child_static_handles, 0..) |*slot, i| {
            if (slot.* == null) {
                slot.* = child;
                child.child_handle_next = null;
                const cid = i + CID_FIRST_CHILD;
                child.local_cid = cid;
                return cid;
            }
        }

        // Column 2: dynamic chained hash table for handles 32..4095
        const dynamic_count = MAX_CHILD_HANDLES - STATIC_CHILD_HANDLES;
        var attempts: usize = 0;
        while (attempts < dynamic_count) : (attempts += 1) {
            const handle_idx = self.next_dynamic_handle;
            self.next_dynamic_handle += 1;
            if (self.next_dynamic_handle >= MAX_CHILD_HANDLES) {
                self.next_dynamic_handle = STATIC_CHILD_HANDLES;
            }

            const cand_cid = handle_idx + CID_FIRST_CHILD;
            const bucket = handle_idx % DYNAMIC_CHILD_BUCKETS;

            // Check if cand_cid is already in use in this bucket
            var in_use = false;
            var curr = self.child_dynamic_buckets[bucket];
            while (curr) |c| {
                if (c.local_cid == cand_cid) {
                    in_use = true;
                    break;
                }
                curr = c.child_handle_next;
            }

            if (!in_use) {
                child.child_handle_next = self.child_dynamic_buckets[bucket];
                self.child_dynamic_buckets[bucket] = child;
                child.local_cid = cand_cid;
                return cand_cid;
            }
        }

        return error.QuotaExceeded;
    }

    pub fn freeChildHandle(self: *Guest, child: *Guest) void {
        const s = self.tree_lock.lock();
        defer self.tree_lock.unlock(s);

        const cid = child.local_cid;
        if (cid >= CID_FIRST_CHILD) {
            const handle_idx = cid - CID_FIRST_CHILD;
            if (handle_idx < STATIC_CHILD_HANDLES) {
                if (self.child_static_handles[handle_idx] == child) {
                    self.child_static_handles[handle_idx] = null;
                    return;
                }
            } else if (handle_idx < MAX_CHILD_HANDLES) {
                const bucket = handle_idx % DYNAMIC_CHILD_BUCKETS;
                var curr = self.child_dynamic_buckets[bucket];
                var prev: ?*Guest = null;
                while (curr) |c| {
                    if (c == child) {
                        if (prev) |p| {
                            p.child_handle_next = c.child_handle_next;
                        } else {
                            self.child_dynamic_buckets[bucket] = c.child_handle_next;
                        }
                        c.child_handle_next = null;
                        return;
                    }
                    prev = c;
                    curr = c.child_handle_next;
                }
            }
        }
    }

    pub fn getGuestByCid(self: *Guest, cid: usize) ?*Guest {
        if (cid == CID_PARENT) {
            return self.parent;
        } else if (cid == CID_SELF) {
            return self;
        } else if (cid >= CID_FIRST_CHILD) {
            const s = self.tree_lock.lock();
            defer self.tree_lock.unlock(s);

            const handle_idx = cid - CID_FIRST_CHILD;
            if (handle_idx < STATIC_CHILD_HANDLES) {
                return self.child_static_handles[handle_idx];
            } else if (handle_idx < MAX_CHILD_HANDLES) {
                const bucket = handle_idx % DYNAMIC_CHILD_BUCKETS;
                var curr = self.child_dynamic_buckets[bucket];
                while (curr) |c| {
                    if (c.local_cid == cid) {
                        return c;
                    }
                    curr = c.child_handle_next;
                }
            }
        }
        return null;
    }

    pub fn setQuota(self: *Guest, args: sbi.QuotaArgs) !void {
        if (args.target_cid == CID_SELF) {
            if (args.max_ram_pages > 0) {
                self.quotas.max_ram_pages = @min(self.quotas.max_ram_pages, args.max_ram_pages);
                self.quotas.used_ram_pages = @min(self.quotas.used_ram_pages, self.quotas.max_ram_pages);
                const max_bytes = std.math.mul(usize, self.quotas.max_ram_pages, physmem.PageSize) catch std.math.maxInt(usize);
                if (self.space.range_size == 0 or self.space.range_size > max_bytes) {
                    self.space.setRangeSize(max_bytes);
                }
            }
            if (args.max_vcpus > 0) self.quotas.max_vcpus = @min(self.quotas.max_vcpus, args.max_vcpus);
            if (args.max_child_depth > 0) self.quotas.max_child_depth = @min(self.quotas.max_child_depth, args.max_child_depth);
            if (args.max_descendants > 0) self.quotas.max_descendants = @min(self.quotas.max_descendants, args.max_descendants);
        } else if (args.target_cid >= CID_FIRST_CHILD) {
            if (self.getGuestByCid(args.target_cid)) |child| {
                if (args.max_ram_pages > 0) {
                    child.quotas.max_ram_pages = @min(self.quotas.max_ram_pages, args.max_ram_pages);
                    child.quotas.used_ram_pages = @min(child.quotas.used_ram_pages, child.quotas.max_ram_pages);
                    const new_range = std.math.mul(usize, child.quotas.max_ram_pages, physmem.PageSize) catch std.math.maxInt(usize);
                    child.space.setRangeSize(new_range);
                }
                if (args.max_vcpus > 0) {
                    child.quotas.max_vcpus = @min(self.quotas.max_vcpus, args.max_vcpus);
                    child.quotas.used_vcpus = @min(child.quotas.used_vcpus, child.quotas.max_vcpus);
                }
                if (args.max_child_depth > 0) child.quotas.max_child_depth = @min(self.quotas.max_child_depth, args.max_child_depth);
                if (args.max_descendants > 0) child.quotas.max_descendants = @min(self.quotas.max_descendants, args.max_descendants);
            } else {
                return error.InvalidParam;
            }
        } else {
            return error.AccessDenied;
        }
    }

    fn guestReadMemory(ctx: *anyopaque, gpa: u64, buf: []u8) bool {
        const g: *Guest = @ptrCast(@alignCast(ctx));
        const addr: usize = std.math.cast(usize, gpa) orelse return false;
        g.space.copyFromGuest(buf, addr) catch return false;
        return true;
    }

    fn guestWriteMemory(ctx: *anyopaque, gpa: u64, buf: []const u8) bool {
        const g: *Guest = @ptrCast(@alignCast(ctx));
        const addr: usize = std.math.cast(usize, gpa) orelse return false;
        g.space.copyToGuest(addr, buf) catch return false;
        return true;
    }

    fn guestUartOutput(char: u8) void {
        debug.putchar(char);
    }

    pub fn init(allocator: std.mem.Allocator, id: GuestID, is_trusted: bool, is_root: bool, parent: ?*Guest, base_gpa: usize, base_hpa: usize, range_size: usize, target_arch: TargetArch) !*Guest {
        const self = try allocator.create(Guest);
        errdefer allocator.destroy(self);

        const ram_pages = range_size / physmem.PageSize;
        self.* = .{
            .id = id,
            .state = .valid,
            .is_trusted = is_trusted,
            .is_root = is_root,
            .target_arch = target_arch,
            .quotas = if (parent) |p| p.quotas else .{
                .max_ram_pages = std.math.maxInt(usize),
                .used_ram_pages = ram_pages,
                .max_vcpus = DEFAULT_ROOT_MAX_VCPUS,
                .used_vcpus = 0,
            },
            .parent = parent,
            .children = .{ .start = null, .end = null },
            .child_node = null,
            .local_cid = CID_SELF,
            .child_static_handles = @splat(null),
            .child_dynamic_buckets = @splat(null),
            .child_handle_next = null,
            .next_dynamic_handle = STATIC_CHILD_HANDLES,
            .exit_code = 0,
            .vcores = .{ .start = null, .end = null },
            .vmid = try allocVmid(),
            .vcore_static = @splat(null),
            .vcore_dynamic_buckets = @splat(null),
            .space = try vm_space.GuestSpace.init(allocator, is_trusted, base_gpa, base_hpa, range_size),

            .early_pgt_gpa = if (target_arch == .x86_64) base_gpa + X86_EARLY_PGT_GPA_OFFSET else 0,
            .pit = .{},
            .ioapic_mem = std.mem.zeroes([IOAPIC_PAGE_SIZE]u8),
            .uart = .{ .guest_id = id, .out_fn = guestUartOutput },
            .timer = .{},
            .pic = .{},
            .allocator = allocator,
        };
        self.children.init();
        self.vcores.init();

        if (parent) |p| {
            const node = try allocator.create(dsa.LinkedList(*Guest).Node);
            node.* = .{ .next = null, .previous = null, .contents = self };
            {
                const s = p.tree_lock.lock();
                p.children.pushEnd(node);
                p.tree_lock.unlock(s);
            }
            self.child_node = node;
            self.local_cid = try p.allocChildHandle(self);
            self.quotas.current_depth = p.quotas.current_depth + 1;

            // Increment descendants count up the lineage
            var p_anc: ?*Guest = p;
            while (p_anc) |anc| {
                anc.quotas.used_descendants += 1;
                p_anc = anc.parent;
            }
        }

        self.vsock = vsock_mod.VirtioVsock{
            .guest_cid = self.local_cid,
            .mem = .{
                .ctx = self,
                .readFn = guestReadMemory,
                .writeFn = guestWriteMemory,
            },
            .router = vsock_mod.global_vsock_router,
        };
        vsock_mod.global_vsock_router.register(&self.vsock);

        return self;
    }

    pub fn terminate(self: *Guest) void {
        self.terminateWithCode(0);
    }

    pub fn terminateWithCode(self: *Guest, exit_code: usize) void {
        if (self.state == .dying) return;
        self.state = .dying;
        self.exit_code = exit_code;

        // Recursive termination of all children (cascading)
        while (blk: {
            const s = self.tree_lock.lock();
            const n = self.children.popStart();
            self.tree_lock.unlock(s);
            break :blk n;
        }) |node| {
            const child = node.contents;
            child.child_node = null;
            child.terminateWithCode(exit_code);
            self.allocator.destroy(node);
        }

        // Stop all virtual cores and wait for physical cores to relinquish them
        self.stop();

        // Release stage-2 memory mappings and allocated RAM pages
        self.space.deinit();

        // Send an IPI to other CPUs to force them to reschedule if needed
        pcore.broadcastIpi();

        // Unlink from parent's children list and free child handle if still attached
        if (self.parent) |p| {
            p.events.push(.{
                .cid = self.local_cid,
                .event_type = @intFromEnum(sbi.EventType.child_terminated),
                .exit_code = @truncate(exit_code),
            });
            p.freeChildHandle(self);
            if (self.child_node) |node| {
                const s = p.tree_lock.lock();
                p.children.remove(node);
                p.tree_lock.unlock(s);
                p.allocator.destroy(node);
                self.child_node = null;
            }
        }

        // Reclaim resources in used counters up the lineage
        const ram_reclaim = self.quotas.used_ram_pages;
        const vcpus_reclaim = self.quotas.used_vcpus;
        var p_opt = self.parent;
        while (p_opt) |p| {
            if (p.quotas.used_ram_pages >= ram_reclaim) {
                p.quotas.used_ram_pages -= ram_reclaim;
            } else {
                p.quotas.used_ram_pages = 0;
            }
            if (p.quotas.used_vcpus >= vcpus_reclaim) {
                p.quotas.used_vcpus -= vcpus_reclaim;
            } else {
                p.quotas.used_vcpus = 0;
            }
            if (p.quotas.used_descendants > 0) {
                p.quotas.used_descendants -= 1;
            }
            p_opt = p.parent;
        }

        vsock_mod.global_vsock_router.unregister(self.local_cid);
        if (self.vmid != 0) {
            freeVmid(self.vmid);
            self.vmid = 0;
        }
        const old_manifest = blk: {
            const s = self.manifest_lock.lock();
            defer self.manifest_lock.unlock(s);
            const m = self.manifest;
            self.manifest = null;
            break :blk m;
        };
        if (old_manifest) |m| {
            self.allocator.free(m);
        }
    }

    pub fn dropTrust(self: *Guest) void {
        self.is_trusted = false;
        self.space.is_trusted = false;
    }

    pub fn reduceQuota(self: *Guest, new_quotas: QuotaSet) void {
        // Only allow reductions
        self.quotas.max_ram_pages = @min(self.quotas.max_ram_pages, new_quotas.max_ram_pages);
        self.quotas.max_vcpus = @min(self.quotas.max_vcpus, new_quotas.max_vcpus);
        self.quotas.max_priority = @min(self.quotas.max_priority, new_quotas.max_priority);
        self.quotas.max_child_depth = @min(self.quotas.max_child_depth, new_quotas.max_child_depth);
        self.quotas.max_descendants = @min(self.quotas.max_descendants, new_quotas.max_descendants);
    }

    pub fn checkQuota(self: *Guest, ram_pages: usize, vcpus: usize, depth: usize) bool {
        // Check local limits
        const new_ram = std.math.add(usize, self.quotas.used_ram_pages, ram_pages) catch return false;
        if (new_ram > self.quotas.max_ram_pages) return false;
        const new_vcpus = std.math.add(usize, self.quotas.used_vcpus, vcpus) catch return false;
        if (new_vcpus > self.quotas.max_vcpus) return false;
        if (depth > self.quotas.max_child_depth) return false;
        const new_desc = std.math.add(usize, self.quotas.used_descendants, 1) catch return false;
        if (new_desc > self.quotas.max_descendants) return false;

        // Recursively check ancestors
        if (self.parent) |p| {
            return p.checkQuota(ram_pages, vcpus, depth);
        }
        return true;
    }

    pub fn checkRamQuota(self: *Guest, ram_pages: usize) bool {
        const new_ram = std.math.add(usize, self.quotas.used_ram_pages, ram_pages) catch return false;
        if (new_ram > self.quotas.max_ram_pages) return false;
        if (self.parent) |p| {
            return p.checkRamQuota(ram_pages);
        }
        return true;
    }

    pub fn consumeQuota(self: *Guest, ram_pages: usize, vcpus: usize) void {
        self.quotas.used_ram_pages = std.math.add(usize, self.quotas.used_ram_pages, ram_pages) catch self.quotas.max_ram_pages;
        self.quotas.used_vcpus = std.math.add(usize, self.quotas.used_vcpus, vcpus) catch self.quotas.max_vcpus;
        if (self.parent) |p| {
            p.consumeQuota(ram_pages, vcpus);
        }
    }

    pub fn releaseQuota(self: *Guest, ram_pages: usize, vcpus: usize) void {
        if (self.quotas.used_ram_pages >= ram_pages) {
            self.quotas.used_ram_pages -= ram_pages;
        } else {
            self.quotas.used_ram_pages = 0;
        }
        if (self.quotas.used_vcpus >= vcpus) {
            self.quotas.used_vcpus -= vcpus;
        } else {
            self.quotas.used_vcpus = 0;
        }
        if (self.parent) |p| {
            p.releaseQuota(ram_pages, vcpus);
        }
    }

    pub fn deinit(self: *Guest) void {
        var it_vcore = self.vcores.start;
        while (it_vcore) |node| {
            const next = node.next;
            node.contents.deinit(); // VCore might need its own cleanup
            self.allocator.destroy(node.contents);
            self.allocator.destroy(node);
            it_vcore = next;
        }
        self.vcores.start = null;
        self.vcores.end = null;
        self.vcore_static = @splat(null);
        self.vcore_dynamic_buckets = @splat(null);
        self.child_static_handles = @splat(null);
        self.child_dynamic_buckets = @splat(null);

        self.space.deinit();

        var it_child = self.children.start;
        while (it_child) |node| {
            const next = node.next;
            self.allocator.destroy(node);
            it_child = next;
        }

        if (self.parent) |p| {
            p.freeChildHandle(self);
            if (self.child_node) |node| {
                const s = p.tree_lock.lock();
                p.children.remove(node);
                p.tree_lock.unlock(s);
                self.allocator.destroy(node);
                self.child_node = null;
            }
        }

        const old_manifest = blk: {
            const s = self.manifest_lock.lock();
            defer self.manifest_lock.unlock(s);
            const m = self.manifest;
            self.manifest = null;
            break :blk m;
        };
        if (old_manifest) |m| {
            self.allocator.free(m);
        }

        vsock_mod.global_vsock_router.unregister(self.local_cid);

        if (self.vmid != 0) {
            freeVmid(self.vmid);
            self.vmid = 0;
        }
        self.allocator.destroy(self);
    }

    /// Add a virtual core to this guest.
    /// `sched_queue` is an optional scheduler enqueue function. Pass `null` if the vcore
    /// should not be auto-enrolled (e.g. stopped secondary harts, or testing).
    /// This dependency-injection pattern allows future support for multiple scheduler backends.
    pub fn addVcore(self: *Guest, vid: vcore.VirtualCoreID, entry: usize, dtb: usize, priority: vcore.Priority, sched_queue: ?*const fn (*vcore.VirtualCore) void) !*vcore.VirtualCore {
        if (self.findVcore(vid) != null) return error.DuplicateVcore;

        const vc = try self.allocator.create(vcore.VirtualCore);
        errdefer self.allocator.destroy(vc);

        vc.* = vcore.VirtualCore.init(vid, self, entry, dtb, priority);
        vc.blocked_node.contents = @ptrCast(vc);
        if (vc.exec_path == .emulated) {
            vc.context[@intFromEnum(riscv.Register.a0)] = @intFromPtr(vc);
        }

        const node = try self.allocator.create(dsa.LinkedList(*vcore.VirtualCore).Node);
        errdefer self.allocator.destroy(node);

        node.* = .{
            .next = null,
            .previous = null,
            .contents = vc,
        };
        self.vcores.pushEnd(node);
        self.quotas.used_vcpus = self.vcores.count();

        // Register in the two-column lookup table
        if (vid < STATIC_VCORES) {
            self.vcore_static[vid] = vc;
        } else {
            const bucket = vid % VCORE_HASH_BUCKETS;
            vc.lookup_next = self.vcore_dynamic_buckets[bucket];
            self.vcore_dynamic_buckets[bucket] = vc;
        }

        // Enroll the vcore in the scheduler if a queue function was provided.
        if (sched_queue) |q| {
            q(vc);
        }

        return vc;
    }

    pub fn findVcore(self: *const Guest, vid: vcore.VirtualCoreID) ?*vcore.VirtualCore {
        if (vid < STATIC_VCORES) {
            return self.vcore_static[vid];
        }
        const bucket = vid % VCORE_HASH_BUCKETS;
        var curr = self.vcore_dynamic_buckets[bucket];
        while (curr) |c| {
            if (c.id == vid) return c;
            curr = c.lookup_next;
        }
        var it = self.vcores.start;
        while (it) |node| {
            if (node.contents.id == vid) return node.contents;
            it = node.next;
        }
        return null;
    }

    // Add a memory region to this guest
    pub fn addMemoryRegion(self: *Guest, gpa: usize, hpa: usize, size: usize, flags: u64) !void {
        try self.space.map(gpa, hpa, size, flags);
    }

    // Create a new child VM with a clean memory space (for ELF loading)
    pub fn createChild(self: *Guest, is_trusted: bool, target_arch: TargetArch, vcpu_count: usize) !*Guest {
        const child_id = blk: {
            const guard = guest_manager.acquire();
            defer guard.release();
            const state = guard.get();
            const next = state.guest_id_next;
            state.guest_id_next = std.math.add(usize, next, 1) catch std.math.maxInt(usize);
            break :blk next;
        };

        const num_vcpus = if (vcpu_count > 0) vcpu_count else 1;
        if (!self.checkQuota(0, num_vcpus, self.quotas.current_depth + 1)) {
            debug.printf("createChild: checkQuota failed! used_vcpus={} max_vcpus={} used_descendants={} max_descendants={}\n", .{
                self.quotas.used_vcpus, self.quotas.max_vcpus, self.quotas.used_descendants, self.quotas.max_descendants,
            });
            return error.QuotaExceeded;
        }

        const child_base_gpa: usize = switch (target_arch) {
            .riscv64, .riscv32 => 0xe0000000,
            .x86_64 => 0,
            .aarch64 => 0x40000000,
        };
        const child_range_size = std.math.mul(usize, self.quotas.max_ram_pages, physmem.PageSize) catch std.math.maxInt(usize);
        const child_space = vm_space.GuestSpace.init(self.allocator, is_trusted, child_base_gpa, 0, child_range_size) catch |err| {
            debug.printf("createChild: GuestSpace.init failed: {s}, free RAM: {} KB\n", .{ @errorName(err), physmem.getFreeRamBytes() / 1024 });
            return err;
        };

        const child = self.allocator.create(Guest) catch |err| {
            debug.printf("createChild: allocator.create(Guest) failed: {s}\n", .{@errorName(err)});
            return err;
        };
        errdefer self.allocator.destroy(child);

        child.* = .{
            .id = child_id,
            .state = .valid,
            .is_trusted = is_trusted,
            .is_root = false,
            .target_arch = target_arch,
            .quotas = .{
                .max_ram_pages = self.quotas.max_ram_pages,
                .used_ram_pages = 0,
                .max_vcpus = self.quotas.max_vcpus,
                .used_vcpus = 0,
                .max_child_depth = if (self.quotas.max_child_depth > 0) self.quotas.max_child_depth - 1 else 0,
                .current_depth = self.quotas.current_depth + 1,
                .max_descendants = if (self.quotas.max_descendants > 0) self.quotas.max_descendants - 1 else 0,
                .used_descendants = 0,
            },
            .parent = self,
            .children = .{ .start = null, .end = null },
            .child_node = null,
            .local_cid = child_id,
            .child_static_handles = @splat(null),
            .child_dynamic_buckets = @splat(null),
            .child_handle_next = null,
            .next_dynamic_handle = STATIC_CHILD_HANDLES,
            .exit_code = 0,
            .vcores = .{ .start = null, .end = null },
            .vmid = allocVmid() catch |err| {
                debug.printf("createChild: allocVmid failed: {s}\n", .{@errorName(err)});
                return err;
            },
            .vcore_static = @splat(null),
            .vcore_dynamic_buckets = @splat(null),
            .space = child_space,
            .early_pgt_gpa = if (target_arch == .x86_64) child_space.base_gpa + X86_EARLY_PGT_GPA_OFFSET else 0,
            .pit = .{},
            .ioapic_mem = std.mem.zeroes([IOAPIC_PAGE_SIZE]u8),
            .uart = .{ .guest_id = child_id, .out_fn = guestUartOutput },
            .timer = .{},
            .pic = .{},
            .allocator = self.allocator,
        };
        child.children.init();
        child.vcores.init();

        // Lineage tracking
        const line_node = self.allocator.create(dsa.LinkedList(*Guest).Node) catch |err| {
            debug.printf("createChild: allocator.create(Node) failed: {s}\n", .{@errorName(err)});
            return err;
        };
        line_node.* = .{ .next = null, .previous = null, .contents = child };
        {
            const s = self.tree_lock.lock();
            self.children.pushEnd(line_node);
            self.tree_lock.unlock(s);
        }
        child.child_node = line_node;
        child.local_cid = try self.allocChildHandle(child);
        child.quotas.current_depth = self.quotas.current_depth + 1;
        child.quotas.used_vcpus = num_vcpus;
        child.quotas.used_ram_pages = 0;

        // Ancestor tracking: consumed descendants and vcpus
        var p_opt: ?*Guest = self;
        while (p_opt) |p| {
            p.quotas.used_descendants += 1;
            p.quotas.used_vcpus += num_vcpus;
            p_opt = p.parent;
        }

        for (0..num_vcpus) |vc_id| {
            _ = child.addVcore(@intCast(vc_id), 0, 0, .normal, null) catch |err| {
                debug.printf("createChild: addVcore failed: {s}\n", .{@errorName(err)});
                return err;
            };
        }

        return child;
    }

    // Stop all virtual cores and wait for physical cores to relinquish them
    pub fn stop(self: *Guest) void {
        const my_cpu = if (builtin.is_test) 0 else riscv.getCPUContext().hardware_hart_id;
        var it = self.vcores.start;
        while (it) |node| {
            const vc = node.contents;
            vc.state = .stopped;
            @atomicStore(bool, &vc.wfi_blocked, false, .release);

            if (!builtin.is_test) {
                scheduler.dequeue(vc);
                if (vc.running_on_cpu) |home_cpu| {
                    if (home_cpu != my_cpu) {
                        pcore.sendIpiToCpu(home_cpu);
                    }
                }
            }
            it = node.next;
        }

        if (!builtin.is_test) {
            it = self.vcores.start;
            while (it) |node| {
                const vc = node.contents;
                while ((@as(*volatile ?usize, &vc.running_on_cpu)).* != null) {
                    if (vc.running_on_cpu == my_cpu) break;
                    std.atomic.spinLoopHint();
                }
                it = node.next;
            }
        }
    }

    // Reset all vcores for booting a new ELF entry point
    pub fn resetForRun(self: *Guest, entry: usize, dtb: usize) void {
        self.state = .valid;
        self.uart = .{ .guest_id = self.id, .out_fn = guestUartOutput };
        self.timer.reset();
        self.pic.reset();
        var is_primary = true;
        var it = self.vcores.start;
        while (it) |node| {
            const vc = node.contents;
            vc.reset(entry, dtb);
            if (is_primary) {
                vc.state = .ready;
                is_primary = false;
            } else {
                vc.state = .stopped;
            }
            it = node.next;
        }
    }
};

// Global guest manager state to encapsulate VMIDs and guest ID counters.
const GuestManagerState = struct {
    vmid_bitmap: [VMID_BITMAP_WORDS]u64 = blk: {
        var bm = std.mem.zeroes([VMID_BITMAP_WORDS]u64);
        bm[0] = 1; // VMID 0 is permanently reserved in RISC-V hgatp
        break :blk bm;
    },
    guest_id_next: usize = CID_SELF,
};

var guest_manager = atomic.LockPayload(GuestManagerState).init("Global guest manager state", .{});

fn allocVmid() !u16 {
    const guard = guest_manager.acquire();
    defer guard.release();
    const state = guard.get();

    // Search for a free bit in the bitmap. VMID 0 is reserved (bit 0 of word 0 is permanently set).
    for (&state.vmid_bitmap, 0..) |*word, wi| {
        if (word.* == std.math.maxInt(u64)) continue; // All 64 bits set, skip.
        const free_bit: u6 = @intCast(@ctz(~word.*));
        const vmid: u16 = @intCast(wi * BITS_PER_WORD + free_bit);
        if (vmid >= max_vmids) break;
        word.* |= @as(u64, 1) << free_bit;
        return vmid;
    }
    // All VMIDs exhausted.
    debug.printf("VMID: All {} VMIDs exhausted\n", .{max_vmids});
    return error.OutOfMemory;
}

fn freeVmid(id: u16) void {
    const guard = guest_manager.acquire();
    defer guard.release();
    const state = guard.get();
    if (id == 0 or id >= max_vmids) return;
    const wi = id / BITS_PER_WORD;
    const bit: u6 = @intCast(id % BITS_PER_WORD);
    state.vmid_bitmap[wi] &= ~(@as(u64, 1) << bit);
}

pub fn createGuest(allocator: std.mem.Allocator, is_trusted: bool, is_root: bool, parent: ?*Guest, base_gpa: usize, base_hpa: usize, range_size: usize, target_arch: TargetArch) !*Guest {
    const id = blk: {
        const guard = guest_manager.acquire();
        defer guard.release();
        const state = guard.get();
        const next = state.guest_id_next;
        state.guest_id_next = next + 1;
        break :blk next;
    };

    return try Guest.init(allocator, id, is_trusted, is_root, parent, base_gpa, base_hpa, range_size, target_arch);
}

test "guest createChild and vcore setup" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Reset ID counter for predictable test
    {
        const guard = guest_manager.acquire();
        defer guard.release();
        const state = guard.get();
        state.guest_id_next = CID_SELF;
        state.vmid_bitmap = std.mem.zeroes([VMID_BITMAP_WORDS]u64);
    }
    var phys_test = try physmem.initForTest(allocator, 128);
    defer phys_test.deinit();

    const hpa = try physmem.allocPage();
    const parent = try createGuest(allocator, true, true, null, 0x80000000, hpa, 0x1000, .riscv64);
    defer parent.deinit();

    scheduler.init();
    scheduler.initCpu();

    // Add a vcore so there is something to test
    _ = try parent.addVcore(0, 0, 0, .normal, null);

    const child = try parent.createChild(false, .riscv64, 1);
    defer child.deinit();

    try testing.expect(child.id != parent.id);
    try testing.expect(child.vmid != parent.vmid);

    // Check that we have a vcore in the child
    try testing.expect(child.vcores.start != null);
    const child_vc = child.vcores.start.?.contents;
    try testing.expectEqual(@as(usize, 0), child_vc.context[10]); // a0 is 0
}

test "guest creation and vcore management" {
    const testing = std.testing;
    const allocator = testing.allocator;

    scheduler.init();
    scheduler.initCpu();

    // Reset ID counter for predictable test
    {
        const guard = guest_manager.acquire();
        defer guard.release();
        const state = guard.get();
        state.guest_id_next = CID_SELF;
        state.vmid_bitmap = std.mem.zeroes([VMID_BITMAP_WORDS]u64);
    }
    var phys_test = try physmem.initForTest(allocator, 128);
    defer phys_test.deinit();

    const g1 = try createGuest(allocator, true, true, null, 0, 0, 0, .riscv64);
    defer g1.deinit();
    try testing.expectEqual(@as(usize, 1), g1.id);

    const g2 = try createGuest(allocator, false, false, g1, 0, 0, 0, .riscv64);
    defer g2.deinit();
    try testing.expectEqual(@as(usize, 2), g2.id);
    try testing.expectEqual(g1, g2.parent.?);

    // Add a vcore to g1
    const vc = try g1.addVcore(100, 0x1000, 0x2000, .high, null);
    try testing.expectEqual(@as(usize, 100), vc.id);
    try testing.expectEqual(g1.id, vc.guest_id);
    try testing.expectEqual(@as(usize, 0x1000), vc.machine.mepc);

    // Check that it was added to the guest's vcore list
    try testing.expect(g1.vcores.start != null);
    try testing.expectEqual(vc, g1.vcores.start.?.contents);
}

test "guest trust drop" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var phys_test = try physmem.initForTest(allocator, 128);
    defer phys_test.deinit();

    const g = try createGuest(allocator, true, true, null, 0, 0, 0, .riscv64);
    defer g.deinit();

    try testing.expect(g.is_trusted == true);
    g.dropTrust();
    try testing.expect(g.is_trusted == false);
    try testing.expect(g.space.is_trusted == false);
}

test "guest cascading termination and lineage" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var phys_test = try physmem.initForTest(allocator, 128);
    defer phys_test.deinit();

    const parent = try createGuest(allocator, true, true, null, 0, 0, 0, .riscv64);
    defer parent.deinit();

    const child = try createGuest(allocator, false, false, parent, 0, 0, 0, .riscv64);
    defer child.deinit();

    const grandchild = try createGuest(allocator, false, false, child, 0, 0, 0, .riscv64);
    defer grandchild.deinit();

    try testing.expectEqual(parent, child.parent.?);
    try testing.expectEqual(child, grandchild.parent.?);

    // Terminate parent
    parent.terminate();

    try testing.expect(parent.state == .dying);
    try testing.expect(child.state == .dying);
    try testing.expect(grandchild.state == .dying);
}

test "guest stop and resetForRun on multicore" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var phys_test = try physmem.initForTest(allocator, 128);
    defer phys_test.deinit();

    const parent = try createGuest(allocator, true, true, null, 0, 0, 0, .riscv64);
    defer parent.deinit();

    const vc0 = try parent.addVcore(0, 0x80200000, 0x81000000, .normal, null);
    const vc1 = try parent.addVcore(1, 0x80200000, 0x81000000, .normal, null);
    vc0.state = .running;
    vc1.state = .running;

    // Stop all vcores
    parent.stop();
    try testing.expect(vc0.state == .stopped);
    try testing.expect(vc1.state == .stopped);

    // Reset for run
    const new_entry: usize = 0x80400000;
    const new_dtb: usize = 0x82000000;
    parent.resetForRun(new_entry, new_dtb);

    // Bootstrap core (vc0) must be .ready, with updated PC and DTB
    try testing.expect(vc0.state == .ready);
    try testing.expectEqual(new_entry, vc0.machine.mepc);
    try testing.expectEqual(@as(usize, 0), vc0.context[@intFromEnum(riscv.Register.a0)]);
    try testing.expectEqual(new_dtb, vc0.context[@intFromEnum(riscv.Register.a1)]);

    // Secondary core (vc1) must be .stopped awaiting SBI HSM start
    try testing.expect(vc1.state == .stopped);
    try testing.expectEqual(new_entry, vc1.machine.mepc);
    try testing.expectEqual(@as(usize, 1), vc1.context[@intFromEnum(riscv.Register.a0)]);
    try testing.expectEqual(new_dtb, vc1.context[@intFromEnum(riscv.Register.a1)]);
}

test "child termination unlinking and quota reclamation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    scheduler.init();
    scheduler.initCpu();

    {
        const guard = guest_manager.acquire();
        defer guard.release();
        const state = guard.get();
        state.guest_id_next = CID_SELF;
        state.vmid_bitmap = std.mem.zeroes([VMID_BITMAP_WORDS]u64);
    }

    var phys_test = try physmem.initForTest(allocator, 128);
    defer phys_test.deinit();

    const parent = try createGuest(allocator, true, true, null, 0, 0, 0x10000, .riscv64);
    defer parent.deinit();

    _ = try parent.addVcore(0, 0, 0, .normal, null);

    const initial_vcpus = parent.quotas.used_vcpus;
    const initial_ram = parent.quotas.used_ram_pages;

    // Create 3 children
    const child1 = try parent.createChild(false, .riscv64, 1);
    defer child1.deinit();
    const child2 = try parent.createChild(false, .riscv64, 1);
    defer child2.deinit();
    const child3 = try parent.createChild(false, .riscv64, 1);
    defer child3.deinit();

    // Verify Context IDs
    try testing.expectEqual(@as(usize, 2), child1.local_cid);
    try testing.expectEqual(@as(usize, 3), child2.local_cid);
    try testing.expectEqual(@as(usize, 4), child3.local_cid);

    // Verify CID resolution
    try testing.expectEqual(parent, child1.getGuestByCid(CID_PARENT).?);
    try testing.expectEqual(child1, child1.getGuestByCid(CID_SELF).?);
    try testing.expectEqual(child1, parent.getGuestByCid(2).?);
    try testing.expectEqual(child2, parent.getGuestByCid(3).?);
    try testing.expectEqual(child3, parent.getGuestByCid(4).?);

    try testing.expectEqual(@as(usize, 3), parent.children.count());
    try testing.expectEqual(@as(usize, 3), parent.quotas.used_descendants);

    // Terminate child 1
    child1.terminateWithCode(42);
    try testing.expectEqual(@as(usize, 42), child1.exit_code);
    try testing.expectEqual(@as(usize, 2), parent.children.count());
    try testing.expectEqual(@as(usize, 2), parent.quotas.used_descendants);
    try testing.expect(parent.getGuestByCid(2) == null);

    // Terminate child 2
    child2.terminateWithCode(0);
    try testing.expectEqual(@as(usize, 0), child2.exit_code);
    try testing.expectEqual(@as(usize, 1), parent.children.count());
    try testing.expectEqual(@as(usize, 1), parent.quotas.used_descendants);
    try testing.expect(parent.getGuestByCid(3) == null);

    // Child 3 must be the only remaining child
    try testing.expectEqual(child3, parent.children.start.?.contents);
    try testing.expectEqual(child3, parent.getGuestByCid(4).?);

    // Terminate child 3
    child3.terminateWithCode(1);
    try testing.expectEqual(@as(usize, 1), child3.exit_code);
    try testing.expectEqual(@as(usize, 0), parent.children.count());
    try testing.expectEqual(@as(usize, 0), parent.quotas.used_descendants);
    try testing.expect(parent.getGuestByCid(4) == null);
    try testing.expectEqual(initial_vcpus, parent.quotas.used_vcpus);
    try testing.expectEqual(initial_ram, parent.quotas.used_ram_pages);

    // Verify asynchronous event delivery in FIFO order
    try testing.expectEqual(@as(usize, 3), parent.events.count);
    const ev1 = parent.events.pop().?;
    try testing.expectEqual(@as(usize, 2), ev1.cid);
    try testing.expectEqual(@as(u32, 1), ev1.event_type);
    try testing.expectEqual(@as(u32, 42), ev1.exit_code);

    const ev2 = parent.events.pop().?;
    try testing.expectEqual(@as(usize, 3), ev2.cid);
    try testing.expectEqual(@as(u32, 1), ev2.event_type);
    try testing.expectEqual(@as(u32, 0), ev2.exit_code);

    const ev3 = parent.events.pop().?;
    try testing.expectEqual(@as(usize, 4), ev3.cid);
    try testing.expectEqual(@as(u32, 1), ev3.event_type);
    try testing.expectEqual(@as(u32, 1), ev3.exit_code);

    try testing.expect(parent.events.pop() == null);
}

test "guest quota management and manifest attachments" {
    const testing = std.testing;
    const allocator = testing.allocator;

    scheduler.init();
    scheduler.initCpu();

    {
        const guard = guest_manager.acquire();
        defer guard.release();
        const state = guard.get();
        state.guest_id_next = CID_SELF;
        state.vmid_bitmap = std.mem.zeroes([VMID_BITMAP_WORDS]u64);
    }

    var phys_test = try physmem.initForTest(allocator, 4096);
    defer phys_test.deinit();

    const parent = try createGuest(allocator, true, true, null, 0, 0, 0x1000000, .riscv64);
    defer parent.deinit();

    _ = try parent.addVcore(0, 0, 0, .normal, null);

    const child = try parent.createChild(false, .riscv64, 1);
    defer child.deinit();

    // Parent sets child quota
    try parent.setQuota(.{
        .target_cid = 2,
        .max_ram_pages = 1024,
        .max_vcpus = 2,
        .max_child_depth = 4,
        .max_descendants = 10,
    });
    try testing.expectEqual(@as(usize, 1024), child.quotas.max_ram_pages);
    try testing.expectEqual(@as(usize, 2), child.quotas.max_vcpus);

    // Child lowers own quota (self-sandboxing)
    try child.setQuota(.{
        .target_cid = CID_SELF,
        .max_ram_pages = 512,
        .max_vcpus = 1,
        .max_child_depth = 2,
        .max_descendants = 5,
    });
    try testing.expectEqual(@as(usize, 512), child.quotas.max_ram_pages);
    try testing.expectEqual(@as(usize, 1), child.quotas.max_vcpus);

    // Child cannot modify parent quota
    try testing.expectError(error.AccessDenied, child.setQuota(.{
        .target_cid = CID_PARENT,
        .max_ram_pages = 100,
        .max_vcpus = 1,
        .max_child_depth = 1,
        .max_descendants = 1,
    }));

    // Test Guest manifest storage and retrieval
    const sample_manifest = "[vm]\nname = \"test-child\"\ncid = 2\n";
    try child.setManifest(sample_manifest);
    try testing.expect(child.getManifest() != null);
    try testing.expectEqualStrings(sample_manifest, child.getManifest().?);

    // Test checkQuota rejection on integer overflow
    try testing.expect(!child.checkQuota(std.math.maxInt(usize), 1, 1));
    try testing.expect(!child.checkQuota(1, std.math.maxInt(usize), 1));

    // Test checkRamQuota, consumeQuota, and releaseQuota propagation
    const parent_base_ram = parent.quotas.used_ram_pages;
    try testing.expect(child.checkRamQuota(100));
    try testing.expect(!child.checkRamQuota(600)); // exceeds child.quotas.max_ram_pages (512)
    child.consumeQuota(100, 0);
    try testing.expectEqual(@as(usize, 100), child.quotas.used_ram_pages);
    try testing.expectEqual(parent_base_ram + 100, parent.quotas.used_ram_pages);
    child.releaseQuota(50, 0);
    try testing.expectEqual(@as(usize, 50), child.quotas.used_ram_pages);
    try testing.expectEqual(parent_base_ram + 50, parent.quotas.used_ram_pages);
    child.releaseQuota(50, 0);
    try testing.expectEqual(@as(usize, 0), child.quotas.used_ram_pages);
    try testing.expectEqual(parent_base_ram, parent.quotas.used_ram_pages);
}

test "VMID double free prevention on terminateWithCode followed by deinit" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var phys_test = try physmem.initForTest(allocator, 128);
    defer phys_test.deinit();

    // Reset ID counter and VMID bitmap
    {
        const guard = guest_manager.acquire();
        defer guard.release();
        const state = guard.get();
        state.guest_id_next = CID_SELF;
        state.vmid_bitmap = std.mem.zeroes([VMID_BITMAP_WORDS]u64);
        state.vmid_bitmap[0] = 1; // VMID 0 reserved
    }

    const parent = try createGuest(allocator, true, true, null, 0, 0, 0, .riscv64);
    defer parent.deinit();

    const child1 = try parent.createChild(false, .riscv64, 0);
    const vmid1 = child1.vmid;
    try testing.expect(vmid1 != 0);

    // Terminate child1: frees VMID and zeroes child1.vmid
    child1.terminateWithCode(0);
    try testing.expectEqual(@as(u16, 0), child1.vmid);

    // Allocate another child VM: it reclaims the freed VMID
    const child2 = try parent.createChild(false, .riscv64, 0);
    defer child2.deinit();
    try testing.expectEqual(vmid1, child2.vmid);

    // Call deinit on child1: must NOT free child2's active VMID!
    child1.deinit();

    // child2's VMID must still be marked active in the bitmap
    {
        const guard = guest_manager.acquire();
        defer guard.release();
        const state = guard.get();
        const wi = child2.vmid / BITS_PER_WORD;
        const bit: u6 = @intCast(child2.vmid % BITS_PER_WORD);
        try testing.expect((state.vmid_bitmap[wi] & (@as(u64, 1) << bit)) != 0);
    }
}

test "EventQueue filtered polling by CID and manifest size enforcement" {
    const testing = std.testing;

    var q = EventQueue{};

    // Push events with distinct CIDs
    q.push(.{ .cid = 10, .event_type = 1, .exit_code = 0 });
    q.push(.{ .cid = 20, .event_type = 2, .exit_code = 1 });
    q.push(.{ .cid = 30, .event_type = 3, .exit_code = 2 });

    try testing.expectEqual(@as(usize, 3), q.count);

    // Filtered peek for CID 20
    const peek20 = q.peekFiltered(20);
    try testing.expect(peek20 != null);
    try testing.expectEqual(@as(usize, 20), peek20.?.cid);
    try testing.expectEqual(@as(usize, 3), q.count); // Count unchanged

    // Filtered peek for non-existent CID
    try testing.expect(q.peekFiltered(99) == null);

    // Pop filtered: extract CID 20 from middle
    const pop20 = q.popFiltered(20);
    try testing.expect(pop20 != null);
    try testing.expectEqual(@as(usize, 20), pop20.?.cid);
    try testing.expectEqual(@as(usize, 2), q.count);

    // Remaining queue in FIFO order: CID 10, then CID 30
    const pop10 = q.popFiltered(0); // Pop any
    try testing.expect(pop10 != null);
    try testing.expectEqual(@as(usize, 10), pop10.?.cid);

    const pop30 = q.popFiltered(0);
    try testing.expect(pop30 != null);
    try testing.expectEqual(@as(usize, 30), pop30.?.cid);

    try testing.expect(q.popFiltered(0) == null);
    try testing.expectEqual(@as(usize, 0), q.count);
}

test "Two-column virtual core lookup table (static and dynamic buckets)" {
    const testing = std.testing;

    var g: Guest = undefined;
    g.vcore_static = @splat(null);
    g.vcore_dynamic_buckets = @splat(null);
    g.vcores.init();

    // Create dummy vcores across static (0..31) and dynamic (>=32) ranges
    var vc0: vcore.VirtualCore = undefined;
    vc0.id = 0;
    vc0.lookup_next = null;
    g.vcore_static[0] = &vc0;

    var vc15: vcore.VirtualCore = undefined;
    vc15.id = 15;
    vc15.lookup_next = null;
    g.vcore_static[15] = &vc15;

    var vc31: vcore.VirtualCore = undefined;
    vc31.id = 31;
    vc31.lookup_next = null;
    g.vcore_static[31] = &vc31;

    // Dynamic vcores >= 32
    var vc32: vcore.VirtualCore = undefined;
    vc32.id = 32;
    vc32.lookup_next = null;
    const b32 = 32 % VCORE_HASH_BUCKETS;
    vc32.lookup_next = g.vcore_dynamic_buckets[b32];
    g.vcore_dynamic_buckets[b32] = &vc32;

    var vc64: vcore.VirtualCore = undefined; // Collides in bucket 0 with 32
    vc64.id = 64;
    vc64.lookup_next = null;
    const b64 = 64 % VCORE_HASH_BUCKETS;
    vc64.lookup_next = g.vcore_dynamic_buckets[b64];
    g.vcore_dynamic_buckets[b64] = &vc64;

    var vc1024: vcore.VirtualCore = undefined;
    vc1024.id = 1024;
    vc1024.lookup_next = null;
    const b1024 = 1024 % VCORE_HASH_BUCKETS;
    vc1024.lookup_next = g.vcore_dynamic_buckets[b1024];
    g.vcore_dynamic_buckets[b1024] = &vc1024;

    // Verify static lookups
    try testing.expectEqual(&vc0, g.findVcore(0));
    try testing.expectEqual(&vc15, g.findVcore(15));
    try testing.expectEqual(&vc31, g.findVcore(31));

    // Verify dynamic lookups (including colliding bucket chain 64 -> 32)
    try testing.expectEqual(&vc32, g.findVcore(32));
    try testing.expectEqual(&vc64, g.findVcore(64));
    try testing.expectEqual(&vc1024, g.findVcore(1024));

    // Verify non-existent returns null
    try testing.expect(g.findVcore(1) == null);
    try testing.expect(g.findVcore(33) == null);
    try testing.expect(g.findVcore(9999) == null);
}

test "addVcore duplicate prevention across static and dynamic columns" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var phys_test = try physmem.initForTest(allocator, 128);
    defer phys_test.deinit();

    const hpa = try physmem.allocPage();
    const g = try createGuest(allocator, true, true, null, 0x80000000, hpa, 0x1000, .riscv64);
    defer g.deinit();

    // 1. Static vcore (ID 0)
    _ = try g.addVcore(0, 0, 0, .normal, null);
    try testing.expect(g.findVcore(0) != null);
    // Duplicate static vcore must fail
    try testing.expectError(error.DuplicateVcore, g.addVcore(0, 0, 0, .normal, null));

    // 2. Dynamic vcore (ID 42)
    _ = try g.addVcore(42, 0, 0, .normal, null);
    try testing.expect(g.findVcore(42) != null);
    // Duplicate dynamic vcore must fail
    try testing.expectError(error.DuplicateVcore, g.addVcore(42, 0, 0, .normal, null));

    // Non-existent
    try testing.expect(g.findVcore(1) == null);
    try testing.expect(g.findVcore(43) == null);
}

test "Two-column child handle lookup table (static array and dynamic chained buckets)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var phys_test = try physmem.initForTest(allocator, 128);
    defer phys_test.deinit();

    const hpa = try physmem.allocPage();
    const parent = try createGuest(allocator, true, true, null, 0x80000000, hpa, 0x1000, .riscv64);
    defer parent.deinit();

    const NUM_CHILDREN = 80; // Surpasses legacy 64 child limit
    var dummy_children: [NUM_CHILDREN]Guest = undefined;
    var allocated_cids: [NUM_CHILDREN]usize = undefined;

    // Allocate 80 child handles on parent
    for (0..NUM_CHILDREN) |i| {
        dummy_children[i] = undefined;
        dummy_children[i].local_cid = 0;
        dummy_children[i].child_handle_next = null;

        const cid = try parent.allocChildHandle(&dummy_children[i]);
        allocated_cids[i] = cid;

        // Static handles: first 32 handles (0..31) -> CIDs 2..33
        if (i < STATIC_CHILD_HANDLES) {
            try testing.expectEqual(i + CID_FIRST_CHILD, cid);
            try testing.expectEqual(&dummy_children[i], parent.child_static_handles[i]);
        } else {
            // Dynamic handles: 32..79 -> CIDs >= 34
            try testing.expect(cid >= STATIC_CHILD_HANDLES + CID_FIRST_CHILD);
        }
    }

    // Verify all 80 children can be looked up via getGuestByCid
    for (0..NUM_CHILDREN) |i| {
        const found = parent.getGuestByCid(allocated_cids[i]);
        try testing.expect(found != null);
        try testing.expectEqual(&dummy_children[i], found.?);
    }

    // Verify CID_PARENT and CID_SELF
    try testing.expectEqual(parent, parent.getGuestByCid(CID_SELF));
    try testing.expect(parent.getGuestByCid(CID_PARENT) == null); // Root VM has no parent

    // Verify non-existent CID
    try testing.expect(parent.getGuestByCid(9999) == null);

    // Free a static handle (e.g. index 5 -> CID 7)
    parent.freeChildHandle(&dummy_children[5]);
    try testing.expect(parent.getGuestByCid(allocated_cids[5]) == null);
    // Other static handles still exist
    try testing.expectEqual(&dummy_children[4], parent.getGuestByCid(allocated_cids[4]));
    try testing.expectEqual(&dummy_children[6], parent.getGuestByCid(allocated_cids[6]));

    // Free a dynamic handle (e.g. index 45)
    parent.freeChildHandle(&dummy_children[45]);
    try testing.expect(parent.getGuestByCid(allocated_cids[45]) == null);
    // Other dynamic handles still exist
    try testing.expectEqual(&dummy_children[44], parent.getGuestByCid(allocated_cids[44]));
    try testing.expectEqual(&dummy_children[46], parent.getGuestByCid(allocated_cids[46]));

    // Re-allocating should fill the freed static slot first
    var new_child_static: Guest = undefined;
    new_child_static.local_cid = 0;
    new_child_static.child_handle_next = null;
    const reused_cid = try parent.allocChildHandle(&new_child_static);
    try testing.expectEqual(allocated_cids[5], reused_cid);
    try testing.expectEqual(&new_child_static, parent.getGuestByCid(reused_cid));

    // Re-allocating dynamic handle allocates at cursor
    var new_child_dynamic: Guest = undefined;
    new_child_dynamic.local_cid = 0;
    new_child_dynamic.child_handle_next = null;
    const new_dyn_cid = try parent.allocChildHandle(&new_child_dynamic);
    try testing.expect(new_dyn_cid >= STATIC_CHILD_HANDLES + CID_FIRST_CHILD);
    try testing.expectEqual(&new_child_dynamic, parent.getGuestByCid(new_dyn_cid));

    // When cursor wraps around or points to freed slot 45, it reuses the hole
    parent.next_dynamic_handle = 45;
    var reused_child: Guest = undefined;
    reused_child.local_cid = 0;
    reused_child.child_handle_next = null;
    const hole_cid = try parent.allocChildHandle(&reused_child);
    try testing.expectEqual(allocated_cids[45], hole_cid);
    try testing.expectEqual(&reused_child, parent.getGuestByCid(hole_cid));
}

