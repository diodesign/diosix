// Diosix Guest Control API wrapper re-exporting shared libdiosix.
//
// Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
// SPDX-License-Identifier: MIT

const std = @import("std");
const lib = @import("libdiosix");

pub const DEFAULT_DEVICE_PATH = lib.DEFAULT_DEVICE_PATH;
pub const EXT_DIOSIX = lib.EXT_DIOSIX;
pub const CID_PARENT = lib.CID_PARENT;
pub const CID_SELF = lib.CID_SELF;
pub const CID_FIRST_CHILD = lib.CID_FIRST_CHILD;
pub const MAX_CHILD_PCPU_QUOTA_PCT = lib.MAX_CHILD_PCPU_QUOTA_PCT;
pub const DEFAULT_RETAINED_PCPU_PCT = lib.DEFAULT_RETAINED_PCPU_PCT;
pub const DEFAULT_CHILD_PCPU_QUOTA_PCT = lib.DEFAULT_CHILD_PCPU_QUOTA_PCT;
pub const MAX_GUEST_VCPUS = lib.MAX_GUEST_VCPUS;
pub const QUOTA_ZERO_SENTINEL = lib.QUOTA_ZERO_SENTINEL;

pub const TargetArch = lib.TargetArch;
pub const DIOSIX_FUNC = lib.DIOSIX_FUNC;
pub const BUILD_COMMIT_LEN = lib.BUILD_COMMIT_LEN;
pub const HOST_CPU_ISA_LEN = lib.HOST_CPU_ISA_LEN;
pub const BUILD_DESC_LEN = lib.BUILD_DESC_LEN;
pub const HypervisorFeature = lib.HypervisorFeature;
pub const HypervisorInfo = lib.HypervisorInfo;
pub const EventType = lib.EventType;
pub const Event = lib.Event;
pub const DiosixEvent = lib.DiosixEvent;
pub const WAIT_EVENT_FLAG_NOHANG = lib.WAIT_EVENT_FLAG_NOHANG;
pub const WaitEventArgs = lib.WaitEventArgs;
pub const SbiResult = lib.SbiResult;
pub const GuestInfo = lib.GuestInfo;
pub const RunFlags = lib.RunFlags;
pub const SpawnFlags = lib.SpawnFlags;
pub const RunArgs = lib.RunArgs;
pub const TerminateArgs = lib.TerminateArgs;
pub const QuotaArgs = lib.QuotaArgs;
pub const ManifestArgs = lib.ManifestArgs;
pub const ConsoleArgs = lib.ConsoleArgs;
pub const MAX_CONSOLE_IO_BYTES = lib.MAX_CONSOLE_IO_BYTES;
pub const MapChildMemArgs = lib.MapChildMemArgs;
pub const UnmapChildMemArgs = lib.UnmapChildMemArgs;
pub const StartArgs = lib.StartArgs;
pub const CharterArgs = lib.CharterArgs;
pub const MISSION_PUBKEY_LEN = lib.MISSION_PUBKEY_LEN;
pub const MISSION_SIG_LEN = lib.MISSION_SIG_LEN;
pub const MISSION_SIGN_DOMAIN = lib.MISSION_SIGN_DOMAIN;
pub const MISSION_SIGN_MSG_LEN = lib.MISSION_SIGN_MSG_LEN;
pub const MissionFlags = lib.MissionFlags;
pub const MissionArgs = lib.MissionArgs;
pub const MissionVoteDecision = lib.MissionVoteDecision;
pub const MissionVoteArgs = lib.MissionVoteArgs;
pub const buildMissionSignMessage = lib.buildMissionSignMessage;
pub const NetPolicyFlags = lib.NetPolicyFlags;
pub const NetPolicyArgs = lib.NetPolicyArgs;
pub const MAX_CHILD_MMIO_SIZE_BYTES = lib.MAX_CHILD_MMIO_SIZE_BYTES;
pub const MmioPassFlags = lib.MmioPassFlags;
pub const MapChildMmioArgs = lib.MapChildMmioArgs;
pub const IrqPassFlags = lib.IrqPassFlags;
pub const DelegateChildIrqArgs = lib.DelegateChildIrqArgs;
pub const ChildRamRange = lib.ChildRamRange;

pub const IOCTL_BASE = lib.IOCTL_BASE;
pub const IOCTL_DROP_TRUST = lib.IOCTL_DROP_TRUST;
pub const IOCTL_RUN = lib.IOCTL_RUN;
pub const IOCTL_SPAWN = lib.IOCTL_SPAWN;
pub const IOCTL_GET_INFO = lib.IOCTL_GET_INFO;
pub const IOCTL_SET_QUOTA = lib.IOCTL_SET_QUOTA;
pub const IOCTL_TERMINATE = lib.IOCTL_TERMINATE;
pub const IOCTL_EXIT = lib.IOCTL_EXIT;
pub const IOCTL_KILL = lib.IOCTL_KILL;
pub const IOCTL_YIELD = lib.IOCTL_YIELD;
pub const IOCTL_WAIT_EVENT = lib.IOCTL_WAIT_EVENT;
pub const IOCTL_GET_HV_INFO = lib.IOCTL_GET_HV_INFO;
pub const IOCTL_GET_MANIFEST = lib.IOCTL_GET_MANIFEST;
pub const IOCTL_SET_MANIFEST = lib.IOCTL_SET_MANIFEST;
pub const IOCTL_MAP_CHILD_MEM = lib.IOCTL_MAP_CHILD_MEM;
pub const IOCTL_UNMAP_CHILD_MEM = lib.IOCTL_UNMAP_CHILD_MEM;
pub const IOCTL_START = lib.IOCTL_START;
pub const IOCTL_SEAL_CHARTER = lib.IOCTL_SEAL_CHARTER;
pub const IOCTL_GET_CHARTER = lib.IOCTL_GET_CHARTER;
pub const IOCTL_RATIFY_CHARTER = lib.IOCTL_RATIFY_CHARTER;
pub const IOCTL_RESET_STEWARD = lib.IOCTL_RESET_STEWARD;
pub const IOCTL_REQUEST_ROOT_FAILOVER = lib.IOCTL_REQUEST_ROOT_FAILOVER;
pub const IOCTL_CONSOLE_WRITE = lib.IOCTL_CONSOLE_WRITE;
pub const IOCTL_CONSOLE_READ = lib.IOCTL_CONSOLE_READ;
pub const IOCTL_SET_NET_POLICY = lib.IOCTL_SET_NET_POLICY;
pub const IOCTL_WHISPER_SEND = lib.IOCTL_WHISPER_SEND;
pub const IOCTL_WHISPER_RECV = lib.IOCTL_WHISPER_RECV;
pub const IOCTL_SEAL_MISSION = lib.IOCTL_SEAL_MISSION;
pub const IOCTL_GET_MISSION = lib.IOCTL_GET_MISSION;
pub const IOCTL_VOTE_MISSION = lib.IOCTL_VOTE_MISSION;
pub const IOCTL_MAP_CHILD_MMIO = lib.IOCTL_MAP_CHILD_MMIO;
pub const IOCTL_DELEGATE_CHILD_IRQ = lib.IOCTL_DELEGATE_CHILD_IRQ;

pub const checkIoctlRc = lib.checkIoctlRc;
pub const DiosixClient = lib.DiosixClient;

test "api: re-exports libdiosix client and ABI" {
    std.testing.refAllDecls(@This());
    try std.testing.expectEqual(@as(u32, 0x101e), IOCTL_SEAL_MISSION);
}
