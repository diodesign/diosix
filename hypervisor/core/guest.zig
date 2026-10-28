// Guest Virtual Machine control block (Guest).
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
const sbi = @import("interface").sbi;
const emulation = @import("emulation");
const config = @import("config");

pub const queues_mod = @import("guest/queues.zig");
pub const quota_mod = @import("guest/quota.zig");
pub const lineage_mod = @import("guest/lineage.zig");

pub const GuestID = usize;
pub const GuestState = enum(u8) {
    valid,
    dying,
    restarting,

    pub const active = GuestState.valid;
};
pub const GuestLifecycleState = GuestState;
pub const QuotaSet = quota_mod.QuotaSet;
pub const TargetArch = sbi.TargetArch;

pub const CID_PARENT: usize = sbi.CID_PARENT;
pub const CID_SELF: usize = sbi.CID_SELF;
pub const CID_FIRST_CHILD: usize = sbi.CID_FIRST_CHILD;

pub const STATIC_CHILD_HANDLES: usize = lineage_mod.STATIC_CHILD_HANDLES;
pub const DYNAMIC_CHILD_BUCKETS: usize = lineage_mod.DYNAMIC_CHILD_BUCKETS;
pub const MAX_CHILD_HANDLES: usize = lineage_mod.MAX_CHILD_HANDLES;
pub const max_child_handles: usize = MAX_CHILD_HANDLES;
pub const max_events: usize = queues_mod.max_events;
pub const max_vcores: usize = 4096;
pub const STATIC_VCORES: usize = lineage_mod.STATIC_VCORES;
pub const VCORE_HASH_BUCKETS: usize = lineage_mod.VCORE_HASH_BUCKETS;
pub const max_vmids: u16 = quota_mod.max_vmids;

pub const DEFAULT_ROOT_MAX_VCPUS: usize = max_vcores;
pub const MAX_MANIFEST_SIZE_BYTES: usize = 1024 * 1024;
pub const IOAPIC_PAGE_SIZE: usize = physmem.PageSize;
pub const X86_EARLY_PGT_GPA_OFFSET: usize = 0x70000;
pub const CHILD_RV_BASE_GPA: usize = 0xe0000000;
pub const CHILD_ARM64_BASE_GPA: usize = 0x40000000;

pub const PIT_NUM_CHANNELS: usize = queues_mod.PIT_NUM_CHANNELS;
pub const PIT_ACCESS_LSB_MSB: u8 = queues_mod.PIT_ACCESS_LSB_MSB;
pub const PIT_PORT61_GATE2_ENABLED: u8 = queues_mod.PIT_PORT61_GATE2_ENABLED;
pub const PIC_ALL_IRQS_MASKED: u8 = queues_mod.PIC_ALL_IRQS_MASKED;
pub const BITS_PER_WORD: usize = quota_mod.BITS_PER_WORD;
pub const VMID_BITMAP_WORDS: usize = quota_mod.VMID_BITMAP_WORDS;

pub const PitChannel = queues_mod.PitChannel;
pub const PitState = queues_mod.PitState;
pub const EventQueue = queues_mod.EventQueue;
pub const MAX_PACKET_LEN: usize = queues_mod.MAX_PACKET_LEN;
pub const MAX_NET_PACKETS: usize = queues_mod.MAX_NET_PACKETS;
pub const Packet = queues_mod.Packet;
pub const PacketQueue = queues_mod.PacketQueue;
pub const CONSOLE_TX_CAPACITY = queues_mod.CONSOLE_TX_CAPACITY;
pub const CONSOLE_RX_CAPACITY = queues_mod.CONSOLE_RX_CAPACITY;
pub const ConsoleTxRing = queues_mod.ConsoleTxRing;
pub const ConsoleRxRing = queues_mod.ConsoleRxRing;

