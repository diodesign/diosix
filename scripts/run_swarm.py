#!/usr/bin/env python3
"""Diosix Multi-Host Autonomous Swarm QEMU Orchestrator & E2E Verifier.

Connects N QEMU riscv64 Diosix hosts over an in-process Ethernet socket hub
and verifies multi-host sharding, external leaf containment, conserved
thinking gateway budgets, non-sudoer autonomous execution, and anti-ransomware
mission vetoes.

Copyright (c) 2026 Chris Williams <chrisw@diosix.org>
SPDX-License-Identifier: MIT
"""

import argparse
import os
import sys
import time

sys.dont_write_bytecode = True

from lib.swarm_harness import (  # noqa: E402
    DEFAULT_STORAGE,
    DEFAULT_VDIOSIX,
    FrameSwitch,
    login_host,
    prepare_host_disk,
    run_cmd,
    spawn_host,
    write_charter,
)


def verify_phase3_isolation_and_gateway(h1, p1):
    """Verify leaf containment, stake isolation, grants, and autonomous loop."""
    run_cmd(
        h1,
        p1,
        "STAKE_BEFORE=$(dsx charter status --json | "
        "sed -n 's/.*\"eligible_stake_pages\":\\([0-9]*\\).*/\\1/p')",
        timeout=20,
    )
    run_cmd(
        h1,
        p1,
        "dsx run diosix-node.elf --name web-leaf --ram 256M --leaf",
        r"started in background",
        timeout=45,
    )
    run_cmd(
        h1,
        p1,
        "for i in $(seq 1 20); do "
        "dsx ssh web-leaf -- dsx info >/dev/null 2>&1 && "
        "echo SSH_OK && break; sleep 2; done",
        r"SSH_OK",
        timeout=60,
    )
    run_cmd(
        h1,
        p1,
        "dsx ssh web-leaf -- dsx run diosix-node.elf --name rogue "
        "--ram 64M 2>&1 || true",
        r"Error:",
        timeout=30,
    )
    run_cmd(
        h1,
        p1,
        "dsx ssh web-leaf -- dsx charter vote --approve 2>&1 || true",
        r"Error:",
        timeout=30,
    )
    run_cmd(
        h1,
        p1,
        "STAKE_AFTER=$(dsx charter status --json | "
        "sed -n 's/.*\"eligible_stake_pages\":\\([0-9]*\\).*/\\1/p'); "
        '[ "$STAKE_BEFORE" = "$STAKE_AFTER" ] && echo STAKE_CONSERVED',
        r"STAKE_CONSERVED",
        timeout=20,
    )
    run_cmd(
        h1,
        p1,
        'dsx ssh web-leaf -- dsx agent ask "hello" 2>&1 || true',
        r"Error:",
        timeout=30,
    )
    print("\n[6/11] Leaf workload VM contained (no spawn/vote/tokens).")

    run_cmd(
        h1,
        p1,
        "dsx agent grant web-leaf --tokens 4096 --budget-usd 0.05 "
        "--max-thinking low --json",
        r'"max_tokens":4096',
        r'"max_cost_micros":50000',
    )
    run_cmd(
        h1,
        p1,
        'dsx ssh web-leaf -- dsx agent ask "status report" '
        "--thinking low --json",
        r'"provider":"parent"',
        r'"thinking":"low"',
        r'"cost_micros_usd":[1-9]',
        timeout=30,
    )
    run_cmd(
        h1,
        p1,
        "dsx agent quota web-leaf --json",
        r'"used_tokens":[1-9]',
        r'"used_cost_micros":[1-9]',
    )
    run_cmd(
        h1,
        p1,
        'dsx ssh web-leaf -- dsx agent ask "escalate" --thinking high '
        "2>&1 || true",
        r"Error:",
        timeout=30,
    )
    run_cmd(h1, p1, "dsx stop web-leaf", r"terminated", timeout=30)
    print("\n[7/11] Conserved token/USD grant and tier attenuation verified.")

    run_cmd(
        h1,
        p1,
        "dsx ssh db-1 -- /usr/sbin/diosix-agent-start "
        "--mode non-sudoer --interval 2",
        timeout=30,
    )
    run_cmd(
        h1,
        p1,
        "dsx ssh db-1 -- /usr/sbin/diosix-agent-start --status",
        r"running",
        r"uid=1000",
        r"mode=non-sudoer",
        timeout=30,
    )
    run_cmd(
        h1,
        p1,
        'dsx board post "Create health artifact" --topic task --to db-1',
        r"Posted",
        timeout=30,
    )
    run_cmd(
        h1,
        p1,
        "for i in $(seq 1 15); do "
        "dsx ssh db-1 -- cat /var/lib/diosix/agent/task-output.txt "
        "2>/dev/null && break; sleep 2; done",
        r"AUTONOMOUS_OK",
        timeout=45,
    )
    run_cmd(
        h1,
        p1,
        "dsx board list --topic task_status --json",
        r"task_receipt",
        r"completed",
        timeout=30,
    )
    run_cmd(
        h1,
        p1,
        "dsx ssh db-1 -- /usr/sbin/diosix-agent-start --stop",
        timeout=30,
    )
    print("\n[8/11] Non-sudoer uid=1000 agent executed autonomous board task.")


