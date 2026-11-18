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

## Hierarchical package attenuation

Child VMs start with no direct internet forwarding and install Alpine Package
Keeper (`apk`) packages strictly from their immediate parent's HTTP proxy
(`http://diosix-parent:8080/v3.24/main`). At each tree edge, the parent
enforces monotonic allowlists (`# diosix-pkg-allow:`) and denylists
(`# diosix-pkg-deny:`) staged in the child's manifest:

* Only packages permitted by both the parent's own ceiling and the child's
  manifest—along with their transitive dependencies not on any denylist—are
  served (`200 OK`); disallowed requests receive `403 Forbidden`.
* Restricting a child at spawn with `dsx run --packages <list>` or updating it
  at runtime with `dsx pkg allow` / `dsx pkg deny` blocks the child from
  delegating broader package permissions to grandchildren.
* Only the top-level VM reaches upstream Alpine mirrors when WAN networking is
  available, while offline boots serve signed packages from the built-in local
  seed repository (`/var/lib/diosix/apk/`).

---

## Anti-collusion parent message boards

Machine mode blocks lateral child-to-child Ethernet frames, VirtIO-vsock
streams, and Whisper rings unless explicitly chained as a router. To coordinate
autonomous workloads without covert peer collusion, every parent VM hosts a
local message board on `diosix0:8485` managed via `dsx board`:

* Each incoming post authenticates the sender's CID from its kernel-bound
  media access control (MAC) address (`02:00:00:00:HI:LO`) on `diosix0`.
* The server rejects child posts targeting any non-zero sibling CID
  (`target_cid != 0`) with `403 Forbidden`; children can only post to the parent
  board (`target_cid = 0`), while the parent can address private directives
  downward to specific children (`dsx board post --to <cid>`).
* Each message appends to a SHA-256 hash-chained log
  (`/run/diosix/board.jsonl`), and children querying `/v1/messages` see only
  board-wide posts (`target_cid = 0`) and messages addressed directly to or
  authored by their own CID.

---

## Autonomous node agents and mission consensus

Diosix combines cryptographic principal authority with tree-scoped multi-agent
governance so neither a compromised owner key nor a single runaway VM can
subvert a fleet (for instance, turning a benign deployment into a ransomware
attack that drops database replicas from three to zero and encrypts storage):

* **Principal Ed25519 signatures and anti-rollback:** Owners sign
  `charter.toml` (`[principal]` and `[spec]`/`[invariants]`) with an
  Edwards-curve digital signature algorithm (Ed25519) key using
  `dsx charter keygen` and `dsx charter sign`. Machine mode (`SEAL_MISSION`)
  verifies the 64-byte signature over the canonical 92-byte mission header and
  rejects any rollback (`version <= active.version`). Key rotation binds a
  `previous_signature` signed by the retiring key.
* **Conserved RAM quota-stake consensus:** When an active sealed Mission
  receives an amendment, every running VM active before the proposal snapshot
  (`guest_id <= proposal_cutoff_guest_id`) votes via `VOTE_MISSION`. A VM's
  voting weight equals its retained physical RAM pages
  (`max_ram_pages -| delegated_ram_pages`). Because spawning child VMs transfers
  RAM quota instead of creating weight, physical stake sums to the total host
  RAM allocated across the tree, preventing Sybil vote amplification and
  post-proposal child stuffing (following John R. Douceur, *"The Sybil Attack"*,
  IPTPS 2002).
* **Tree-based dissemination and stake aggregation:** Proposals walk down parent
  `dsx board` instances while signed vote receipts bubble back up to parents
  and host peers—matching the hierarchical dissemination and aggregation pattern
  described in Ray Neiheiser, Miguel Matos, and Luís Rodrigues (*"Kauri:
  Scalable BFT Consensus with Pipelined Tree-Based Dissemination and
  Aggregation"*, ACM SOSP 2021) paired with Byzantine supermajority quorum
  (`>= stake_quorum_pct`, default `67%`, following Miguel Castro and Barbara
  Liskov, *"Practical Byzantine Fault Tolerance"*, OSDI 1999).
* **Defense-in-depth anti-ransomware veto:** Even if an attacker compromises
  the Principal private key and signs a hostile `v2` charter, both child U-mode
  agents (`dsx agent step`) and M-mode (`SEAL_MISSION`) independently enforce
  constitutional transition guards: dropping total replicas to zero under
  `forbid_zero_replicas`, exceeding `max_stepdown_pct`, or setting volume
  encryption or wipe flags under `forbid_unratified_encryption` is
  deterministically rejected.
* **External hypervisor containment (platform security boundary):** Diosix never
  relies on guest-internal `uid` checks or scripts to isolate workloads. Plain
  workload VMs—such as Ubuntu web servers with normal `root` accounts or copies
  of `dsx`—remain externally contained by Stage-2 memory permissions,
  `RUN_FLAG_LEAF_NO_CHILDREN` (`--leaf`), `RUN_FLAG_DELEGATE_STAKE` separation
  (M-mode denies `VOTE_MISSION` from non-stake children while preserving their
  RAM weight on the stake-holding parent), layer-2 source MAC and Address
  Resolution Protocol (ARP) `sha` stamping, 802.1Q virtual local area network
  (VLAN) tag rejection, and Stage-2 read-only aperture write guards.
* **Optional in-guest startup hygiene (`diosix-agent-start`):** The unified
  `diosix-node.elf` image provides an unprivileged `agent` (`uid=1000`) user and
  `/usr/sbin/diosix-agent-start` supporting `root`, `sudoer`
  (`/etc/doas.d/agent.conf`), and `non-sudoer` (`su` + `setpriv --nnp`) modes.
  Inside `non-sudoer` VMs, `/run/diosix/node-env` allows agent loops to discover
  parent networking while local privilege escalation stays blocked; security for
  the cluster still rests on M-mode quotas and parent boundaries outside the VM.
* **Generic thinking gateway and conserved budgets (`diosix0:8081`):** Children
  send prompt plus `minimal`, `low`, `medium`, or `high` thinking tiers to
  `POST http://diosix-parent:8081/v1/infer` (authenticated by kernel neighbor
  ARP MAC binding), keeping API secrets in `/var/lib/diosix/keys/llm.secret`
  on the root VM. Unconfigured children default to zero tokens and zero USD
  (`429 quota_exceeded`); `dsx agent grant` allocates explicit conserved token
  and micro-USD (`cost_micros_usd`) pools with two-phase reservation, thinking
  tier attenuation, and per-minute rate limits (`rpm`, `tpm`).

---

## Reporting security issues

To report a security vulnerability privately, email
[security@diosix.org](mailto:security@diosix.org) with technical details.
