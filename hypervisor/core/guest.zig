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
const debug = @import("debug.zig");
const scheduler = @import("scheduler.zig");
const interface = @import("interface");
const sbi = interface.sbi;

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

pub const max_child_handles: usize = 64;
pub const max_events: usize = 32;
pub const max_ipc_messages: usize = 16;
pub const max_ipc_msg_len: usize = 4096;
pub const max_vcores: usize = 128;
pub const max_vmids: u16 = 4096;

pub const DEFAULT_ROOT_MAX_VCPUS: usize = 16;
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

    pub fn push(self: *EventQueue, ev: sbi.Event) void {
        if (self.count >= max_events) {
            self.tail = (self.tail + 1) % max_events;
            self.count -= 1;
        }
        self.events[self.head] = ev;
        self.head = (self.head + 1) % max_events;
        self.count += 1;
    }

    pub fn pop(self: *EventQueue) ?sbi.Event {
        if (self.count == 0) return null;
        const ev = self.events[self.tail];
        self.tail = (self.tail + 1) % max_events;
        self.count -= 1;
        return ev;
    }
};

pub const IpcMessage = struct {
    sender_cid: usize,
    len: usize,
    data: [max_ipc_msg_len]u8,
};

pub const IpcInbox = struct {
    messages: [max_ipc_messages]IpcMessage = std.mem.zeroes([max_ipc_messages]IpcMessage),
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,

    pub fn push(self: *IpcInbox, sender_cid: usize, slice: []const u8) bool {
        if (self.count >= max_ipc_messages) return false;
        const copy_len = @min(slice.len, max_ipc_msg_len);
        self.messages[self.head].sender_cid = sender_cid;
        self.messages[self.head].len = copy_len;
        @memcpy(self.messages[self.head].data[0..copy_len], slice[0..copy_len]);
        self.head = (self.head + 1) % max_ipc_messages;
        self.count += 1;
        return true;
    }

    pub fn pop(self: *IpcInbox, sender_filter: usize) ?IpcMessage {
        if (self.count == 0) return null;
        if (sender_filter == 0) {
            const msg = self.messages[self.tail];
            self.tail = (self.tail + 1) % max_ipc_messages;
            self.count -= 1;
            return msg;
        }

        // Search for the oldest matching message in the ring buffer
        for (0..self.count) |offset| {
            const idx = (self.tail + offset) % max_ipc_messages;
            if (self.messages[idx].sender_cid == sender_filter) {
                const msg = self.messages[idx];
                // Shift preceding elements from tail forward to fill the hole
                var cur = idx;
                while (cur != self.tail) {
                    const prev = if (cur == 0) max_ipc_messages - 1 else cur - 1;
                    self.messages[cur] = self.messages[prev];
                    cur = prev;
                }
                self.tail = (self.tail + 1) % max_ipc_messages;
                self.count -= 1;
                return msg;
            }
        }
        return null;
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

    // Fast array mapping child CID (CID >= 2) to *Guest
    child_handles: [max_child_handles]?*Guest = std.mem.zeroes([max_child_handles]?*Guest),

    // Event queue for asynchronous child notifications
    events: EventQueue = .{},

    // Inter-VM IPC message inbox
    inbox: IpcInbox = .{},

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

    // Fast O(1) lookup from guest_hart_id to vcore.
    // Lock-free because vcores are only added during init before booting.
    vcore_lookup: [max_vcores]?*vcore.VirtualCore,

    // PIT (Programmable Interval Timer) State
    pit: PitState,

    // Shared IO-APIC backing memory for x86_64 guests
    ioapic_mem: [IOAPIC_PAGE_SIZE]u8,

    // Attenuated guest VM manifest buffer
    manifest: ?[]u8 = null,

    // allocator for heap-allocated Guest structures
    allocator: std.mem.Allocator,

    pub fn setManifest(self: *Guest, data: []const u8) !void {
        if (self.manifest) |m| {
            self.allocator.free(m);
            self.manifest = null;
        }
        const buf = try self.allocator.alloc(u8, data.len);
        @memcpy(buf, data);
        self.manifest = buf;
    }

    pub fn getManifest(self: *const Guest) ?[]const u8 {
        return self.manifest;
    }

    pub fn allocChildHandle(self: *Guest, child: *Guest) !usize {
        for (&self.child_handles, 0..) |*slot, i| {
            if (slot.* == null) {
                slot.* = child;
                return i + CID_FIRST_CHILD;
            }
        }
        return error.QuotaExceeded;
    }

    pub fn freeChildHandle(self: *Guest, child: *Guest) void {
        for (&self.child_handles) |*slot| {
            if (slot.* == child) {
                slot.* = null;
                break;
            }
        }
    }

    pub fn getGuestByCid(self: *Guest, cid: usize) ?*Guest {
        if (cid == CID_PARENT) {
            return self.parent;
        } else if (cid == CID_SELF) {
            return self;
        } else if (cid >= CID_FIRST_CHILD) {
            const idx = cid - CID_FIRST_CHILD;
            if (idx < max_child_handles) {
                return self.child_handles[idx];
            }
        }
        return null;
    }

    pub fn setQuota(self: *Guest, args: sbi.QuotaArgs) !void {
        if (args.target_cid == CID_SELF) {
            if (args.max_ram_pages > 0) self.quotas.max_ram_pages = @min(self.quotas.max_ram_pages, args.max_ram_pages);
            if (args.max_vcpus > 0) self.quotas.max_vcpus = @min(self.quotas.max_vcpus, args.max_vcpus);
            if (args.max_child_depth > 0) self.quotas.max_child_depth = @min(self.quotas.max_child_depth, args.max_child_depth);
            if (args.max_descendants > 0) self.quotas.max_descendants = @min(self.quotas.max_descendants, args.max_descendants);
        } else if (args.target_cid >= CID_FIRST_CHILD) {
            if (self.getGuestByCid(args.target_cid)) |child| {
                if (args.max_ram_pages > 0) {
                    child.quotas.max_ram_pages = @min(self.quotas.max_ram_pages, args.max_ram_pages);
                    child.quotas.used_ram_pages = child.quotas.max_ram_pages;
                }
                if (args.max_vcpus > 0) {
                    child.quotas.max_vcpus = @min(self.quotas.max_vcpus, args.max_vcpus);
                    child.quotas.used_vcpus = child.quotas.max_vcpus;
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

    pub fn sendIpc(self: *Guest, target_cid: usize, payload: []const u8) !void {
        const target = self.getGuestByCid(target_cid) orelse return error.InvalidParam;
        const sender_cid_for_target: usize = if (target_cid == CID_PARENT) self.local_cid else CID_PARENT;

        if (!target.inbox.push(sender_cid_for_target, payload)) {
            return error.QueueFull;
        }

        target.events.push(.{
            .cid = sender_cid_for_target,
            .event_type = @intFromEnum(sbi.EventType.ipc_message),
            .exit_code = @truncate(payload.len),
        });

        // Wake up / enqueue the target guest's virtual cores
        var it = target.vcores.start;
        while (it) |node| {
            scheduler.queue(node.contents);
            it = node.next;
        }
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
                .max_ram_pages = ram_pages,
                .used_ram_pages = ram_pages,
                .max_vcpus = DEFAULT_ROOT_MAX_VCPUS,
                .used_vcpus = 0,
            },
            .parent = parent,
            .children = .{ .start = null, .end = null },
            .child_node = null,
            .local_cid = CID_SELF,
            .child_handles = std.mem.zeroes([max_child_handles]?*Guest),
            .exit_code = 0,
            .vcores = .{ .start = null, .end = null },
            .vmid = try allocVmid(),
            .vcore_lookup = std.mem.zeroes([max_vcores]?*vcore.VirtualCore),
            .space = try vm_space.GuestSpace.init(allocator, is_trusted, base_gpa, base_hpa, range_size),

            .early_pgt_gpa = if (target_arch == .x86_64) base_gpa + X86_EARLY_PGT_GPA_OFFSET else 0,
            .pit = .{},
            .ioapic_mem = std.mem.zeroes([IOAPIC_PAGE_SIZE]u8),
            .allocator = allocator,
        };
        self.children.init();
        self.vcores.init();

        // Console input is restricted to the Root VM only.
        if (is_root) {
            debug.last_reader_guest_id = id;
        }

        if (parent) |p| {
            const node = try allocator.create(dsa.LinkedList(*Guest).Node);
            node.* = .{ .next = null, .previous = null, .contents = self };
            p.children.pushEnd(node);
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

        return self;
    }

    pub fn terminate(self: *Guest) void {
        self.terminateWithCode(0);
    }

    pub fn terminateWithCode(self: *Guest, exit_code: usize) void {
        if (self.state == .dying) return;
        self.state = .dying;
        self.exit_code = exit_code;

        // Release console focus
        debug.destroyGuestState(self.id);

        // Recursive termination of all children (cascading)
        while (self.children.popStart()) |node| {
            const child = node.contents;
            child.child_node = null;
            child.terminateWithCode(exit_code);
            self.allocator.destroy(node);
        }

        // Stop and free all vcores
        var it_vcore = self.vcores.start;
        while (it_vcore) |node| {
            node.contents.state = .stopped;
            it_vcore = node.next;
        }

        // Send an IPI to all CPUs to force them to reschedule and drop stopped vcores from their run_queues
        for (0..riscv.cpu_to_hart_map.len) |target_cpu| {
            if (riscv.CLINT.msip(riscv.cpu_to_hart_map[target_cpu])) |ptr| {
                ptr.* = 1;
            }
        }

        // Unlink from parent's children list and free child handle if still attached
        if (self.parent) |p| {
            p.events.push(.{
                .cid = self.local_cid,
                .event_type = @intFromEnum(sbi.EventType.child_terminated),
                .exit_code = @truncate(exit_code),
            });
            p.freeChildHandle(self);
            if (self.child_node) |node| {
                p.children.remove(node);
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
        if (self.quotas.used_ram_pages + ram_pages > self.quotas.max_ram_pages) return false;
        if (self.quotas.used_vcpus + vcpus > self.quotas.max_vcpus) return false;
        if (depth > self.quotas.max_child_depth) return false;
        if (self.quotas.used_descendants + 1 > self.quotas.max_descendants) return false;

        // Recursively check ancestors
        if (self.parent) |p| {
            return p.checkQuota(ram_pages, vcpus, depth);
        }
        return true;
    }

    pub fn consumeQuota(self: *Guest, ram_pages: usize, vcpus: usize) void {
        self.quotas.used_ram_pages += ram_pages;
        self.quotas.used_vcpus += vcpus;
        if (self.parent) |p| {
            p.consumeQuota(ram_pages, vcpus);
        }
    }

    pub fn deinit(self: *Guest) void {
        debug.destroyGuestState(self.id);
        var it_vcore = self.vcores.start;
        while (it_vcore) |node| {
            const next = node.next;
            node.contents.deinit(); // VCore might need its own cleanup
            self.allocator.destroy(node.contents);
            self.allocator.destroy(node);
            it_vcore = next;
        }

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
                p.children.remove(node);
                self.allocator.destroy(node);
                self.child_node = null;
            }
        }

        if (self.manifest) |m| {
            self.allocator.free(m);
            self.manifest = null;
        }

        freeVmid(self.vmid);
        self.allocator.destroy(self);
    }

    /// Add a virtual core to this guest.
    /// `sched_queue` is an optional scheduler enqueue function. Pass `null` if the vcore
    /// should not be auto-enrolled (e.g. stopped secondary harts, or testing).
    /// This dependency-injection pattern allows future support for multiple scheduler backends.
    pub fn addVcore(self: *Guest, vid: vcore.VirtualCoreID, entry: usize, dtb: usize, priority: vcore.Priority, sched_queue: ?*const fn (*vcore.VirtualCore) void) !*vcore.VirtualCore {
        const vc = try self.allocator.create(vcore.VirtualCore);
        errdefer self.allocator.destroy(vc);

        vc.* = vcore.VirtualCore.init(vid, self, entry, dtb, priority);
        vc.blocked_node.contents = @ptrCast(vc);
        if (vc.exec_path == .emulated) {
            vc.exec_path.emulated.context[@intFromEnum(riscv.Register.a0)] = @intFromPtr(vc);
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

        // Register in the O(1) lookup table if the hart ID fits.
        if (vid < max_vcores) {
            self.vcore_lookup[vid] = vc;
        } else {
            debug.printf("Warning: Guest {} created vcore with ID {} exceeding max_vcores ({})\n", .{ self.id, vid, max_vcores });
        }

        // Enroll the vcore in the scheduler if a queue function was provided.
        if (sched_queue) |q| {
            q(vc);
        }

        return vc;
    }

    pub fn findVcore(self: *const Guest, vid: vcore.VirtualCoreID) ?*vcore.VirtualCore {
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

    // Fork this guest to create a child VM
    pub fn fork(self: *Guest) !*Guest {
        const child_id = blk: {
            const guard = guest_manager.acquire();
            defer guard.release();
            const state = guard.get();
            const next = state.guest_id_next;
            state.guest_id_next = next + 1;
            break :blk next;
        };

        // Resource check: RAM=0 (fork is lazy), VCPUs=count, Depth=current+1
        const vcpu_count = self.vcores.count();
        if (!self.checkQuota(0, vcpu_count, self.quotas.current_depth + 1)) {
            return error.QuotaExceeded;
        }

        // Create new guest space with lazy forking
        const child_space = try self.space.fork();

        const child = try self.allocator.create(Guest);
        errdefer self.allocator.destroy(child);

        child.* = .{
            .id = child_id,
            .state = .valid,
            .is_trusted = self.is_trusted,
            .is_root = false, // Only the progenitor is truly root
            .target_arch = self.target_arch,
            .quotas = self.quotas,
            .parent = self,
            .children = .{ .start = null, .end = null },
            .child_node = null,
            .local_cid = CID_SELF,
            .child_handles = std.mem.zeroes([max_child_handles]?*Guest),
            .exit_code = 0,
            .vcores = .{ .start = null, .end = null },
            .vmid = try allocVmid(),
            .vcore_lookup = std.mem.zeroes([max_vcores]?*vcore.VirtualCore),
            .space = child_space,
            .early_pgt_gpa = if (self.target_arch == .x86_64) child_space.base_gpa + X86_EARLY_PGT_GPA_OFFSET else 0,
            .pit = .{},
            .ioapic_mem = std.mem.zeroes([IOAPIC_PAGE_SIZE]u8),
            .allocator = self.allocator,
        };
        child.children.init();
        child.vcores.init();

        // Lineage tracking
        const line_node = try self.allocator.create(dsa.LinkedList(*Guest).Node);
        line_node.* = .{ .next = null, .previous = null, .contents = child };
        self.children.pushEnd(line_node);
        child.child_node = line_node;
        child.local_cid = try self.allocChildHandle(child);
        child.quotas.current_depth = self.quotas.current_depth + 1;
        child.quotas.used_vcpus = vcpu_count;
        child.quotas.used_ram_pages = 0;

        // Ancestor tracking: consumed descendants and vcpus
        var p_opt: ?*Guest = self;
        while (p_opt) |p| {
            p.quotas.used_descendants += 1;
            p.quotas.used_vcpus += vcpu_count;
            p_opt = p.parent;
        }

        // Clone vcores

        var it_vcore = self.vcores.start;
        while (it_vcore) |node| {
            const vc = try node.contents.fork(child);
            const vc_node = try child.allocator.create(dsa.LinkedList(*vcore.VirtualCore).Node);
            vc_node.* = .{ .next = null, .previous = null, .contents = vc };
            child.vcores.pushEnd(vc_node);
            if (vc.id < max_vcores) {
                child.vcore_lookup[vc.id] = vc;
            }
            it_vcore = node.next;
        }

        return child;
    }

    // Create a new child VM with a clean memory space (for ELF loading)
    pub fn createChild(self: *Guest, is_trusted: bool, target_arch: TargetArch, vcpu_count: usize) !*Guest {
        const child_id = blk: {
            const guard = guest_manager.acquire();
            defer guard.release();
            const state = guard.get();
            const next = state.guest_id_next;
            state.guest_id_next = next + 1;
            break :blk next;
        };

        const num_vcpus = if (vcpu_count > 0) vcpu_count else 1;
        if (!self.checkQuota(0, num_vcpus, self.quotas.current_depth + 1)) {
            return error.QuotaExceeded;
        }

        const child_space = try vm_space.GuestSpace.init(self.allocator, is_trusted, self.space.base_gpa, 0, 0);

        const child = try self.allocator.create(Guest);
        errdefer self.allocator.destroy(child);

        child.* = .{
            .id = child_id,
            .state = .valid,
            .is_trusted = is_trusted,
            .is_root = false,
            .target_arch = target_arch,
            .quotas = self.quotas,
            .parent = self,
            .children = .{ .start = null, .end = null },
            .child_node = null,
            .local_cid = CID_SELF,
            .child_handles = std.mem.zeroes([max_child_handles]?*Guest),
            .exit_code = 0,
            .vcores = .{ .start = null, .end = null },
            .vmid = try allocVmid(),
            .vcore_lookup = std.mem.zeroes([max_vcores]?*vcore.VirtualCore),
            .space = child_space,
            .early_pgt_gpa = if (target_arch == .x86_64) child_space.base_gpa + X86_EARLY_PGT_GPA_OFFSET else 0,
            .pit = .{},
            .ioapic_mem = std.mem.zeroes([IOAPIC_PAGE_SIZE]u8),
            .allocator = self.allocator,
        };
        child.children.init();
        child.vcores.init();

        // Lineage tracking
        const line_node = try self.allocator.create(dsa.LinkedList(*Guest).Node);
        line_node.* = .{ .next = null, .previous = null, .contents = child };
        self.children.pushEnd(line_node);
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
            _ = try child.addVcore(@intCast(vc_id), 0, 0, .normal, null);
        }

        return child;
    }

    // Stop all virtual cores and wait for physical cores to relinquish them
    pub fn stop(self: *Guest) void {
        var it = self.vcores.start;
        while (it) |node| {
            const vc = node.contents;
            vc.state = .stopped;
            @atomicStore(bool, &vc.wfi_blocked, false, .release);

            if (!builtin.is_test) {
                if (vc.running_on_cpu) |home_cpu| {
                    if (home_cpu < riscv.cpu_to_hart_map.len) {
                        if (riscv.CLINT.msip(riscv.cpu_to_hart_map[home_cpu])) |ptr| {
                            ptr.* = 1;
                        }
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
                    std.atomic.spinLoopHint();
                }
                it = node.next;
            }
        }
    }

    // Reset all vcores for booting a new ELF entry point
    pub fn resetForSpawn(self: *Guest, entry: usize, dtb: usize) void {
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
    vmid_bitmap: [VMID_BITMAP_WORDS]u64 = std.mem.zeroes([VMID_BITMAP_WORDS]u64),
    guest_id_next: usize = CID_SELF,
};

var guest_manager = atomic.LockPayload(GuestManagerState).init("Global guest manager state", .{});

fn allocVmid() !u16 {
    const guard = guest_manager.acquire();
    defer guard.release();
    const state = guard.get();

    // Search for a free bit in the bitmap (skip bit 0 = VMID 0).
    for (&state.vmid_bitmap, 0..) |*word, wi| {
        if (word.* == ~@as(u64, 0)) continue; // All bits set, skip.
        const free_bit = @ctz(~word.*);
        const vmid: u16 = @intCast(wi * BITS_PER_WORD + free_bit);
        if (vmid == 0) {
            // VMID 0 is reserved; mark it used and continue searching.
            word.* |= @as(u64, 1) << @intCast(free_bit);
            continue;
        }
        word.* |= @as(u64, 1) << @intCast(free_bit);
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

test "guest fork and memory sharing" {
    const testing = std.testing;
    const allocator = testing.allocator;

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

    // Add a vcore so there is something to fork
    _ = try parent.addVcore(0, 0, 0, .normal, null);

    const child = try parent.fork();
    defer child.deinit();

    try testing.expect(child.id != parent.id);
    try testing.expect(child.vmid != parent.vmid);

    // Check that we have a vcore in the child
    try testing.expect(child.vcores.start != null);
    const child_vc = child.vcores.start.?.contents;
    try testing.expectEqual(@as(usize, 0), child_vc.exec_path.native.context[10]); // a0 is 0
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
    try testing.expectEqual(@as(usize, 0x1000), vc.exec_path.native.machine.mepc);

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

test "guest stop and resetForSpawn on multicore" {
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

    // Reset for spawn
    const new_entry: usize = 0x80400000;
    const new_dtb: usize = 0x82000000;
    parent.resetForSpawn(new_entry, new_dtb);

    // Bootstrap core (vc0) must be .ready, with updated PC and DTB
    try testing.expect(vc0.state == .ready);
    try testing.expectEqual(new_entry, vc0.exec_path.native.machine.mepc);
    try testing.expectEqual(@as(usize, 0), vc0.exec_path.native.context[@intFromEnum(riscv.Register.a0)]);
    try testing.expectEqual(new_dtb, vc0.exec_path.native.context[@intFromEnum(riscv.Register.a1)]);

    // Secondary core (vc1) must be .stopped awaiting SBI HSM start
    try testing.expect(vc1.state == .stopped);
    try testing.expectEqual(new_entry, vc1.exec_path.native.machine.mepc);
    try testing.expectEqual(@as(usize, 1), vc1.exec_path.native.context[@intFromEnum(riscv.Register.a0)]);
    try testing.expectEqual(new_dtb, vc1.exec_path.native.context[@intFromEnum(riscv.Register.a1)]);
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

    // Fork 3 children
    const child1 = try parent.fork();
    defer child1.deinit();
    const child2 = try parent.fork();
    defer child2.deinit();
    const child3 = try parent.fork();
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

test "guest quota management and inter-VM IPC" {
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

    const child = try parent.fork();
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

    // Child sends IPC message to parent (CID 0)
    const child_msg = "Hello parent from child";
    try child.sendIpc(CID_PARENT, child_msg);

    // Parent receives event notification
    const p_ev = parent.events.pop().?;
    try testing.expectEqual(@as(usize, 2), p_ev.cid);
    try testing.expectEqual(@as(u32, 4), p_ev.event_type); // ipc_message

    // Parent pops message from inbox
    const received_by_parent = parent.inbox.pop(0).?;
    try testing.expectEqual(@as(usize, 2), received_by_parent.sender_cid);
    try testing.expectEqual(child_msg.len, received_by_parent.len);
    try testing.expectEqualStrings(child_msg, received_by_parent.data[0..received_by_parent.len]);

    // Parent sends reply to child (CID 2)
    const parent_msg = "Hello child from parent";
    try parent.sendIpc(2, parent_msg);

    // Child receives event notification
    const c_ev = child.events.pop().?;
    try testing.expectEqual(@as(usize, 0), c_ev.cid); // From parent (CID 0)
    try testing.expectEqual(@as(u32, 4), c_ev.event_type);

    // Child pops message from inbox
    const received_by_child = child.inbox.pop(0).?;
    try testing.expectEqual(@as(usize, 0), received_by_child.sender_cid);
    try testing.expectEqual(parent_msg.len, received_by_child.len);
    try testing.expectEqualStrings(parent_msg, received_by_child.data[0..received_by_child.len]);

    // Test Guest manifest storage and retrieval
    const sample_manifest = "[vm]\nname = \"test-child\"\ncid = 2\n";
    try child.setManifest(sample_manifest);
    try testing.expect(child.getManifest() != null);
    try testing.expectEqualStrings(sample_manifest, child.getManifest().?);
}
