# Games-on-Whales / Wolf GPU streaming

How the `games` namespace went from an empty manifest to a real application
streaming GPU-accelerated, hardware-encoded video to a [Moonlight](https://moonlight-stream.org/)
client — co-resident with the LLM stack on a single two-GPU node — and what is
still open. This README is the narrative record; topic-by-topic deep dives live
alongside it in this directory:

| Topic | What's in it |
| --- | --- |
| [gpu-handoff-and-time-slicing.md](gpu-handoff-and-time-slicing.md) | How the LLM yields GPUs to a game session (preemption), why GPU time-slicing breaks it, the llmkube `count`↔`tensor-split` mechanics, and what you'd have to do to re-enable time-slicing. |
| [gpu-co-location.md](gpu-co-location.md) | Why a real game's app container can't be HW-accelerated yet (same-GPU placement), why this stack disables device selection, and the three real fix paths. |
| [known-issues.md](known-issues.md) | Open quirks: the Test Ball video override, and controller/keyboard input. |
| [upstream-issues.md](upstream-issues.md) | Drafted upstream issues (fenrir/wolf and defilantech/LLMKube) not yet filed. |

## What we built

On-demand cloud-gaming on the homelab cluster:

- A Moonlight client (laptop, phone, TV) pairs with an in-cluster
  **`moonlight-proxy`**.
- The **`direwolf-operator`** (the [shrinedogg/fenrir](https://github.com/shrinedogg/fenrir)
  fork of [Games-on-Whales](https://games-on-whales.github.io/)) reconciles
  `App` / `User` / `Session` / `Pairing` CRDs and spins up a **per-session pod** on
  the GPU node (`talos1`): a Wolf Wayland compositor + GStreamer/NVENC capture
  sidecar, plus the application container (e.g. Firefox).
- Video streams back over RTSP/RTP; the whole thing is GitOps-managed by Flux.

The hard part was never "deploy the chart." It was three intertwined problems:
**(1)** getting the client's video to actually arrive, **(2)** getting the GPU
hardware encoder to engage, and **(3)** sharing two physical GPUs between Wolf,
the app, and the always-on LLM. Each took several iterations.

## Final architecture (current state)

| Concern | Resolution |
| --- | --- |
| Operator / proxy | shrinedogg/fenrir fork, images pinned by digest (`#1082`) |
| Client source IP | Cilium **DSR** (`opt` dispatch) on annotated Services (`#1102`/`#1103`) |
| Shared LB VIP | `10.0.42.135`, Cilium LB-IPAM sharing-key `direwolf` |
| GPU encode | Wolf sidecar gets a GPU; entrypoint auto-detects the injected render node (`#1104`/`#1105`) |
| LLM ↔ gaming GPU handoff | **Automatic** via scheduler preemption of the LLM (`#1117`) |
| App HW-accel co-location | **Open** — needs same-GPU placement; tracked in `#1109` |

Node facts: `talos0` = `10.0.42.3` (control plane), `talos1` = `10.0.42.4` (GPU
node — RTX **3090 Ti** at `0000:01:00.0`, RTX **3070** at `0000:0f:00.0`). All GPU
pods are pinned to `talos1`. Driver `595.71.05` (nvidia-open via Talos extensions),
gpu-operator with `cdi.default: true`. Cilium `1.19.5`, `routingMode: native`,
global LB mode `snat`. Kubernetes `v1.36`.

---

## The journey

### 1. Foundation and config papercuts

The base deployment (`#1082`) landed the operator, proxy, and CRDs. Two early
config bugs had to clear before anything ran:

- **Strict base64 (`#1089`).** The `appAssetWebP` asset was 423 characters — not a
  multiple of 4. macOS `base64 -d` is lenient and accepted it locally, but
  Kubernetes' `format: byte` uses Go's *strict* decoder and rejected it. Lesson:
  validate base64 destined for a k8s `format: byte` field with a strict decode or
  `kubectl --dry-run=server`, not the macOS CLI.
- **PodSecurity + Flux envsubst (`#1096`).** Two parts: (a) the `games` namespace
  needed `pod-security.kubernetes.io/enforce: privileged` because the wolf-agent
  sidecar requires `NET_ADMIN`; (b) Flux's `postBuild` envsubst rewrites **every**
  braced `${...}` across all rendered manifests — including shell scripts embedded
  in ConfigMaps and container commands. It silently blanked `source "${init_script}"`
  → `source ""` in the wolf entrypoint and `${PULSE_SINK}` in the Firefox command.
  Fix: annotate those resources `kustomize.toolkit.fluxcd.io/substitute: disabled`.

### 2. "No video received" — the networking half

Pairing and the RTSP control plane worked immediately, but the client never got
video. Root cause: **SNAT**. Cilium masqueraded the Moonlight client's source IP to
a node IP, so Wolf was told `client_ip = 10.0.42.3` and streamed RTP video *to the
node* instead of the client. Control/RTSP survived because it's client-initiated
(conntrack handles the return path); only the server-initiated video stream broke.

The fix had false starts:

- **`externalTrafficPolicy: Local` (`#1099`)** preserved the real client IP, but
  Cilium LB-IPAM **won't share one VIP across `ETP: Local` Services** — the session
  `*-rtp` Service got a *different* IP than the proxy, so RTSP to the shared
  `.135:48010` timed out. This architecture *requires* a single shared VIP, so
  ETP:Local was a dead end. Reverted in `#1101`.
- **DSR (`#1102`)** was the right tool: `forwarding-mode: dsr` is a *datapath*
  setting independent of LB-IPAM's sharing-key, so it preserves the source IP while
  keeping `ETP: Cluster` (sharing intact). But the first attempt used
  `dsrDispatch: geneve`, which **crash-looped every Cilium agent** — geneve dispatch
  requires the geneve tunnel protocol, and with `routingMode: native` the agent
  fatally rejects it.
- **`dsrDispatch: opt` (`#1103`)** is the correct dispatch for native routing
  (IPv4-option based). Safe here because both nodes are L2-adjacent through an L2
  switch that forwards by MAC and doesn't strip IPv4 options.

End state: Cilium runs `bpf-lb-mode=snat` globally with `bpf-lb-mode-annotation=true`
+ `bpf-lb-dsr-dispatch=opt`, so **only** annotated Services use DSR. The proxy
Service and every session `*-rtp` Service carry
`service.cilium.io/forwarding-mode: dsr` — the latter injected at CREATE by a
`MutatingAdmissionPolicy` (`direwolf-session-svc-dsr`), since the operator exposes
no way to configure the Services it generates. Validated: proxy and Wolf both saw
the real client `10.0.10.104`, sharing the VIP `10.0.42.135`.

### 3. "No video received" — the GPU half

With networking fixed, video *still* fell back to software x264. The logs showed
`/dev/dri/renderD128 doesn't exist … not a NVIDIA GPU … x264 (Software)`. This had
masqueraded as three separate blockers (a GBM panic, "wolfConfig ignored", NVENC
failure) — all were the **same** root cause: **Wolf couldn't find the GPU.**

The subtlety is the render-node numbering. On `talos1`, CDI injects each *allocated*
GPU's DRM render node at its **host numbering**: `renderD128` = 3090 Ti
(`01:00.0`), `renderD129` = 3070 (`0f:00.0`). A single `nvidia.com/gpu: 1` request
lands on **either** card non-deterministically, so Wolf's hardcoded
`renderNode: renderD128` was absent whenever it got the 3070 → software fallback.
(This reconciled the earlier `#1098` flip-flop between renderD128/129 — both were
"right" on different runs.)

- **`#1104`** made the Wolf sidecar request `nvidia.com/gpu: 2` (both GPUs), so
  both render nodes are always present and `renderD128` is always valid. Confirmed
  live: `renderD128 vendor: NVIDIA` · `nvcodec` · `zero copy pipeline on Nvidia` ·
  `nvh265enc` · live video. The GBM/NVENC "failures" vanished — they were only ever
  symptoms of the missing GPU; `GBM_BACKENDS_PATH` had been correct all along.

> **GPU lever gotcha:** the GPU request lives on `sidecarPolicies.wolf.resources`
> in the User CRD, *not* the top-level `spec.resources` (which is only a *ceiling*
> for the app container). Editing the top-level field does nothing for Wolf.

But grabbing both GPUs created the next problem: an App with its *own* GPU container
(Firefox needs one) now had nothing left to schedule onto.

### 4. A real app — Firefox end-to-end

Two changes got Firefox co-scheduled with Wolf and streaming:

- **Render-node auto-detect (`#1105`).** The fork passes the App's
  `wolfConfig.runtimeVariables.renderNode` to the sidecar as `WOLF_RENDER_NODE`. The
  wolf-entrypoint ConfigMap wrapper now detects whichever `renderD*` CDI actually
  injected and overrides that env var at startup. This let the Wolf sidecar drop
  back to **1 GPU** and still get NVENC on whatever card it landed on, freeing the
  other GPU for the app container.
- **Firefox profile chown (`#1106`).** The `wolf-data` emptyDir is `root:root`
  (shared with the root Wolf sidecar), so Firefox couldn't load its profile. A
  `chown -R retro /home/retro` in the app command before the entrypoint fixed it.

Result (2026-06-23): a Firefox session streamed a clean **2560×1600 @ 60 FPS HEVC**
picture to Moonlight — **0.00% frames dropped**, 3 ms network latency, 2.23 ms
decode, 1.41 ms render. The streaming pipeline is fully validated end-to-end.

### 5. Sharing the GPUs with the LLM — automatic handoff

`talos1`'s two GPUs are normally held by **llmkube** (`qwen3-6-27b-mtp`,
`nvidia.com/gpu: 2`). A game session needs both (Wolf + app), so the LLM has to
yield. The operator can't set a `priorityClassName` on session pods, so the lever
lives on the *consumer* side: llmkube's model is pinned to a negative PriorityClass
**`gpu-preemptible`** (value `-100`), and a default-priority session preempts it.

This is where time-slicing led us astray:

- To let Wolf (1 GPU) + the app (1 GPU) co-schedule, `#1105` had enabled **GPU
  time-slicing** (`replicas: 4` → `talos1` advertises `nvidia.com/gpu: 8`). But
  time-slicing **broke preemption**: with 8 logical GPUs the node always had free
  slices, so a session scheduled *alongside* qwen instead of preempting it — and
  they then contended for VRAM on the same physical card.
- **`#1107`** tried to restore scarcity by bumping qwen's request to
  `resources.gpu: 8`. It was a **no-op**: llmkube's `resolveGPUCount` binds the pod
  request to `Model.hardware.gpu.count` (= 2) and silently ignores `resources.gpu`,
  so qwen still requested only 2 of the 8 slices.
- **`#1108`** over-corrected — it ripped out *both* time-slicing and the
  PriorityClass and fell back to manual `kubectl scale`.

The resolution (`#1117`, supersedes `#1108`): remove **only** time-slicing, **keep**
the PriorityClass. With the node back to `nvidia.com/gpu: 2`, qwen holds both, a
session needs both, and the scheduler **preempts** the `-100` qwen pod to fit.
Validated live — a Firefox session preempted qwen on `talos1`:

```
Normal  Preempted  pod/qwen3-6-27b-mtp-...-nj765
  Preempted by pod eaef996d-... (alex-firefox) on node talos1
```

qwen then sits `Pending` (it correctly *can't* preempt the default-priority session
back) and reschedules + reloads the model when the session ends. **Automatic
handoff, no arbiter, no manual steps.** The lesson: time-slicing was the sole
culprit — it broke preemption *and* never delivered co-location (below); the
PriorityClass was collateral damage in the over-correction.

> The `Model.hardware.gpu.count` ↔ `--tensor-split` coupling that made `#1107` a
> no-op — and what re-enabling time-slicing would actually require — is documented
> in [`gpu-handoff-and-time-slicing.md`](gpu-handoff-and-time-slicing.md). It is
> also worth filing upstream against defilantech/LLMKube — see Open work.

---

## What works today

- Moonlight pairing and the full RTSP/control plane.
- Operator / session lifecycle; `App` / `User` CRDs reconcile.
- Source-IP preservation via DSR (shared VIP intact).
- GPU detection, NVENC hardware encode, zero-copy capture → live HEVC video.
- **Firefox streams end-to-end**, with **automatic** preemption-based handoff of the
  LLM when a session needs the GPUs.

## What's still open

### Co-location (the blocker for *real games*)

Firefox works because it tolerates **software** rendering. A real game needs the
app container HW-accelerated, which requires Wolf's sidecar and the app container to
share the **same physical GPU** (NVIDIA has no cross-GPU dmabuf for the zero-copy
Wayland path). The device plugin instead *spreads* the pod's two `nvidia.com/gpu: 1`
allocations across the two cards, so the app's `wayland-egl` can't open Wolf's
render node and falls back to software. Full detail and the fix paths:
[gpu-co-location.md](gpu-co-location.md).

In short, three real paths (tracked in issue **#1109**): **DRA** (the principled
answer, blocked on a graphics/display CDI-injection gap), a **Talos toolkit + UUID
pin** (bypasses the device plugin, security-relevant), or the **shrinedogg
gpu-arbiter** (the manual-handoff half).

### Smaller items

- **Controller/keyboard input** — needs a `squat.ai/uinput` device plugin
  (`/dev/uinput`, `/dev/input/event*`); Wolf logs `MOUSE_MOVE_REL_PACKET but no
  mouse device present`. Pointer worked over the stream; full input is unwired. See
  [known-issues.md](known-issues.md).
- **Upstream issues to file** — fenrir/wolf (configurable session Services) and
  defilantech/LLMKube (GPU count vs request; device-level assignment). Drafts in
  [upstream-issues.md](upstream-issues.md).

---

## Reference facts and gotchas

- **GPU ↔ render-node mapping** (`talos1`, `nvidia.com/gpu: 2`, no time-slicing):
  `renderD128` = 3090 Ti (`01:00.0`), `renderD129` = 3070 (`0f:00.0`). CDI injects
  each *allocated* GPU's node at host numbering — a 1-GPU request gives one of them
  non-deterministically.
- **Cilium DSR:** with `routingMode: native`, DSR dispatch **must** be `opt`, never
  `geneve` (geneve needs the geneve tunnel and crash-loops every agent). `opt` is
  safe only because the nodes are L2-adjacent.
- **User CRD resource semantics:** `spec.resources` = a *ceiling* for the app
  container only; `sidecarPolicies.wolf.resources` = the *actual* request on the
  Wolf sidecar (the real GPU lever).
- **Flux envsubst** blanks any braced `${...}` in rendered manifests, including
  embedded shell — opt out per-resource with
  `kustomize.toolkit.fluxcd.io/substitute: disabled`.
- **Strict base64:** k8s `format: byte` uses Go's strict decoder; validate with
  `--dry-run=server`, not macOS `base64 -d`.
- **llmkube GPU count** drives the pod request *and* `--split-mode`/`--tensor-split`
  simultaneously (`Model.hardware.gpu.count` wins over `resources.gpu`); changing it
  has model-loading side effects. Full mechanics:
  [gpu-handoff-and-time-slicing.md](gpu-handoff-and-time-slicing.md).
- **Moonlight ports:** video 47998/UDP, control 47999/UDP, audio 48000/UDP, RTSP
  48010/TCP.
- **Pairing:** `kubectl -n games logs deploy/moonlight-proxy | grep "Insert pin"`,
  swap `127.0.0.1` → `10.0.42.135`, open in a browser, enter the 4-digit PIN.

## Reference deployments

- **shrinedogg/biggs.dog** (`clusters/cluster0/.../dreamcast`) — the same fork on a
  single-dGPU node (always `renderD129`); has a `gpu-arbiter/` (DCGM-driven LLM
  scale-down) and `nvngx-pvc` (DLSS NGX cache for Proton).
- **joryirving/home-ops** — qwen on one GPU; PriorityClass preemption validated
  *for the LLM scale-down only*; DRA driver deployed but **games-on-whales does not
  actually work** there either (blocked on the same DRA graphics-injection gap).

## Repo layout

- `kubernetes/apps/games/games-on-whales/` — the app (`ks.yaml`, `app/*`, `README.md`).
- `app/session-service-policy.yaml` — the `direwolf-session-svc-dsr`
  MutatingAdmissionPolicy that injects the DSR annotation on `*-rtp` Services.
- `kubernetes/apps/ai/llmkube/models/` — the qwen model + `priorityclass.yaml`
  (`gpu-preemptible`).
- `kubernetes/apps/kube-system/nvidia-gpu/operator/` — the gpu-operator HelmRelease.
