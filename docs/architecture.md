# Diosix Architecture

Diosix is a lightweight, secure-by-design hypervisor that uses a hierarchical management model for virtual machines (VMs). 

## 1. Hierarchical Forking Model

Unlike traditional hypervisors that use a flat structure for guest management, Diosix organizes VMs into a tree-like lineage. 

*   **The Root VM**: The first VM loaded by the hypervisor at boot. It acts as the progenitor (Unix `init` or PID 1 equivalent) for all other guests.
*   **Recursive Management**: Any VM can fork itself or manage its direct children (start, stop, kill, or reboot). A parent VM is responsible for the lifecycle and resources of its descendants.

## 2. Resource Quotas

Diosix uses a **Subtree Resource Quota** system to prevent Denial-of-Service (DoS) attacks and ensure fair resource distribution. A VM's quota defines the absolute maximum resources that it and its entire descendant tree can consume.

Currently, Diosix tracks and enforces the following quotas:
*   **Physical RAM**: Total physical pages allocated for page tables and guest memory.
*   **VCPU Cores**: Maximum number of virtual CPU cores in the subtree.
*   **Scheduling Priority**: The highest priority any VCPU in the subtree can have.
*   **Max Child Depth**: The maximum levels of nesting below this VM.
*   **Max Descendants**: The total number of VMs allowed in the subtree.

The Root VM starts with the maximum available system resources. Any VM can voluntarily decrease its own quota (a one-way operation) to sandbox itself and its future descendants.

## 3. Communication and Lineage Isolation

Isolation is a core tenant of the Diosix architecture:
*   **Direct Interaction**: VMs are strictly limited to communicating only with their immediate parent and immediate children.
*   **Lineage Isolation**: VMs that do not share a direct parent-child relationship are completely isolated and cannot interact or detect each other’s existence.

## 4. Hardware Trust (`is_trusted`)

Diosix distinguishes between managing children (available to all parents) and controlling hardware:
*   **`is_trusted` flag**: Only a VM with this flag can map physical MMIO space or route hardware interrupts to itself.
*   **Privilege De-escalation**: The Root VM is initialized as `is_trusted`. A VM can permanently relinquish this privilege using the `vm_drop_trust` hypercall. 

This enables a "Least Privilege" workflow where a trusted loader forks a child, populates it with a guest OS image, drops the child's trust, and then restarts the child as a standard isolated guest.

## 5. Termination and Restart Policy

*   **Cascading Termination**: If a VM terminates (via `vm_exit` or a fatal crash), the hypervisor recursively terminates all of its children and descendants. Orphans are not allowed.
*   **System Restart**: If the top-level **Root VM** terminates or crashes, the hypervisor considers the system state to be finalized and restarts the host machine.
