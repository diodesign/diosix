# Security, networking, and governance

Diosix sets conservative security defaults out of the box. Child virtual
machines (VMs) start isolated from the internet and from each other,
administrative SSH uses public-key authentication without placing private keys
inside guests, and critical workloads can be protected by a sealed charter in
machine mode (M-mode).

This guide explains why these mechanisms work this way and how to configure
them with `dsx`.

---

## Hierarchical VM tree and relative context IDs

### Why Diosix hides global VM IDs
In many hypervisors, every guest has a global ID or name on a shared management
bus. Diosix instead organizes VMs into a parent-child tree where each VM refers
only to its immediate neighbors using relative context IDs (CIDs):

* `1` (`self`) refers to the calling VM itself.
* `0` (`parent`) refers to the calling VM's immediate parent.
* `2..N` (or friendly VM names) refer to direct children created by the caller.

Because M-mode resolves CIDs relative to the caller, a child VM cannot list,
address, or probe siblings, cousins, or ancestors above its parent. Management
operations flow strictly downward from parent to child, so querying or altering
a parent VM's state returns a permission error.

---

## Network security and service-VM routing

### Why child VMs start on a local-only network
Each child VM receives a private IP address and defaults to local-only
networking:

* The parent VM can reach its direct children over SSH for management.
* The M-mode layer-2 (L2) switch stamps each child VM's assigned media access
  control (MAC) address onto outgoing Ethernet frames and drops frames
  addressed to sibling VMs unless a router link is configured.
* The parent VM's layer-3 (L3) firewall blocks wide area network (WAN)
  forwarding from child VMs until you explicitly grant internet or router
  access.

### Choosing a network mode

| Mode | Flag or command | Traffic allowed | Typical use |
| :--- | :--- | :--- | :--- |
| Air-gapped | `--net none` or `dsx net isolate <vm>` | No network frames (blocked in M-mode). | Key vaults, offline signing, or quarantined VMs. |
| Host-only (default) | `--net local` or `dsx net revoke <vm>` | Parent-child link only; no WAN forwarding. | Application sandboxes and internal services. |
| Internet | `--net wan` or `dsx net grant <vm> wan` | Outbound WAN network address translation (NAT) via parent. | Package installs or web clients. |
| Router or firewall | `--net router` or `dsx net grant <vm> router` | L3 IP forwarding and NAT for downstream VMs. | Dedicated firewall, packet-filtering, or logging VMs. |

### Granting or revoking internet access

```bash
# Start a VM with outbound internet (WAN) access enabled
dsx run linux-guest --name builder --net wan

# Or grant and revoke WAN access on a running VM
dsx net grant work wan
dsx net status
dsx net revoke work

# Cut off all network access for a VM in M-mode
dsx net isolate work
```

### Routing traffic through a firewall or logging VM

Instead of routing workload VMs straight through their parent VM to the
internet, you can chain their traffic through a dedicated sibling router VM
running your own firewall rules, packet capture tools, or VPN tunnel:

1. Start a sibling VM with the router role:

   ```bash
   dsx run linux-guest --name net-fw --net router
   ```

2. Launch a workload VM chained through `net-fw` (or re-route an existing VM):

   ```bash
   dsx run linux-guest --name app-vm --net-via net-fw
   dsx net route work --via net-fw
   ```

3. Confirm the active gateway chain:

   ```bash
   dsx net status
   ```

When `app-vm` is routed through `net-fw`, M-mode permits L2 frames between the
two VMs while preventing `app-vm` from bypassing `net-fw` to reach the parent
VM's WAN interface or other sibling VMs.

---

## SSH passkeys and downward management

### Why Diosix disables SSH passwords and keeps private keys out of guests

* Dropbear SSH disables password and root-password logins across all VMs,
  authenticating remote operators strictly against enrolled public keys while
  keeping the local hardware or emulator serial console available for direct
  host recovery.
* On first boot, a parent VM generates a local Ed25519 management keypair
  protected with owner-only file permissions. When creating or seeding a child
  VM, only the public key is staged into the child's authorized-keys file, so a
  compromised guest cannot SSH into sibling VMs or upward into its parent.
* Launching a VM as a steward or confidential guest skips parent SSH key
  injection altogether so the parent VM does not stage root SSH access inside
  the guest.

### Enrolling and verifying keys

```bash
# View authentication status, boot mode, and detected hardware tokens
dsx auth status

# Enroll an SSH Ed25519 or ECDSA public key from a file
dsx auth enroll --file /root/operator.pub --label laptop-key

# Generate a local Ed25519 key seeded by TPM 2.0 RNG or a FIDO2 token check
dsx auth enroll --tpm --label tablet-key
dsx auth enroll --fido2 --label usb-key

# List enrolled keys and their SHA-256 hashes
dsx auth list

# Revoke a key by index, fingerprint prefix, or label
dsx auth revoke laptop-key
```

You can also issue and verify a single-use 256-bit Ed25519 challenge nonce (or
print a QR pairing URI with `dsx auth enroll --qr`):

```bash
# Generate a single-use 256-bit challenge nonce
dsx auth challenge

# Verify a 64-byte raw Ed25519 signature over that challenge
dsx auth verify <128-char-signature-hex>
```

---

## Declarative manifests and charter governance

### Defining multi-domain topologies
You can declare VM images, quotas, and allowed service routes in a manifest
file. Before starting a domain from a manifest, Diosix prunes the file so each
child VM receives only the service routes it is permitted to use:

```bash
# Check manifest syntax and capability rules
dsx manifest validate /etc/diosix/system.toml

# Prune a child manifest for a specific domain
dsx manifest prune /etc/diosix/system.toml --domain sys -o /tmp/sys.toml
```

### Sealing a charter and running steward VMs
To enforce M-mode governance rules on running VMs, launch your steward VMs with
`--steward` and an optional standby root VM with `--standby-root`, then seal
the charter into M-mode:

* M-mode blocks parent console, graphical scanout, and virtual input access to
  steward VMs, and once a charter hash is sealed, also blocks foreign memory
  mapping and denies termination, resets, or quota reductions unless a quorum
  of steward VMs ratifies the action.
* M-mode blocks parent console, graphical scanout, and virtual input access to
  confidential VMs, and blocks foreign memory mapping once a charter is sealed.
* If the active root VM crashes or a quorum of stewards ratifies failover,
  M-mode promotes a warm standby root VM and reparents surviving child VMs
  without rebooting the host.

```bash
# View charter status, quorum thresholds, and M-mode seal state
dsx charter status

# Seal /etc/diosix/charter.toml's SHA-256 digest and quorum into M-mode
dsx charter deploy

# Confirm that the on-disk charter matches the sealed M-mode SHA-256 hash
dsx charter audit
```

---

## Reporting security issues

To report a security vulnerability privately, email
[security@diosix.org](mailto:security@diosix.org) with technical details.
