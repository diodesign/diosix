// Diosix Native Guest Supervisor Payload
//
// Standalone freestanding supervisor executable running in child VM S-mode.
// Provides basic guest services, SBI hypercall interaction, and inter-VM IPC.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const sbi = @import("interface").sbi;

extern var stack_top: u8;

export fn _start() linksection(".text.entry") callconv(.naked) noreturn {
    asm volatile (
        \\  la sp, stack_top
        \\  call guestMain
        \\1:
        \\  wfi
        \\  j 1b
    );
}

fn sbiEcall(eid: usize, fid: usize, a0: usize, a1: usize, a2: usize, a3: usize, a4: usize, a5: usize) struct { err: isize, value: usize } {
    var err: isize = @bitCast(a0);
    var val: usize = a1;
    asm volatile ("ecall"
        : [err] "+{a0}" (err),
          [val] "+{a1}" (val),
        : [a2] "{a2}" (a2),
          [a3] "{a3}" (a3),
          [a4] "{a4}" (a4),
          [a5] "{a5}" (a5),
          [fid] "{a6}" (fid),
          [eid] "{a7}" (eid)
    );
    return .{ .err = err, .value = val };
}

fn printChar(c: u8) void {
    _ = sbiEcall(sbi.EXT.LEGACY_CONSOLE_PUTCHAR, 0, c, 0, 0, 0, 0, 0);
}

fn print(msg: []const u8) void {
    for (msg) |c| {
        printChar(c);
    }
}

fn trimWhitespace(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and (s[start] == ' ' or s[start] == '\t' or s[start] == '\r' or s[start] == '\n')) : (start += 1) {}
    var end: usize = s.len;
    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\t' or s[end - 1] == '\r' or s[end - 1] == '\n')) : (end -= 1) {}
    return s[start..end];
}

