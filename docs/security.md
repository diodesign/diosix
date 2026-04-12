# Diosix Security Model

The [Diosix](https://diosix.org) architecture is designed to minimize the Trusted Computing Base (TCB) while providing flexible, hierarchical management for guest virtual machines.

## Trusted Computing Base (TCB)
The hypervisor and the progenitor **Root VM** (init-equivalent) form the core TCB. The hypervisor enforces memory separation and resource quotas, while the Root VM manages the host's initial hardware and orchestration.

## Hardware-Enforced Isolation
Diosix uses machine-level features to enforce guest sandboxing:
*   **G-stage Paging**: Virtualizes physical memory so guests cannot access the hypervisor or other guests' addresses.
*   **PMP (Physical Memory Protection)**: Used as a fallback on systems without H-extension to strictly bound guest access.
*   **Privilege Guarding**: Any physical MMIO mapping (e.g., for device drivers) or direct hardware interrupt routing requires the `is_trusted` flag, which is only granted to the Root VM and its specifically designated descendants.

## Lineage Isolation
Diosix enforces **Lineage Isolation** at the messaging layer. A guest VM can only communicate with its immediate parent or children. VMs that are not on the same branch of the tree are completely invisible to each other.

## Least Privilege Cycle
Parents can manage their children’s lifecycle (stop, start, kill, reboot) regardless of their `is_trusted` status. This allows for a security-hardened workflow:
1.  **Fork with Trust**: A trusted parent forks a child VM with the `is_trusted` flag.
2.  **Load guest image**: The trusted parent populates the child’s memory with a new OS image.
3.  **Drop Trust**: The parent (or the child via hypercall) triggers `vm_drop_trust`.
4.  **Restart**: The child is restarted as a standard isolated guest, and it can never regain trust or hardware access.

## Reporting security issues

The project takes security bugs seriously. To privately report a security vulnerability, email [security@diosix.org](mailto:security@diosix.org) with further details.