pub const Guest = struct {
    id: GuestID,
    state: GuestState,
    is_trusted: bool,
    is_root: bool,
    is_steward: bool = false,
    is_standby_root: bool = false,
    is_confidential: bool = false,
    target_arch: TargetArch,
    quotas: QuotaSet,
    parent: ?*Guest,
    children: dsa.LinkedList(*Guest),
    child_node: ?*dsa.LinkedList(*Guest).Node = null,
    local_cid: usize = CID_SELF,
    child_static_handles: [STATIC_CHILD_HANDLES]?*Guest = @splat(null),
    child_dynamic_buckets: [DYNAMIC_CHILD_BUCKETS]?*Guest = @splat(null),
    child_handle_next: ?*Guest = null,
    next_static_handle: usize = 0,
    next_dynamic_handle: usize = STATIC_CHILD_HANDLES,
    events: EventQueue = .{},
    net_rx: PacketQueue = .{},
    whisper_rx: PacketQueue = .{},
    console_tx: ConsoleTxRing = .{},
    console_rx: ConsoleRxRing = .{},
    initial_entry_point: usize = 0,
    initial_dtb_ptr: usize = 0,
    steward_reset_count: usize = 0,
    exit_code: usize = 0,
    vcores: dsa.LinkedList(*vcore.VirtualCore),
    space: vm_space.GuestSpace,
    vmid: u16,
    early_pgt_gpa: usize,
    vcore_static: [STATIC_VCORES]?*vcore.VirtualCore = @splat(null),
    vcore_dynamic_buckets: [VCORE_HASH_BUCKETS]?*vcore.VirtualCore =
        @splat(null),
    pit: PitState,
    ioapic_mem: [IOAPIC_PAGE_SIZE]u8,
    manifest: ?[]u8 = null,
    manifest_lock: atomic.SpinLock = atomic.SpinLock.init(),
    tree_lock: atomic.SpinLock = atomic.SpinLock.init(),
    vsock: emulation.VirtioVsock = .{},
    uart: emulation.VirtualUart = .{},
    timer: emulation.VirtualTimer = .{},
    pic: emulation.VirtualPlic = .{},
    allocator: std.mem.Allocator,

    pub const allocChildHandle = lineage_mod.allocChildHandle;
    pub const freeChildHandle = lineage_mod.freeChildHandle;
    pub const getGuestByCid = lineage_mod.getGuestByCid;
    pub const findVcore = lineage_mod.findVcore;
    pub const createChild = lineage_mod.createChild;
    pub const terminateWithCode = lineage_mod.terminateWithCode;
    pub const resetSteward = lineage_mod.resetSteward;
    pub const findStandbyRoot = lineage_mod.findStandbyRoot;
    pub const promoteStandbyRoot = lineage_mod.promoteStandbyRoot;
    pub const setQuota = quota_mod.setQuota;
    pub const reduceQuota = quota_mod.reduceQuota;
    pub const onMemoryPoolExhausted = quota_mod.onMemoryPoolExhausted;
    pub const checkQuota = quota_mod.checkQuota;
    pub const checkRamQuota = quota_mod.checkRamQuota;
    pub const consumeQuota = quota_mod.consumeQuota;
    pub const releaseQuota = quota_mod.releaseQuota;
    pub const setManifest = quota_mod.setManifest;
    pub const readManifest = quota_mod.readManifest;
    pub const getManifestLength = quota_mod.getManifestLength;
    pub const stop = quota_mod.stop;
    pub const resetForRun = quota_mod.resetForRun;
    pub const hasAnyVcoreStarted = quota_mod.hasAnyVcoreStarted;
    pub const checkVcpuQuota = quota_mod.checkVcpuQuota;

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

    pub fn guestUartOutput(char: u8) void {
        debug.putchar(char);
    }

    pub fn init(
        allocator: std.mem.Allocator,
        id: GuestID,
        is_trusted: bool,
        is_root: bool,
        parent: ?*Guest,
        base_gpa: usize,
        base_hpa: usize,
        range_size: usize,
        target_arch: TargetArch,
    ) !*Guest {
        const vmid = try quota_mod.allocVmid();
        errdefer quota_mod.freeVmid(vmid);

        var space = try vm_space.GuestSpace.init(
            allocator,
            is_trusted,
            base_gpa,
            base_hpa,
            range_size,
        );
        errdefer space.deinit();

        const self = try allocator.create(Guest);
        errdefer allocator.destroy(self);

        self.* = .{
            .id = id,
            .state = .valid,
            .is_trusted = is_trusted,
            .is_root = is_root,
            .target_arch = target_arch,
            .quotas = if (parent) |p| p.quotas else .{
                .max_ram_pages = std.math.maxInt(usize),
                .used_ram_pages = 0,
                .max_vcpus = std.math.maxInt(usize),
                .used_vcpus = 0,
                .pcpu_quota_pct = 100,
                .delegated_pcpu_pct = 0,
            },
            .parent = parent,
            .children = .{ .start = null, .end = null },
            .vcores = .{ .start = null, .end = null },
            .vmid = vmid,
            .space = space,
            .early_pgt_gpa = if (target_arch == .x86_64)
                base_gpa + X86_EARLY_PGT_GPA_OFFSET
            else
                0,
            .pit = .{},
            .ioapic_mem = @splat(0),
            .uart = .{ .guest_id = id, .out_fn = guestUartOutput },
            .allocator = allocator,
        };
        self.children.init();
        self.vcores.init();

        if (parent) |p| {
            const node = try allocator.create(dsa.LinkedList(*Guest).Node);
            errdefer allocator.destroy(node);
            self.local_cid = try p.allocChildHandle(self);
            errdefer p.freeChildHandle(self);
            node.* = .{ .next = null, .previous = null, .contents = self };
            {
                const s = p.tree_lock.lock();
                p.children.pushEnd(node);
                p.tree_lock.unlock(s);
            }
            self.child_node = node;
            self.quotas.current_depth = p.quotas.current_depth + 1;
            var p_anc: ?*Guest = p;
            while (p_anc) |anc| : (p_anc = anc.parent) {
                anc.quotas.used_descendants += 1;
            }
        }

        self.vsock = emulation.VirtioVsock{
            .guest_cid = self.local_cid,
            .mem = .{
                .ctx = self,
                .readFn = guestReadMemory,
                .writeFn = guestWriteMemory,
            },
            .router = emulation.global_vsock_router,
        };
        emulation.global_vsock_router.register(&self.vsock);
        return self;
    }

    pub fn terminate(self: *Guest) void {
        self.terminateWithCode(0);
    }

    pub fn dropTrust(self: *Guest) void {
        self.is_trusted = false;
        self.space.is_trusted = false;
    }

    pub fn unregisterResources(self: *Guest) void {
        const old_manifest = blk: {
            const s = self.manifest_lock.lock();
            defer self.manifest_lock.unlock(s);
            const m = self.manifest;
            self.manifest = null;
            break :blk m;
        };
        if (old_manifest) |m| self.allocator.free(m);

        const main = @import("../main.zig");
        if (main.global_root_vm == self) main.global_root_vm = null;
        emulation.global_vsock_router.unregister(self.local_cid);
        if (self.vmid != 0) {
            quota_mod.freeVmid(self.vmid);
            self.vmid = 0;
        }
    }

    pub fn deinit(self: *Guest) void {
        var it_vcore = self.vcores.start;
        while (it_vcore) |node| {
            const next = node.next;
            node.contents.deinit();
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
            node.contents.parent = null;
            node.contents.child_node = null;
            self.allocator.destroy(node);
            it_child = next;
        }
        if (self.parent) |p| {
            p.quotas.delegated_pcpu_pct -|= self.quotas.pcpu_quota_pct;
            p.quotas.delegated_ram_pages -|= self.quotas.committed_ram_pages;
            p.freeChildHandle(self);
            if (self.child_node) |node| {
                const s = p.tree_lock.lock();
                p.children.remove(node);
                p.tree_lock.unlock(s);
                self.allocator.destroy(node);
                self.child_node = null;
            }
        }
        self.unregisterResources();
        self.allocator.destroy(self);
    }

    pub fn addVcore(
        self: *Guest,
        vid: vcore.VirtualCoreID,
        entry: usize,
        dtb: usize,
        priority: vcore.Priority,
        sched_queue: ?*const fn (*vcore.VirtualCore) void,
    ) !*vcore.VirtualCore {
        if (self.findVcore(vid) != null) return error.DuplicateVcore;
        const vc = try self.allocator.create(vcore.VirtualCore);
        errdefer self.allocator.destroy(vc);
        vc.* = try vcore.VirtualCore.initChecked(
            vid,
            self,
            entry,
            dtb,
            priority,
        );
        errdefer vc.deinit();
        vc.blocked_node.contents = @ptrCast(vc);
        if (vc.exec_path == .emulated) {
            vc.context[@backingInt(riscv.Register.a0)] = @intFromPtr(vc);
        }
        const VcNode = dsa.LinkedList(*vcore.VirtualCore).Node;
        const node = try self.allocator.create(VcNode);
        node.* = .{ .next = null, .previous = null, .contents = vc };
        self.vcores.pushEnd(node);
        self.quotas.used_vcpus = self.vcores.count();
        lineage_mod.registerVcoreLookup(self, vid, vc);
        if (sched_queue) |q| q(vc);
        return vc;
    }

    pub fn addMemoryRegion(
        self: *Guest,
        gpa: usize,
        hpa: usize,
        size: usize,
        flags: u64,
    ) !void {
        try self.space.map(gpa, hpa, size, flags);
    }
};