def run_self_test(kernel, storage_img):
    print("===============================================================")
    print("  Diosix Multi-Host Swarm, Gateway & Containment E2E Check     ")
    print("===============================================================")
    sw = FrameSwitch()
    disks = []
    hosts = []
    try:
        for i in range(2):
            fmt, dpath = prepare_host_disk(i, storage_img)
            disks.append(dpath)
            h = spawn_host(i, 2, sw.port, kernel, fmt, dpath)
            hosts.append(h)

        h1, h2 = hosts[0], hosts[1]
        h1.logfile_read = sys.stdout
        p1 = login_host(h1, "host1")
        p2 = login_host(h2, "host2")
        print("\n[1/11] Both QEMU Diosix hosts booted on shared socket LAN.")

        run_cmd(h2, p2, "dsx swarm serve --daemon || true")
        run_cmd(
            h1,
            p1,
            "dsx swarm join 10.0.2.12 --json",
            r'"status":"joined"',
            r'"peer_endpoint":"10\.0\.2\.12:8486"',
        )
        print("\n[2/11] Multi-host Ed25519 peer mesh verified.")

        run_cmd(h1, p1, "dsx charter keygen --priv /tmp/p.key --pub /tmp/p.pub")
        write_charter(h1, p1, "/tmp/v1.toml", 1, 2, 2, "false")
        run_cmd(
            h1,
            p1,
            "dsx charter sign --file /tmp/v1.toml --key /tmp/p.key --json",
            r'"status":"signed"',
        )
        run_cmd(
            h1,
            p1,
            "dsx charter deploy --file /tmp/v1.toml --json",
            r'"status":"sealed"',
            r'"mode":"mission"',
        )
        run_cmd(
            h2,
            p2,
            "dsx swarm join 10.0.2.11 --json",
            r'"adopted_charter":true',
        )
        run_cmd(h2, p2, "dsx charter status --json", r'"mission_sealed":true')
        print("\n[3/11] Principal-signed v1 sealed & adopted across fleet.")

        run_cmd(
            h1,
            p1,
            "dsx agent step --json",
            r'"replicas_spawned":1',
            timeout=45,
        )
        run_cmd(
            h2,
            p2,
            "dsx agent step --json",
            r'"replicas_spawned":1',
            timeout=45,
        )
        print("\n[4/11] Autonomous agents sharded replicas across 2 hosts.")

        run_cmd(
            h1,
            p1,
            "for i in $(seq 1 20); do "
            "dsx ssh db-1 -- dsx info >/dev/null 2>&1 && "
            "echo SSH_OK && break; sleep 2; done",
            r"SSH_OK",
            timeout=60,
        )
        run_cmd(
            h1,
            p1,
            'dsx ssh db-1 -- dsx agent ask "health check" --json',
            r'"provider":"parent"',
            r"approve",
            timeout=30,
        )
        print("\n[5/11] WAN-isolated child queried parent gateway (:8081).")

        verify_phase3_isolation_and_gateway(h1, p1)

        write_charter(h1, p1, "/tmp/ransom.toml", 2, 0, 0, "true")
        run_cmd(
            h1,
            p1,
            "dsx charter sign --file /tmp/ransom.toml --key /tmp/p.key",
            r"Signed Charter",
        )
        run_cmd(
            h1,
            p1,
            "dsx swarm propose --file /tmp/ransom.toml --json",
            r'"local_allowed":false',
        )
        run_cmd(
            h1,
            p1,
            "dsx ssh db-1 -- dsx agent step --json",
            r'"votes_rejected":1',
            timeout=30,
        )
        run_cmd(
            h1,
            p1,
            "dsx charter deploy --file /tmp/ransom.toml 2>&1 || true",
            r"Error:",
        )
        run_cmd(h1, p1, "dsx charter status --json", r'"mission_version":1')
        print("\n[9/11] Compromised-Principal ransomware vetoed cleanly.")

        write_charter(h1, p1, "/tmp/v2.toml", 2, 2, 4, "false")
        run_cmd(
            h1,
            p1,
            "dsx charter sign --file /tmp/v2.toml --key /tmp/p.key",
            r"Signed Charter",
        )
        run_cmd(
            h1,
            p1,
            "dsx swarm propose --file /tmp/v2.toml --json",
            r'"local_allowed":true',
        )
        run_cmd(
            h1,
            p1,
            "dsx ssh db-1 -- dsx agent step --json",
            r'"votes_approved":1',
            timeout=30,
        )
        run_cmd(
            h1,
            p1,
            "dsx agent step --json",
            r'"sealed_version":2',
            r'"replicas_spawned":1',
            timeout=45,
        )
        run_cmd(h1, p1, "dsx charter status --json", r'"mission_version":2')
        print("\n[10/11] Signed scale-up v2 ratified by stake quorum & sealed.")

        h1.sendline("dsx host poweroff")
        h2.sendline("dsx host poweroff")
        time.sleep(1)
        print("\n[11/11] ALL MULTI-HOST SWARM & PHASE 3 CHECKS PASSED.")
        return 0
    finally:
        for h in hosts:
            try:
                if h.isalive():
                    h.terminate(force=True)
            except Exception:
                pass
        sw.close()
        for d in disks:
            if os.path.exists(d):
                os.unlink(d)