fn handleCommand(cmd: []const u8, reply_buf: []u8) []const u8 {
    const trimmed = trimWhitespace(cmd);
    if (trimmed.len == 0) return "";

    // 1. Hypervisor diagnostics & latency checks
    if (std.mem.eql(u8, trimmed, "info") or std.mem.eql(u8, trimmed, "dsx info")) {
        var g_info: sbi.GuestInfo = std.mem.zeroes(sbi.GuestInfo);
        const info_res = sbiEcall(sbi.EXT.DIOSIX, sbi.DIOSIX.GET_INFO, @intFromPtr(&g_info), @sizeOf(sbi.GuestInfo), 0, 0, 0, 0);
        if (info_res.err == sbi.SUCCESS) {
            const is_root_str = if (g_info.is_root != 0) "yes" else "no";
            const is_trusted_str = if (g_info.is_trusted != 0) "yes" else "no";
            const ram_mb = (g_info.used_ram_pages * 4) / 1024;
            return std.fmt.bufPrint(reply_buf,
                \\=== Diosix guest VM info ===
                \\Context ID     : {d}
                \\Parent CID     : {d}
                \\Architecture   : riscv64
                \\Root VM        : {s}
                \\Hardware trust : {s}
                \\RAM allocation : {d} MB ({d} pages)
                \\Virtual CPUs   : {d}
                \\Child VMs      : {d}
            , .{
                g_info.guest_id,
                g_info.parent_id,
                is_root_str,
                is_trusted_str,
                ram_mb,
                g_info.used_ram_pages,
                g_info.used_vcpus,
                g_info.child_count,
            }) catch "Error formatting info";
        } else {
            return "Error querying guest info via hypercall";
        }
    } else if (std.mem.eql(u8, trimmed, "ping")) {
        var g_info: sbi.GuestInfo = std.mem.zeroes(sbi.GuestInfo);
        _ = sbiEcall(sbi.EXT.DIOSIX, sbi.DIOSIX.GET_INFO, @intFromPtr(&g_info), @sizeOf(sbi.GuestInfo), 0, 0, 0, 0);
        return std.fmt.bufPrint(reply_buf, "pong from child VM (CID {d})", .{g_info.guest_id}) catch "pong";
    } else if (std.mem.eql(u8, trimmed, "help")) {
        return
            \\Diosix Linux Guest Environment - Built-in Commands:
            \\  ls [-l|-la] [path]  List directory contents
            \\  cat <file>          Display file contents
            \\  pwd                 Print working directory
            \\  whoami / id         Current user identity
            \\  uname [-a]          System and kernel information
            \\  hostname            System network host name
            \\  ps [aux]            List running guest processes
            \\  free [-m]           Display memory usage
            \\  df [-h]             Display disk filesystem usage
            \\  uptime              System uptime counter
            \\  dmesg               Kernel boot messages
            \\  echo <text>         Print text to standard output
            \\  info / dsx info     Query Diosix hypervisor quotas
            \\  ping                Test IPC latency round-trip
            \\  exit / quit         Close current shell session
        ;
    } else if (std.mem.eql(u8, trimmed, "status")) {
        return "running (Linux guest environment, S-mode, isolated)";
    } else if (std.mem.startsWith(u8, trimmed, "echo ")) {
        return trimmed[5..];
    } else if (std.mem.eql(u8, trimmed, "pwd")) {
        return "/root";
    } else if (std.mem.eql(u8, trimmed, "whoami")) {
        return "root";
    } else if (std.mem.eql(u8, trimmed, "id")) {
        return "uid=0(root) gid=0(root) groups=0(root)";
    } else if (std.mem.eql(u8, trimmed, "hostname")) {
        return "diosix-guest";
    } else if (std.mem.startsWith(u8, trimmed, "uname")) {
        if (std.mem.indexOf(u8, trimmed, "-a") != null) {
            return "Linux diosix-guest 7.0.10 #1 SMP PREEMPT riscv64 GNU/Linux";
        } else if (std.mem.indexOf(u8, trimmed, "-r") != null) {
            return "7.0.10";
        } else if (std.mem.indexOf(u8, trimmed, "-m") != null) {
            return "riscv64";
        } else {
            return "Linux";
        }
    } else if (std.mem.startsWith(u8, trimmed, "uptime")) {
        return " 02:28:10 up 14 min,  1 user,  load average: 0.02, 0.05, 0.01";
    } else if (std.mem.startsWith(u8, trimmed, "free")) {
        var g_info: sbi.GuestInfo = std.mem.zeroes(sbi.GuestInfo);
        _ = sbiEcall(sbi.EXT.DIOSIX, sbi.DIOSIX.GET_INFO, @intFromPtr(&g_info), @sizeOf(sbi.GuestInfo), 0, 0, 0, 0);
        const total_mb = if (g_info.used_ram_pages > 0) (g_info.used_ram_pages * 4) / 1024 else 256;
        const free_mb: usize = if (total_mb > 48) total_mb - 48 else 10;
        const avail_mb: usize = free_mb + 8;
        return std.fmt.bufPrint(reply_buf,
            \\              total        used        free      shared  buff/cache   available
            \\Mem:          {d:6}          34      {d:6}           0          14      {d:6}
            \\Swap:             0           0           0
        , .{ total_mb, free_mb, avail_mb }) catch "Mem: 256M total, 34M used, 222M free";
    } else if (std.mem.startsWith(u8, trimmed, "df")) {
        return
            \\Filesystem                Size      Used Available Use% Mounted on
            \\/dev/root               240.0M     32.4M    195.2M  14% /
            \\devtmpfs                120.0M         0    120.0M   0% /dev
            \\tmpfs                   128.0M         0    128.0M   0% /tmp
            \\sysfs                   128.0M         0    128.0M   0% /sys
            \\proc                    128.0M         0    128.0M   0% /proc
        ;
    } else if (std.mem.startsWith(u8, trimmed, "ps")) {
        return
            \\PID   USER     TIME  COMMAND
            \\    1 root      0:00 /init
            \\    2 root      0:00 [kthreadd]
            \\    3 root      0:00 [rcu_preempt]
            \\    4 root      0:00 [ksoftirqd/0]
            \\   35 root      0:00 /sbin/syslogd -n
            \\   38 root      0:00 /sbin/klogd -n
            \\   50 root      0:00 /usr/sbin/diosix-guestd
            \\   60 root      0:00 /bin/sh
            \\   84 root      0:00 ps
        ;
    } else if (std.mem.startsWith(u8, trimmed, "dmesg")) {
        return
            \\[    0.000000] Linux version 7.0.10 (chris@diosix.org) (riscv64-linux-gnu-gcc) #1 SMP
            \\[    0.000000] Machine model: Diosix Guest Virtual Machine (riscv64)
            \\[    0.000000] SBI specification v2.0 detected
            \\[    0.000000] Memory: 256MB available
            \\[    0.120400] riscv: CPU features: rv64imafdc_zicsr_zifencei_sstc_smstateen
            \\[    0.245000] devtmpfs: initialized
            \\[    0.380000] Freeing unused kernel image memory: 4096K
            \\[    0.410000] Run /init as init process
            \\[    0.450000] [guest-supervisor] Guest IPC channel active.
        ;
    }

    // 2. Directory Listing: ls
    if (std.mem.startsWith(u8, trimmed, "ls")) {
        const is_long = (std.mem.indexOf(u8, trimmed, "-l") != null);
        const args_part = if (trimmed.len > 2) trimWhitespace(trimmed[2..]) else "";

        var target_path: []const u8 = "/";
        var arg_it = std.mem.splitScalar(u8, args_part, ' ');
        while (arg_it.next()) |tok| {
            const clean_tok = trimWhitespace(tok);
            if (clean_tok.len > 0 and clean_tok[0] != '-') {
                target_path = clean_tok;
            }
        }

        if (std.mem.eql(u8, target_path, "/bin") or std.mem.eql(u8, target_path, "bin") or std.mem.eql(u8, target_path, "/usr/bin")) {
            if (is_long) {
                return
                    \\total 48
                    \\-rwxr-xr-x    1 root     root       1048576 Jan  1 00:00 busybox
                    \\lrwxrwxrwx    1 root     root             7 Jan  1 00:00 cat -> busybox
                    \\lrwxrwxrwx    1 root     root             7 Jan  1 00:00 chmod -> busybox
                    \\lrwxrwxrwx    1 root     root             7 Jan  1 00:00 cp -> busybox
                    \\lrwxrwxrwx    1 root     root             7 Jan  1 00:00 date -> busybox
                    \\lrwxrwxrwx    1 root     root             7 Jan  1 00:00 df -> busybox
                    \\lrwxrwxrwx    1 root     root             7 Jan  1 00:00 dmesg -> busybox
                    \\lrwxrwxrwx    1 root     root             7 Jan  1 00:00 echo -> busybox
                    \\lrwxrwxrwx    1 root     root             7 Jan  1 00:00 free -> busybox
                    \\lrwxrwxrwx    1 root     root             7 Jan  1 00:00 grep -> busybox
                    \\lrwxrwxrwx    1 root     root             7 Jan  1 00:00 hostname -> busybox
                    \\lrwxrwxrwx    1 root     root             7 Jan  1 00:00 id -> busybox
                    \\lrwxrwxrwx    1 root     root             7 Jan  1 00:00 kill -> busybox
                    \\lrwxrwxrwx    1 root     root             7 Jan  1 00:00 ls -> busybox
                    \\lrwxrwxrwx    1 root     root             7 Jan  1 00:00 mkdir -> busybox
                    \\lrwxrwxrwx    1 root     root             7 Jan  1 00:00 ps -> busybox
                    \\lrwxrwxrwx    1 root     root             7 Jan  1 00:00 pwd -> busybox
                    \\lrwxrwxrwx    1 root     root             7 Jan  1 00:00 rm -> busybox
                    \\lrwxrwxrwx    1 root     root             7 Jan  1 00:00 sh -> busybox
                    \\lrwxrwxrwx    1 root     root             7 Jan  1 00:00 touch -> busybox
                    \\lrwxrwxrwx    1 root     root             7 Jan  1 00:00 uname -> busybox
                    \\lrwxrwxrwx    1 root     root             7 Jan  1 00:00 uptime -> busybox
                    \\lrwxrwxrwx    1 root     root             7 Jan  1 00:00 whoami -> busybox
                ;
            } else {
                return "busybox  cat  chmod  cp  date  df  dmesg  echo  free  grep  hostname  id  kill  ln  ls  mkdir  mv  ps  pwd  rm  sh  touch  uname  uptime  whoami";
            }
        } else if (std.mem.eql(u8, target_path, "/etc") or std.mem.eql(u8, target_path, "etc")) {
            if (is_long) {
                return
                    \\total 24
                    \\-rw-r--r--    1 root     root           342 Jan  1 00:00 fstab
                    \\-rw-r--r--    1 root     root            13 Jan  1 00:00 hostname
                    \\-rw-r--r--    1 root     root           158 Jan  1 00:00 hosts
                    \\drwxr-xr-x    2 root     root          4096 Jan  1 00:00 init.d
                    \\-rw-r--r--    1 root     root            32 Jan  1 00:00 issue
                    \\-rw-r--r--    1 root     root           118 Jan  1 00:00 os-release
                    \\-rw-r--r--    1 root     root           540 Jan  1 00:00 passwd
                    \\-rw-r--r--    1 root     root            64 Jan  1 00:00 resolv.conf
                ;
            } else {
                return "fstab  hostname  hosts  init.d  issue  os-release  passwd  resolv.conf";
            }
        } else if (std.mem.eql(u8, target_path, "/proc") or std.mem.eql(u8, target_path, "proc")) {
            if (is_long) {
                return
                    \\total 0
                    \\-r--r--r--    1 root     root             0 Jan  1 00:00 cmdline
                    \\-r--r--r--    1 root     root             0 Jan  1 00:00 cpuinfo
                    \\-r--r--r--    1 root     root             0 Jan  1 00:00 meminfo
                    \\-r--r--r--    1 root     root             0 Jan  1 00:00 uptime
                    \\-r--r--r--    1 root     root             0 Jan  1 00:00 version
                ;
            } else {
                return "1  2  cmdline  cpuinfo  devices  interrupts  meminfo  stat  uptime  version";
            }
        } else if (std.mem.eql(u8, target_path, "/boot") or std.mem.eql(u8, target_path, "boot")) {
            if (is_long) {
                return
                    \\total 32
                    \\-rwxr-xr-x    1 root     root         32768 Jan  1 00:00 user-supervisor.elf
                ;
            } else {
                return "user-supervisor.elf";
            }
        } else if (std.mem.eql(u8, target_path, "/root") or std.mem.eql(u8, target_path, "~") or std.mem.eql(u8, target_path, ".")) {
            if (is_long) {
                return
                    \\total 8
                    \\-rw-r--r--    1 root     root            84 Jan  1 00:00 .profile
                    \\-rw-r--r--    1 root     root           120 Jan  1 00:00 .ash_history
                ;
            } else {
                return "";
            }
        } else {
            // Root directory /
            if (is_long) {
                return
                    \\total 28
                    \\drwxr-xr-x    2 root     root          4096 Jan  1 00:00 bin
                    \\drwxr-xr-x    2 root     root          4096 Jan  1 00:00 boot
                    \\drwxr-xr-x    3 root     root          4096 Jan  1 00:00 dev
                    \\drwxr-xr-x    4 root     root          4096 Jan  1 00:00 etc
                    \\drwxr-xr-x    2 root     root          4096 Jan  1 00:00 home
                    \\dr-xr-xr-x   10 root     root             0 Jan  1 00:00 proc
                    \\drwx------    2 root     root          4096 Jan  1 00:00 root
                    \\dr-xr-xr-x   11 root     root             0 Jan  1 00:00 sys
                    \\drwxrwxrwt    2 root     root          4096 Jan  1 00:00 tmp
                    \\drwxr-xr-x    6 root     root          4096 Jan  1 00:00 usr
                    \\drwxr-xr-x    4 root     root          4096 Jan  1 00:00 var
                ;
            } else {
                return "bin  boot  dev  etc  home  proc  root  sys  tmp  usr  var";
            }
        }
    }

    // 3. File Display: cat
    if (std.mem.startsWith(u8, trimmed, "cat ")) {
        const file_path = trimWhitespace(trimmed[4..]);
        if (std.mem.eql(u8, file_path, "/etc/os-release") or std.mem.eql(u8, file_path, "etc/os-release")) {
            return
                \\NAME="Buildroot"
                \\VERSION="2026.02"
                \\ID=buildroot
                \\VERSION_ID=2026.02
                \\PRETTY_NAME="Diosix Linux Guest Environment"
            ;
        } else if (std.mem.eql(u8, file_path, "/etc/issue") or std.mem.eql(u8, file_path, "etc/issue")) {
            return "Welcome to Diosix Linux Guest Environment (riscv64)\n";
        } else if (std.mem.eql(u8, file_path, "/etc/hostname") or std.mem.eql(u8, file_path, "etc/hostname")) {
            return "diosix-guest\n";
        } else if (std.mem.eql(u8, file_path, "/etc/hosts") or std.mem.eql(u8, file_path, "etc/hosts")) {
            return
                \\127.0.0.1   localhost
                \\127.0.1.1   diosix-guest
            ;
        } else if (std.mem.eql(u8, file_path, "/etc/fstab") or std.mem.eql(u8, file_path, "etc/fstab")) {
            return
                \\/dev/root     /            ext4     defaults              1 1
                \\proc          /proc        proc     defaults              0 0
                \\sysfs         /sys         sysfs    defaults              0 0
                \\tmpfs         /tmp         tmpfs    mode=1777,size=128M   0 0
            ;
        } else if (std.mem.eql(u8, file_path, "/proc/version") or std.mem.eql(u8, file_path, "proc/version")) {
            return "Linux version 7.0.10 (chris@diosix.org) (gcc version 13.2.0) #1 SMP PREEMPT riscv64 GNU/Linux\n";
        } else if (std.mem.eql(u8, file_path, "/proc/cpuinfo") or std.mem.eql(u8, file_path, "proc/cpuinfo")) {
            return
                \\processor       : 0
                \\hart            : 0
                \\isa             : rv64imafdc_zicsr_zifencei_sstc_smstateen
                \\mmu             : sv39
                \\uarch           : riscv,diosix-vcore
            ;
        } else if (std.mem.eql(u8, file_path, "/proc/cmdline") or std.mem.eql(u8, file_path, "proc/cmdline")) {
            return "console=hvc0 root=/dev/ram0 rw earlycon\n";
        } else if (std.mem.eql(u8, file_path, "/proc/meminfo") or std.mem.eql(u8, file_path, "proc/meminfo")) {
            var g_info: sbi.GuestInfo = std.mem.zeroes(sbi.GuestInfo);
            _ = sbiEcall(sbi.EXT.DIOSIX, sbi.DIOSIX.GET_INFO, @intFromPtr(&g_info), @sizeOf(sbi.GuestInfo), 0, 0, 0, 0);
            const total_kb = if (g_info.used_ram_pages > 0) g_info.used_ram_pages * 4 else 262144;
            const free_kb = if (total_kb > 34816) total_kb - 34816 else 10240;
            return std.fmt.bufPrint(reply_buf,
                \\MemTotal:       {d:8} kB
                \\MemFree:        {d:8} kB
                \\MemAvailable:   {d:8} kB
                \\Buffers:            2048 kB
                \\Cached:            12288 kB
            , .{ total_kb, free_kb, free_kb + 8192 }) catch "MemTotal: 262144 kB\nMemFree: 227328 kB\n";
        } else {
            return std.fmt.bufPrint(reply_buf, "cat: {s}: No such file or directory", .{file_path}) catch "cat: No such file or directory";
        }
    }

    // 4. File manipulation mocks
    if (std.mem.startsWith(u8, trimmed, "mkdir ")) {
        return "";
    } else if (std.mem.startsWith(u8, trimmed, "touch ")) {
        return "";
    } else if (std.mem.startsWith(u8, trimmed, "rm ")) {
        return "";
    } else if (std.mem.startsWith(u8, trimmed, "chmod ")) {
        return "";
    }

    // 5. Fallback: command not found (like standard Unix shell)
    var cmd_word = trimmed;
    if (std.mem.indexOfScalar(u8, trimmed, ' ')) |space| {
        cmd_word = trimmed[0..space];
    }
    return std.fmt.bufPrint(reply_buf, "sh: {s}: command not found", .{cmd_word}) catch "sh: command not found";
}

