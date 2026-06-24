# GPU co-location: HW-accelerating the app container (open)

Firefox streams end-to-end today, but it tolerates **software** rendering. A real
game needs its app container **hardware-accelerated**, and that is the open blocker.

## The problem

For the zero-copy Wayland path, the Wolf sidecar and the app container must share
the **same physical GPU** — NVIDIA has no cross-GPU dmabuf. But the device plugin
*spreads* the pod's two `nvidia.com/gpu: 1` allocations across the two cards
(e.g. app → 3090 Ti / `renderD128`, wolf → 3070 / `renderD129`). The app's
`wayland-egl` then can't open Wolf's render node:

```
libEGL warning: could not open /dev/dri/renderD129
```

…so the app falls back to software rendering. Fine for Firefox; broken for games.

## Why we can't just pin the cards

Pinning both containers to one card needs **explicit device selection**, which this
stack deliberately disables. Both mechanisms are ignored (proven with test Jobs — no
`nvidia-smi`, no `/dev/dri` in the container):

- the `cdi.k8s.io/*` pod annotation, **and**
- `NVIDIA_VISIBLE_DEVICES=<uuid>`

because the Talos nvidia-container-toolkit ships `accept-nvidia-visible-devices-*`
**off**.

Reference UUIDs (talos1):

| Card | UUID | Index | Render node | PCI |
| --- | --- | --- | --- | --- |
| RTX 3090 Ti | `GPU-9de300eb-ef5d-4fee-1f75-9f6202d85d6d` | 0 | renderD128 | `01:00.0` |
| RTX 3070 | `GPU-8756b659-8947-df5a-dd44-7a78f0bf07bc` | 1 | renderD129 | `0f:00.0` |

## Three real paths (deferred; tracked in #1109)

1. **DRA — the principled path.** `kubernetes-sigs/dra-driver-nvidia-gpu` does device
   selection by attribute/UUID (pin the 3090 Ti) **and** shared allocation
   (co-location) through the scheduler *with accounting* — no Talos hack, no arbiter.
   **Blocked on a known gap:** the DRA driver's CDI spec injects GPU *compute*
   userspace (CUDA) but **not** the *graphics/display* stack (`libEGL_nvidia`,
   `libGLX_nvidia`, the nvidia GBM backend, EGL/Vulkan ICDs) that Wolf needs. The
   fix is to patch `cmd/gpu-kubelet-plugin/cdi.go` (add the graphics flag to
   `nvcdi.New(...)`, available since nvidia-container-toolkit v1.18) and build a
   custom image. A real project.

2. **Talos toolkit + UUID pin.** Enable `accept-nvidia-visible-devices-*` on the
   Talos extension and pin both Wolf and the app to the 3090 Ti UUID. Bypasses the
   device plugin → no accounting, so the LLM handoff needs an arbiter or manual
   scaling. A security-relevant node change.

3. **shrinedogg gpu-arbiter** (the LLM-handoff half, if not using preemption): a
   scheduling-gate `MutatingAdmissionPolicy` (matched on `app=direwolf-worker` —
   identical label to our session pods) plus a small controller that scales the
   InferenceService `/scale` to 0, waits on `DCGM_FI_DEV_FB_FREE`, then ungates the
   session. Maps to us 1:1. It's also the prerequisite that makes UUID-pinned
   co-location *safe* (guarantees the card is free before the game lands).

## Reference deployments

- **shrinedogg/biggs.dog** (`clusters/cluster0/.../dreamcast`) — the same fork on a
  single-dGPU node (always `renderD129`, so no spreading problem); has the
  `gpu-arbiter/` and an `nvngx-pvc` (DLSS NGX DLL cache for Proton/Steam).
- **joryirving/home-ops** — qwen on one GPU; PriorityClass preemption validated *for
  the LLM scale-down only*; the DRA driver is deployed but **games-on-whales does not
  actually work** there either — blocked on the same DRA graphics-injection gap. He
  has the autoscaling/handoff but no working game app behind it.