def main():
    parser = argparse.ArgumentParser(description="Diosix QEMU swarm runner")
    parser.add_argument("--hosts", type=int, default=2, help="Host count")
    parser.add_argument("--kernel", default=DEFAULT_VDIOSIX)
    parser.add_argument("--storage", default=DEFAULT_STORAGE)
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="Run automated multi-host E2E verification",
    )
    args = parser.parse_args()

    if args.self_test:
        sys.exit(run_self_test(args.kernel, args.storage))

    sw = FrameSwitch()
    disks = []
    hosts = []
    try:
        for i in range(args.hosts):
            fmt, dpath = prepare_host_disk(i, args.storage)
            disks.append(dpath)
            h = spawn_host(i, args.hosts, sw.port, args.kernel, fmt, dpath)
            hosts.append(h)
        print(
            f"Started {args.hosts} swarm hosts on switch port {sw.port}. "
            "Attaching to Host 1 serial (Ctrl-C exits cluster)..."
        )
        hosts[0].logfile_read = None
        hosts[0].interact()
    except KeyboardInterrupt:
        pass
    finally:
        for h in hosts:
            try:
                h.terminate(force=True)
            except Exception:
                pass
        sw.close()
        for d in disks:
            if os.path.exists(d):
                os.unlink(d)


if __name__ == "__main__":
    main()