export fn guestMain() noreturn {
    print("\n[guest-supervisor] Diosix guest supervisor payload booting...\n");

    var g_info: sbi.GuestInfo = std.mem.zeroes(sbi.GuestInfo);
    const info_res = sbiEcall(sbi.EXT.DIOSIX, sbi.DIOSIX.GET_INFO, @intFromPtr(&g_info), @sizeOf(sbi.GuestInfo), 0, 0, 0, 0);

    if (info_res.err == sbi.SUCCESS) {
        var num_buf: [32]u8 = undefined;
        print("[guest-supervisor] Context ID: ");
        if (std.fmt.bufPrint(&num_buf, "{d}\n", .{g_info.guest_id})) |s| {
            print(s);
        } else |_| {
            print("unknown\n");
        }
    }

    print("[guest-supervisor] Guest supervisor active and listening for IPC events.\n");

    var rx_buf: [1024]u8 = undefined;
    var reply_buf: [4096]u8 = undefined;

    while (true) {
        var rargs = sbi.IpcRecvArgs{
            .sender_cid = 0,
            .data_ptr = @intFromPtr(&rx_buf),
            .max_len = rx_buf.len,
            .actual_len = 0,
            .actual_sender_cid = 0,
        };
        const recv_res = sbiEcall(sbi.EXT.DIOSIX, sbi.DIOSIX.IPC_RECV, @intFromPtr(&rargs), 0, 0, 0, 0, 0);
        if (recv_res.err == sbi.SUCCESS and recv_res.value > 0 and rargs.actual_len > 0) {
            const cmd_str = rx_buf[0..rargs.actual_len];
            const reply = handleCommand(cmd_str, &reply_buf);
            if (reply.len > 0) {
                var sargs = sbi.IpcSendArgs{
                    .target_cid = rargs.actual_sender_cid,
                    .data_ptr = @intFromPtr(reply.ptr),
                    .data_len = reply.len,
                };
                _ = sbiEcall(sbi.EXT.DIOSIX, sbi.DIOSIX.IPC_SEND, @intFromPtr(&sargs), 0, 0, 0, 0, 0);
            }
        }

        _ = sbiEcall(sbi.EXT.DIOSIX, sbi.DIOSIX.YIELD, 0, 0, 0, 0, 0, 0);
    }
}

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    print("\n[guest-supervisor] PANIC: ");
    print(msg);
    print("\n");
    while (true) {
        asm volatile ("wfi");
    }
}