pub fn createGuest(
    allocator: std.mem.Allocator,
    is_trusted: bool,
    is_root: bool,
    parent: ?*Guest,
    base_gpa: usize,
    base_hpa: usize,
    range_size: usize,
    target_arch: TargetArch,
) !*Guest {
    const id = quota_mod.allocGuestId();
    return try Guest.init(
        allocator,
        id,
        is_trusted,
        is_root,
        parent,
        base_gpa,
        base_hpa,
        range_size,
        target_arch,
    );
}

test "guest lifecycle, cascading termination, and multicore reset" {
    const testing = std.testing;
    _ = queues_mod;
    _ = quota_mod;
    _ = lineage_mod;
    _ = @import("guest/failover.zig");
    _ = @import("guest/dtb.zig");
    std.testing.refAllDecls(@This());
    scheduler.init();
    scheduler.initCpu();
    quota_mod.resetGuestManagerForTest();

    var phys_test = try physmem.initForTest(testing.allocator, 256);
    defer phys_test.deinit();

    const parent = try createGuest(
        testing.allocator,
        true,
        true,
        null,
        0,
        0,
        0x10000,
        .riscv64,
    );
    defer parent.deinit();

    const vc0 = try parent.addVcore(0, 0x80200000, 0x81000000, .normal, null);
    const vc1 = try parent.addVcore(1, 0x80200000, 0x81000000, .normal, null);
    vc0.state = .running;
    vc1.state = .running;
    parent.stop();
    try testing.expectEqual(vcore.VirtualCoreState.stopped, vc0.state);
    try testing.expectEqual(vcore.VirtualCoreState.stopped, vc1.state);

    parent.resetForRun(0x80400000, 0x82000000);
    try testing.expectEqual(vcore.VirtualCoreState.ready, vc0.state);
    try testing.expectEqual(vcore.VirtualCoreState.stopped, vc1.state);

    const initial_vcpus = parent.quotas.used_vcpus;
    const child1 = try parent.createChild(false, .riscv64, 1);
    defer child1.deinit();
    const child2 = try parent.createChild(false, .riscv64, 1);
    defer child2.deinit();
    try testing.expectEqual(@as(usize, 2), child1.local_cid);
    try testing.expectEqual(@as(usize, 3), child2.local_cid);
    try testing.expectEqual(@as(usize, 2), parent.children.count());

    child1.terminateWithCode(42);
    try testing.expectEqual(@as(usize, 42), child1.exit_code);
    try testing.expect(parent.getGuestByCid(2) == null);

    child2.terminateWithCode(0);
    try testing.expectEqual(initial_vcpus, parent.quotas.used_vcpus);
    try testing.expectEqual(@as(usize, 2), parent.events.count);

    parent.dropTrust();
    try testing.expect(!parent.is_trusted and !parent.space.is_trusted);
}
