(() => {
  document.documentElement.classList.add("js-ready");

  const REPO = "https://github.com/diodesign/diosix";
  const reducedMotion = window.matchMedia(
    "(prefers-reduced-motion: reduce)",
  ).matches;

  /* 01. Relative CID & use-case explorer */
  const SCENES = window.DIOSIX_SCENES || {};
  const sceneEls = document.querySelectorAll(".tree-scene[data-scene]");
  const caseBtns = document.querySelectorAll("[data-tree-case]");
  const readout = document.getElementById("cid-readout");
  let curScene = "swarm";

  function traceEdge(edge) {
    if (reducedMotion || typeof edge.getTotalLength !== "function") return;
    const len = edge.getTotalLength();
    edge.style.strokeDasharray = String(len);
    edge.style.strokeDashoffset = String(len);
    edge.getBoundingClientRect();
    edge.style.strokeDashoffset = "0";
  }

  function selectNode(id, animate = true) {
    const sceneData = SCENES[curScene];
    const activeScene = document.querySelector(
      `.tree-scene[data-scene="${curScene}"]`,
    );
    if (!sceneData || !activeScene) return;
    const view = sceneData.perspectives[id];
    if (!view) return;

    activeScene.querySelectorAll(".tree-node[data-node]").forEach((el) => {
      const nid = el.dataset.node;
      el.classList.remove("is-self", "is-parent", "is-child", "is-opaque");
      el.classList.add(view.roles[nid]);
      el.setAttribute("aria-pressed", String(nid === id));
      const label = el.querySelector(".node-cid");
      if (label) label.textContent = view.cids[nid];
    });
    activeScene.querySelectorAll(".tree-edge[id]").forEach((edge) => {
      const active = view.edges.includes(edge.id);
      edge.classList.toggle("is-active", active);
      edge.classList.toggle("is-dim", !active);
      if (active && animate) {
        traceEdge(edge);
      } else {
        edge.style.strokeDasharray = "";
        edge.style.strokeDashoffset = "";
      }
    });
    const barrier = activeScene.querySelector(".tree-barrier");
    if (barrier) barrier.classList.toggle("is-highlighted", view.barrier);
    if (readout) readout.textContent = view.text;
  }

  function setTreeScene(name, syncThumbs = true) {
    if (!SCENES[name]) return;
    curScene = name;
    sceneEls.forEach((sc) => {
      const active = sc.dataset.scene === name;
      sc.classList.toggle("is-active", active);
      sc.querySelectorAll(".tree-node[data-node]").forEach((node) => {
        node.setAttribute("tabindex", active ? "0" : "-1");
      });
    });
    caseBtns.forEach((btn) =>
      btn.setAttribute("aria-pressed", String(btn.dataset.treeCase === name)),
    );
    if (syncThumbs) syncAllThumbs();
    selectNode(SCENES[name].defaultNode, false);
  }

  sceneEls.forEach((sc) => {
    sc.querySelectorAll(".tree-node[data-node]").forEach((node) => {
      node.addEventListener("click", () => selectNode(node.dataset.node, true));
      node.addEventListener("keydown", (ev) => {
        if (ev.key === "Enter" || ev.key === " ") {
          ev.preventDefault();
          selectNode(node.dataset.node, true);
        }
      });
    });
  });

  caseBtns.forEach((btn) =>
    btn.addEventListener("click", () => setTreeScene(btn.dataset.treeCase)),
  );

  /* 02. Sliding thumb helper for segmented tracks */
  function moveSegThumb(track) {
    const thumb = track.querySelector(".seg-thumb");
    const active = track.querySelector("[aria-pressed='true']");
    if (!thumb || !active) return;
    thumb.style.width = `${active.offsetWidth}px`;
    thumb.style.transform = `translateX(${active.offsetLeft}px)`;
  }

  const segTracks = document.querySelectorAll("[data-seg-track]");
  function syncAllThumbs() {
    segTracks.forEach(moveSegThumb);
  }

  /* 03. Edition and Boot Mode command composer */
  const COMMANDS = {
    core: {
      emulated: {
        cmd: "./scripts/build.sh -Dedition=core run",
        note: "Boots headless Diosix Core in QEMU with developer SSH keys on localhost port 2222.",
      },
      live: {
        cmd: "tar -xf diosix-26.1-core-riscv64.tar.xz && ./diosix-26.1-core-riscv64/run-diosix.sh",
        note: "Unpacks the release bundle for QEMU, or flash the live image to removable media and install with dsx.",
      },
      installed: {
        cmd: "dsx host install --disk /dev/nvme0n1 --edition core --hostname core-01",
        note: "Writes GPT boot, state, and data partitions and records Core as the persistent edition.",
      },
      diskless: {
        cmd: "python3 -B scripts/hil/runner.py --self-test",
        note: "Stages verified Diosix Core payloads over HTTP into RAM without writing to local storage.",
      },
    },
    personal: {
      emulated: {
        cmd: "./scripts/build.sh run-personal",
        note: "Boots Diosix Personal in QEMU with desktop profile controls ready over SSH.",
      },
      live: {
        cmd: "tar -xf diosix-26.1-personal-riscv64.tar.xz && ./diosix-26.1-personal-riscv64/run-diosix.sh",
        note: "Inspects hardware live in RAM before installing your desktop profile onto internal storage.",
      },
      installed: {
        cmd: "dsx host install --disk /dev/nvme0n1 --edition personal --personal-image desktop.img --dma-trusted --auto-start",
        note: "Saves Personal as the persistent edition and retains desktop profiles across reboots.",
      },
      diskless: {
        cmd: "python3 -B scripts/test_personal_passthrough.py",
        note: "Verifies hardware register mapping, contiguous RAM allocation, and interrupt forwarding in QEMU.",
      },
    },
    swarm: {
      emulated: {
        cmd: "./scripts/build.sh run-swarm",
        note: "Launches two networked QEMU Swarm hosts running message boards, the AI gateway, and peer discovery.",
      },
      live: {
        cmd: "tar -xf diosix-26.1-swarm-riscv64.tar.xz && ./diosix-26.1-swarm-riscv64/run-diosix.sh",
        note: "Boots the default Swarm live bundle, or flash the GPT live image directly onto hardware nodes.",
      },
      installed: {
        cmd: "dsx host install --disk /dev/nvme0n1 --edition swarm --stewards --standby-root",
        note: "Provisions persistent Swarm storage with charter governance and standby failover configuration.",
      },
      diskless: {
        cmd: "python3 -B scripts/run_swarm.py --hosts 2 --self-test",
        note: "Boots stateless multi-host Swarm nodes over RAM boot with zero local disk writes.",
      },
    },
  };

  let curEd = "swarm";
  let curMode = "emulated";
  const edBtns = document.querySelectorAll("[data-select-ed]");
  const modeBtns = document.querySelectorAll("[data-select-mode]");
  const cmdOut = document.getElementById("composer-cmd");
  const cmdPre = cmdOut ? cmdOut.parentElement : null;
  const noteOut = document.getElementById("composer-note");
  const copyBtn = document.getElementById("composer-copy");

  function renderComposer(flash = true) {
    const entry = COMMANDS[curEd][curMode];
    edBtns.forEach((b) =>
      b.setAttribute("aria-pressed", String(b.dataset.selectEd === curEd)),
    );
    modeBtns.forEach((b) =>
      b.setAttribute("aria-pressed", String(b.dataset.selectMode === curMode)),
    );
    syncAllThumbs();
    if (cmdPre && flash && !reducedMotion) {
      cmdPre.classList.add("is-updating");
      setTimeout(() => {
        if (cmdOut) cmdOut.textContent = entry.cmd;
        if (noteOut) noteOut.textContent = entry.note;
        cmdPre.classList.remove("is-updating");
      }, 90);
    } else {
      if (cmdOut) cmdOut.textContent = entry.cmd;
      if (noteOut) noteOut.textContent = entry.note;
    }
  }

  edBtns.forEach((btn) =>
    btn.addEventListener("click", () => {
      curEd = btn.dataset.selectEd;
      renderComposer(true);
    }),
  );

  modeBtns.forEach((btn) =>
    btn.addEventListener("click", () => {
      curMode = btn.dataset.selectMode;
      renderComposer(true);
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
        copyBtn.textContent = "Select";
      }
      setTimeout(() => {
        copyBtn.textContent = "Copy";
      }, 1500);
    });
  }

  /* 04. stable / devel branch switcher for GitHub docs */
  const branchBtns = document.querySelectorAll("[data-doc-branch]");
  const docLinks = document.querySelectorAll("a[data-doc-path]");

  function setDocBranch(branch) {
    branchBtns.forEach((b) =>
      b.setAttribute("aria-pressed", String(b.dataset.docBranch === branch)),
    );
    docLinks.forEach((a) => {
      a.href = `${REPO}/blob/${branch}/${a.dataset.docPath}`;
    });
    syncAllThumbs();
  }

  branchBtns.forEach((btn) =>
    btn.addEventListener("click", () => setDocBranch(btn.dataset.docBranch)),
  );

  /* 05. Adaptive masthead theme, nav hairline, & one-shot reveals */
  const header = document.getElementById("site-header");
  const hero = document.getElementById("welcome");
  const nav = document.querySelector(".site-nav");
  const navInd = document.getElementById("nav-indicator");
  const navLinks = nav ? nav.querySelectorAll("a[href^='#']") : [];
  let activeNavId = "";

  function syncNavIndicator() {
    if (!navInd || !activeNavId) {
      if (navInd) navInd.classList.remove("is-visible");
      return;
    }
    const target = nav.querySelector(`a[href="#${activeNavId}"]`);
    navLinks.forEach((a) => a.classList.toggle("is-current", a === target));
    if (!target || target.offsetParent === null) {
      navInd.classList.remove("is-visible");
      return;
    }
    navInd.classList.add("is-visible");
    navInd.style.transform =
      `translateX(${target.offsetLeft}px) scaleX(${target.offsetWidth})`;
  }

  if ("IntersectionObserver" in window) {
    if (header && hero) {
      new IntersectionObserver(
        (entries) => {
          entries.forEach((entry) => {
            header.classList.toggle("is-on-hero", entry.isIntersecting);
            if (entry.isIntersecting && entry.intersectionRatio > 0.45) {
              activeNavId = "";
              syncNavIndicator();
            }
          });
        },
        { rootMargin: "-64px 0px 0px 0px", threshold: [0.05, 0.45] },
      ).observe(hero);
    }

    const tracked = ["architecture", "editions", "boot-modes", "docs"]
      .map((id) => document.getElementById(id))
      .filter(Boolean);
    const navIo = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (entry.isIntersecting) {
            activeNavId = entry.target.id;
            syncNavIndicator();
          }
        });
      },
      { rootMargin: "-35% 0px -50% 0px", threshold: 0 },
    );
    tracked.forEach((el) => navIo.observe(el));

    const revealIo = new IntersectionObserver(
      (entries, observer) => {
        entries.forEach((entry) => {
          if (entry.isIntersecting) {
            entry.target.classList.add("is-visible");
            observer.unobserve(entry.target);
          }
        });
      },
      { threshold: 0.08 },
    );
    document
      .querySelectorAll(".stage-reveal")
      .forEach((el) => revealIo.observe(el));
  } else {
    document
      .querySelectorAll(".stage-reveal")
      .forEach((el) => el.classList.add("is-visible"));
  }

  /* 06. GitHub Releases asset hydration */
  async function hydrateReleases() {
    try {
      const res = await fetch(`${REPO.replace("github.com", "api.github.com/repos")}/releases/latest`, {
        headers: { Accept: "application/vnd.github+json" },
      });
      if (!res.ok) return;
      const data = await res.json();
      const assets = Array.isArray(data.assets) ? data.assets : [];
      const pill = document.getElementById("release-pill");
      if (pill && data.tag_name) pill.textContent = `${data.tag_name} (riscv64)`;

      ["core", "personal", "swarm"].forEach((ed) => {
        const tar = assets.find((a) =>
          a.name.startsWith("diosix-") &&
          a.name.includes(`-${ed}-`) &&
          a.name.endsWith(".tar.xz"),
        );
        const sha = assets.find((a) => tar && a.name === `${tar.name}.sha256`);
        const dlEl = document.querySelector(`[data-dl="${ed}"]`);
        const shaEl = document.querySelector(`[data-sha="${ed}"]`);
        if (dlEl && tar) {
          dlEl.href = tar.browser_download_url;
          const mib = Math.round(tar.size / (1024 * 1024));
          dlEl.textContent = `Download ${ed} (${mib} MiB)`;
        }
        if (shaEl && sha) shaEl.href = sha.browser_download_url;
      });

      const sdk = assets.find((a) =>
        a.name.startsWith("libdiosix-") && a.name.endsWith(".tar.xz"),
      );
      const sdkEl = document.querySelector("[data-dl='sdk']");
      if (sdkEl && sdk) {
        sdkEl.href = sdk.browser_download_url;
        sdkEl.textContent = `${sdk.name} (${(sdk.size / (1024 * 1024)).toFixed(1)} MiB)`;
      }
    } catch {
      /* Fallback /releases/latest URLs remain intact. */
    }
  }

  window.addEventListener("resize", () => {
    syncAllThumbs();
    syncNavIndicator();
  });

  const initCase = new URLSearchParams(window.location.search).get("case");
  setTreeScene(SCENES[initCase] ? initCase : "swarm", false);
  renderComposer(false);
  requestAnimationFrame(syncAllThumbs);
  if (document.fonts && document.fonts.ready) {
    document.fonts.ready.then(() => {
      syncAllThumbs();
      syncNavIndicator();
    });
  }
  hydrateReleases();
})();
