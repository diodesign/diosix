(() => {
  const REPO = "https://github.com/diodesign/diosix";

  /* 01. Relative CID perspective explorer in SVG */
  const PERSPECTIVES = {
    root: {
      cids: {
        root: "CID 1 · self",
        steward: "CID 2 · child",
        desktop: "CID 3 · child",
        "worker-a": "opaque · grandchild",
        "worker-b": "opaque · grandchild",
      },
      roles: {
        root: "is-self",
        steward: "is-child",
        desktop: "is-child",
        "worker-a": "is-opaque",
        "worker-b": "is-opaque",
      },
      edges: ["e-root-steward", "e-root-desktop"],
      text: "Root VM sees self (CID 1) and direct children Steward (CID 2) & Desktop (CID 3). Grandchildren stay opaque.",
    },
    steward: {
      cids: {
        root: "CID 0 · parent",
        steward: "CID 1 · self",
        desktop: "hidden · sibling",
        "worker-a": "CID 2 · child",
        "worker-b": "CID 3 · child",
      },
      roles: {
        root: "is-parent",
        steward: "is-self",
        desktop: "is-opaque",
        "worker-a": "is-child",
        "worker-b": "is-child",
      },
      edges: ["e-root-steward", "e-steward-wa", "e-steward-wb"],
      text: "Steward sees Parent (CID 0), self (CID 1), and Workers (CID 2..3) on its private switch. Sibling Desktop is invisible.",
    },
    desktop: {
      cids: {
        root: "CID 0 · parent",
        steward: "hidden · sibling",
        desktop: "CID 1 · self",
        "worker-a": "hidden · cousin",
        "worker-b": "hidden · cousin",
      },
      roles: {
        root: "is-parent",
        steward: "is-opaque",
        desktop: "is-self",
        "worker-a": "is-opaque",
        "worker-b": "is-opaque",
      },
      edges: ["e-root-desktop"],
      text: "Desktop sees only Parent (CID 0) and self (CID 1). Steward and Workers cannot be probed or messaged.",
    },
    "worker-a": {
      cids: {
        root: "hidden · ancestor",
        steward: "CID 0 · parent",
        desktop: "hidden · aunt",
        "worker-a": "CID 1 · self",
        "worker-b": "hidden · sibling",
      },
      roles: {
        root: "is-opaque",
        steward: "is-parent",
        desktop: "is-opaque",
        "worker-a": "is-self",
        "worker-b": "is-opaque",
      },
      edges: ["e-steward-wa"],
      text: "Worker A treats Steward identically as CID 0. Lateral frames to Worker B and upward probes to Root are blocked by M-mode.",
    },
    "worker-b": {
      cids: {
        root: "hidden · ancestor",
        steward: "CID 0 · parent",
        desktop: "hidden · aunt",
        "worker-a": "hidden · sibling",
        "worker-b": "CID 1 · self",
      },
      roles: {
        root: "is-opaque",
        steward: "is-parent",
        desktop: "is-opaque",
        "worker-a": "is-opaque",
        "worker-b": "is-self",
      },
      edges: ["e-steward-wb"],
      text: "Worker B coordinates solely through Steward (CID 0) boards (`dsx board`) and inherits attenuated RAM, CPU, and package quotas.",
    },
  };

  const nodes = document.querySelectorAll(".tree-node[data-node]");
  const edges = document.querySelectorAll(".tree-edge[id]");
  const readout = document.getElementById("cid-readout");

  function selectNode(id) {
    const view = PERSPECTIVES[id];
    if (!view) return;
    nodes.forEach((el) => {
      const nid = el.dataset.node;
      el.classList.remove("is-self", "is-parent", "is-child", "is-opaque");
      el.classList.add(view.roles[nid]);
      el.setAttribute("aria-pressed", String(nid === id));
      const label = el.querySelector(".node-cid");
      if (label) label.textContent = view.cids[nid];
    });
    edges.forEach((edge) => {
      const active = view.edges.includes(edge.id);
      edge.classList.toggle("is-active", active);
      edge.classList.toggle("is-dim", !active);
    });
    if (readout) readout.textContent = view.text;
  }

  nodes.forEach((node) => {
    node.addEventListener("click", () => selectNode(node.dataset.node));
    node.addEventListener("keydown", (ev) => {
      if (ev.key === "Enter" || ev.key === " ") {
        ev.preventDefault();
        selectNode(node.dataset.node);
      }
    });
  });

  /* 02. Edition x Boot Mode command composer */
  const COMMANDS = {
    core: {
      emulated: {
        cmd: "./scripts/build.sh -Dedition=core run",
        note: "Boots headless Diosix Core in QEMU with developer SSH keys on localhost:2222.",
      },
      live: {
        cmd: "tar -xf diosix-26.1-core-riscv64.tar.xz && ./diosix-26.1-core-riscv64/run-diosix.sh",
        note: "Or flash diosix-live-riscv64.img to removable media and run `dsx host install --edition core`.",
      },
      installed: {
        cmd: "dsx host install --disk /dev/nvme0n1 --edition core --hostname core-01",
        note: "Writes GPT partitions (BOOT A/B, STATE, DATA) and persists `core` in /var/lib/diosix/state/edition.",
      },
      diskless: {
        cmd: "python3 -B scripts/hil/runner.py --self-test",
        note: "Stages verified Core payloads over HTTP into tmpfs without touching local storage.",
      },
    },
    personal: {
      emulated: {
        cmd: "./scripts/build.sh run-personal",
        note: "Boots Diosix Personal in QEMU with passthrough profile tools ready over SSH (`dsx personal`).",
      },
      live: {
        cmd: "tar -xf diosix-26.1-personal-riscv64.tar.xz && ./diosix-26.1-personal-riscv64/run-diosix.sh",
        note: "Inspect host hardware live in RAM, then install your desktop profile onto disk.",
      },
      installed: {
        cmd: "dsx host install --disk /dev/nvme0n1 --edition personal --personal-image desktop.img --dma-trusted --auto-start",
        note: "Persists `personal` edition and `/var/lib/diosix/etc/personal.toml` across reboots.",
      },
      diskless: {
        cmd: "python3 -B scripts/test_personal_passthrough.py",
        note: "Verifies QEMU PCIe BAR/MMIO passthrough, contiguous DMA identity RAM, and PLIC IRQ forwarding.",
      },
    },
    swarm: {
      emulated: {
        cmd: "./scripts/build.sh run-swarm",
        note: "Launches two networked QEMU Swarm hosts running boards, thinking gateway, and peering.",
      },
      live: {
        cmd: "tar -xf diosix-26.1-swarm-riscv64.tar.xz && ./diosix-26.1-swarm-riscv64/run-diosix.sh",
        note: "Boots the default Swarm live bundle; flash diosix-live-riscv64.img onto hardware nodes via `dd`.",
      },
      installed: {
        cmd: "dsx host install --disk /dev/nvme0n1 --edition swarm --stewards --standby-root",
        note: "Provisions persistent Swarm storage with charter governance and warm standby root tracking.",
      },
      diskless: {
        cmd: "python3 -B scripts/run_swarm.py --hosts 2 --self-test",
        note: "Boots stateless multi-host Swarm nodes over RAM boot with zero persistent disk writes.",
      },
    },
  };

  let curEd = "swarm";
  let curMode = "emulated";
  const edBtns = document.querySelectorAll("[data-select-ed]");
  const modeBtns = document.querySelectorAll("[data-select-mode]");
  const cmdOut = document.getElementById("composer-cmd");
  const noteOut = document.getElementById("composer-note");
  const copyBtn = document.getElementById("composer-copy");

  function renderComposer() {
    const entry = COMMANDS[curEd][curMode];
    if (cmdOut) cmdOut.textContent = entry.cmd;
    if (noteOut) noteOut.textContent = entry.note;
    edBtns.forEach((b) =>
      b.setAttribute("aria-pressed", String(b.dataset.selectEd === curEd)),
    );
    modeBtns.forEach((b) =>
      b.setAttribute("aria-pressed", String(b.dataset.selectMode === curMode)),
    );
  }

  edBtns.forEach((btn) =>
    btn.addEventListener("click", () => {
      curEd = btn.dataset.selectEd;
      renderComposer();
    }),
  );

  modeBtns.forEach((btn) =>
    btn.addEventListener("click", () => {
      curMode = btn.dataset.selectMode;
      renderComposer();
    }),
  );

  if (copyBtn) {
    copyBtn.addEventListener("click", async () => {
      const text = cmdOut ? cmdOut.textContent : "";
      if (!text) return;
      try {
        await navigator.clipboard.writeText(text);
        copyBtn.textContent = "Copied";
      } catch {
        copyBtn.textContent = "Select to copy";
      }
      setTimeout(() => {
        copyBtn.textContent = "Copy";
      }, 1500);
    });
  }

  /* 03. stable / devel branch switcher for GitHub docs links */
  const branchBtns = document.querySelectorAll("[data-doc-branch]");
  const docLinks = document.querySelectorAll("a[data-doc-path]");

  function setDocBranch(branch) {
    branchBtns.forEach((b) =>
      b.setAttribute("aria-pressed", String(b.dataset.docBranch === branch)),
    );
    docLinks.forEach((a) => {
      const rel = a.dataset.docPath;
      a.href = `${REPO}/blob/${branch}/${rel}`;
    });
  }

  branchBtns.forEach((btn) =>
    btn.addEventListener("click", () => setDocBranch(btn.dataset.docBranch)),
  );

  /* 04. Scroll-stage indicator via IntersectionObserver (0% CPU when idle) */
  const stageReadout = document.getElementById("stage-readout");
  const stages = document.querySelectorAll("section[data-stage]");
  if (stageReadout && "IntersectionObserver" in window) {
    const io = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (entry.isIntersecting) {
            stageReadout.textContent = entry.target.dataset.stage;
          }
        });
      },
      { rootMargin: "-35% 0px -50% 0px", threshold: 0 },
    );
    stages.forEach((s) => io.observe(s));
  }

  /* 05. Hydrate live asset links from GitHub Releases with zero-JS fallback */
  async function hydrateReleases() {
    try {
      const res = await fetch(
        "https://api.github.com/repos/diodesign/diosix/releases/latest",
        { headers: { Accept: "application/vnd.github+json" } },
      );
      if (!res.ok) return;
      const data = await res.json();
      const assets = Array.isArray(data.assets) ? data.assets : [];
      const tag = data.tag_name;
      const pill = document.getElementById("release-pill");
      if (pill && tag) pill.textContent = `${tag} · riscv64`;

      ["core", "personal", "swarm"].forEach((ed) => {
        const tar = assets.find((a) =>
          a.name.startsWith("diosix-") &&
          a.name.includes(`-${ed}-`) &&
          a.name.endsWith(".tar.xz"),
        );
        const sha = assets.find((a) =>
          tar && a.name === `${tar.name}.sha256`,
        );
        const dlEl = document.querySelector(`[data-dl="${ed}"]`);
        const shaEl = document.querySelector(`[data-sha="${ed}"]`);
        if (dlEl && tar) {
          dlEl.href = tar.browser_download_url;
          const mib = Math.round(tar.size / (1024 * 1024));
          dlEl.textContent = `Download ${ed} (${mib} MiB)`;
        }
        if (shaEl && sha) {
          shaEl.href = sha.browser_download_url;
        }
      });

      const sdk = assets.find((a) =>
        a.name.startsWith("libdiosix-") && a.name.endsWith(".tar.xz"),
      );
      const sdkEl = document.querySelector("[data-dl='sdk']");
      if (sdkEl && sdk) {
        sdkEl.href = sdk.browser_download_url;
        const mib = (sdk.size / (1024 * 1024)).toFixed(1);
        sdkEl.textContent = `${sdk.name} (${mib} MiB)`;
      }
    } catch {
      /* Network offline or rate-limited: preserve /releases/latest fallbacks. */
    }
  }

  selectNode("root");
  renderComposer();
  hydrateReleases();
})();
