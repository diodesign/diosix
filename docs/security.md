# Diosix security model

The Diosix architecture prioritizes a minimal Trusted Computing Base (TCB)
and enforces guest isolation through hierarchical tree segmentation,
hardware-level memory protections, and network boundary controls.

## Trusted computing base

The hypervisor and its progenitor **Root VM** (Unix init-equivalent) form
the core of the TCB. The hypervisor enforces physical memory separation,
virtual CPU scheduling, and resource quotas. The Root VM manages host hardware
drivers, storage volumes, and initial guest orchestration.

## Hardware-enforced isolation

Diosix uses machine-level features of the RISC-V architecture to enforce
guest sandboxing:

*   **Second-stage (G-stage) translation**: When the RISC-V hypervisor (H)
    extension is present, G-stage page tables translate Guest Physical Addresses
    (GPAs) to Host Physical Addresses (HPAs). Guest VMs cannot access memory
    outside their assigned GPA ranges or read hypervisor memory.
*   **Physical Memory Protection (PMP)**: On target platforms lacking the
    H-extension, Diosix configures machine-mode PMP registers to strictly bound
    guest physical memory access to designated DRAM regions.
*   **Hardware trust restriction**: Any mapping of physical Memory-Mapped I/O
    (MMIO) addresses or routing of physical device interrupts requires the
    hardware trust privilege. Untrusted guest VMs cannot access host hardware
    peripherals.

## Tree-based segmentation and relative context IDs

Diosix models all guest VMs as nodes in a strictly hierarchical tree. Rather
than exposing global guest identifiers to guest software, the hypervisor
presents relative Context IDs (CIDs):

*   **`CID 0` (Parent)**: Refers to the calling VM's immediate parent.
*   **`CID 1` (Self)**: Refers to the calling VM itself.
*   **`CID 2..N` (Children)**: Refers to the calling VM's direct child guests.

Internally, the hypervisor assigns a unique system-wide guest ID for bookkeeping.
However, guest VMs remain completely unaware of this global identifier. A guest
VM cannot address or discover its siblings, ancestors, or unrelated branches
in the tree. Each guest VM is blind to the rest of the system unless its direct
parent explicitly grants a capability route through manifest attenuation.

## Asymmetric credential management

Administrative access between parent and child guest VMs follows a strict
two-tier unidirectional downward hierarchy:

*   **Operator ingress (Host -> Root VM)**: Operators authenticate to the Root VM
    using their own SSH keypair. During hypervisor installation, the operator's
    public key is provisioned into the Root VM's `/root/.ssh/authorized_keys`.
    The Root VM never possesses the operator's private key.
*   **Dynamic cluster management keys**: The Root VM generates an internal
    Dropbear cluster management keypair on first boot, storing it on the
    persistent storage volume (`/var/lib/diosix/keys/id_management`). This volume
    is mounted exclusively by privileged Domain 0 and is inaccessible to child
    guests. Management private keys are never committed to source control or
    baked into release binaries.
*   **Ephemeral and unique host keys**: SSH host keys are generated uniquely per
    machine instance upon boot or installation. Base images and rootfs templates
    contain no pre-baked private host keys, preventing cross-guest key reuse or
    spoofing.
*   **True child key exclusion**: Guest VM images contain only their parent's
    public key in `/root/.ssh/authorized_keys`. Management private keys are never
    written to child disk images or mapped into child address spaces, ensuring a
    compromised guest kernel cannot extract administrative credentials.
*   **Hierarchical delegation**: When a child VM spawns a grandchild VM, the
    child generates its own local management keypair on its own volume and
    passes only its public key downward. A guest cannot access credentials or
    control channels belonging to ancestors or siblings.
*   **Downward command flow**: Administrative control channels and remote shell
    sessions flow strictly downward from parent to child (`Parent -> Child`).
    Child VMs cannot open administrative SSH sessions to their parent VM.

## Network firewall and boundary containment

Network traffic traversing the virtual network device (`diosix0`) is filtered
by stateful iptables firewall rules configured on the Root VM router:

*   **Parent inbound denial**: The parent router installs packet-filter rules
    dropping all new connection attempts originating from child VMs
    (`-A INPUT -i diosix0 -m conntrack --ctstate NEW -j DROP` and
    `-A INPUT -s 10.0.0.0/16 -m conntrack --ctstate NEW -j DROP`). Child VMs
    cannot connect to parent listening services, including SSH on port 22.
*   **Cross-guest lateral denial**: The router denies forwarding between
    virtual child subnets (`-A FORWARD -s 10.0.0.0/16 -d 10.0.0.0/16 -j DROP`).
    Sibling guest VMs cannot probe, port scan, or communicate laterally with one
    another across the virtual network.
*   **Stateful return traffic**: Established and related responses to
    parent-initiated connections (`--ctstate ESTABLISHED,RELATED`) are
    permitted, allowing downward management commands to complete reliably.

## Declarative manifests and air-gapped domains

System security policies are declared in the system manifest (`system.toml`).
The Root VM parses the manifest and generates pruned, attenuated child manifests
upon domain startup:

*   **Capability attenuation**: A child VM's permissions are bounded by its
    declared `can_require` capabilities. A parent VM can only grant
    capabilities that the parent itself possesses.
*   **Air-gapped domain isolation**: Domains that omit external network
    capabilities (such as the `[domains.vault]` domain, which specifies only
    `gui.*` display capabilities and omits `net.wan`) receive no network
    routes or WAN gateway forwarding. Sensitive workloads remain air-gapped
    from external network interfaces.

## Least privilege lifecycle

Parent VMs control the lifecycle of their child VMs through Supervisor Binary
Interface (SBI) hypercalls:

1.  A trusted parent VM creates a child VM with constrained RAM and vCPU quotas.
2.  The child VM is instantiated from an isolated guest image loaded into guest
    memory without direct host hardware access.
3.  If hardware MMIO access is required (such as for a dedicated display or
    storage driver), trust can be granted at startup; otherwise, guests run
    strictly untrusted.
4.  A trusted guest VM can permanently surrender its hardware privileges by
    invoking the `DROP_TRUST` SBI function. This privilege revocation is
    irreversible for the lifetime of that guest.

## Reporting security issues <a name="reporting-security-issues"></a>

The project takes security bugs seriously. To privately and responsibly
report a security vulnerability, email 
[security@diosix.org](mailto:security@diosix.org) with technical details.
We investigate and respond to all reports promptly.