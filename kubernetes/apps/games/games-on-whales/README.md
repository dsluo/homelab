# games-on-whales

On-demand, GPU-accelerated game streaming built on [Games-on-Whales
Wolf](https://games-on-whales.github.io/) + the
[Fenrir/direwolf-operator](https://github.com/shrinedogg/fenrir) fork by
shrinedogg. A [Moonlight](https://moonlight-stream.org/) client pairs with an
in-cluster `moonlight-proxy`; the `direwolf-operator` reconciles
`App`/`User`/`Session`/`Pairing` CRDs and spins up a per-session pod (Wolf
Wayland compositor + GStreamer/NVENC + the app) on the NVIDIA node (talos1),
streaming the desktop back over RTSP/RTP.

This is **phase 1: validation only** — operator + proxy + two lightweight apps
(Test Ball, Firefox). Steam / DLSS / persistent library are deliberately out of
scope (see the fork's `examples/steam.yaml` to add later).

## Layout

- `ks.yaml` — `GitRepository` (fork, pinned commit) + `fenrir-crds` Flux
  Kustomization (applies `./crds`) + the `games-on-whales` app Kustomization
  (`dependsOn: fenrir-crds`).
- `app/ocirepository.yaml` — published Helm chart
  `oci://ghcr.io/games-on-whales/charts/direwolf-operator`.
- `app/helmrelease.yaml` — operator + moonlight-proxy. Overrides the four images
  with shrinedogg's published fork tags and aligns the Cilium LB sharing key.
- `app/user.yaml` — the `alex` User (hardcoded upstream); defines the session
  pod's GPU request, the root-entrypoint workaround, and the fake-udev wiring.
- `app/wolf-entrypoint.yaml` — ConfigMap that forces the wolf sidecar to run as
  root (see comments within).
- `app/apps.yaml` — `Test Ball` (synthetic `videotestsrc`, no app container) and
  `Firefox` App CRDs.

## Images (shrinedogg's fork, docker.io/shrinedogg/\*)

| Image | Tag | Why the fork patch |
|---|---|---|
| direwolf-operator | v0.1.0 | retries stream reconciliation; prunes stale tracked sessions |
| moonlight-proxy | v0.1.1 | `/launch` waits 120s (not 25s) for cold-start session pods |
| wolf-agent | v0.1.0 | Go fake-udev for controller hotplug |
| wolf | v0.1.0 | skips legacy `wl_drm` when dmabuf v4 feedback is active (sway crash) |

## GPU sharing with llmkube (PriorityClass preemption)

talos1's GPUs (3090 Ti + 3070) are normally held by **llmkube** (`qwen3-6-27b-mtp`,
`nvidia.com/gpu: 2`). The Fenrir operator cannot set a `priorityClassName` on the
session pods it generates (the User CRD only exposes resources/volumes/sidecar
policies), so instead **llmkube's GPU model is pinned to a negative PriorityClass**
`gpu-preemptible` (value `-100`, defined in
`kubernetes/apps/ai/llmkube/models/priorityclass.yaml`).

A game session pod runs at the default priority (0). When it requests
`nvidia.com/gpu` and both GPUs are held by llmkube, the scheduler **preempts** the
negative-priority llmkube pod to free a GPU; llmkube reschedules and reloads its
model once the session ends. No custom controller, no fork patch.

Trade-offs: preemption evicts llmkube's whole pod (both GPUs — a Test Ball session
needs 1, a Firefox session needs 2: wolf + app); the LLM is offline during play and
takes time to reload afterward.

> ⚠️ **Do not enable GPU time-slicing on the gpu-operator.** Preemption relies on
> the node advertising exactly `nvidia.com/gpu: 2`; time-slicing inflates that (e.g.
> 8 slices) so a session schedules *alongside* qwen without preempting it, and they
> contend for VRAM. See issue #1109.

## Pairing / using it

1. Get the shared LB IP: `kubectl -n games get svc -o wide` (pinned to
   `10.0.42.135`).
2. Point a Moonlight client at that IP and start pairing.
3. Grab the PIN/pairing URL from the proxy logs:
   `kubectl -n games logs deploy/direwolf-moonlight-proxy`.
4. Complete pairing (creates a `Pairing` CR), then launch **Test Ball** first
   (pure pipeline check), then **Firefox**. First launch is slow (image pull +
   wolf boot); the patched proxy waits up to 120s.

## Open items / cluster-specific verification

- **Render node**: `wolfConfig.runtimeVariables.renderNode` is set to
  `/dev/dri/renderD129` (shrinedogg's CDI-injected dGPU node). Verify on talos1:
  `talosctl -n <talos1-ip> ls /dev/dri` and check what the CDI-injected node is
  inside the wolf container. Wrong node → silent software x264 fallback.
- **CDI runtime**: session pods can't set `runtimeClassName: nvidia` (CRD limit);
  GPU injection relies on the gpu-operator running with `cdi.default: true` (it
  does). Confirm the wolf container actually sees the GPU.
- **Input / uinput**: the `squat.ai/uinput` request was dropped (no
  generic-device-plugin here). Video streams without it, but controller/virtual
  input needs `/dev/uinput` on talos1 (uinput kernel module + device access) —
  add a generic-device-plugin or privileged `/dev/uinput` hostPath mount when
  input is wanted. Test Ball needs no input.
- **DSR optimization** (skipped): shrinedogg uses a `MutatingAdmissionPolicy` to
  set `service.cilium.io/forwarding-mode: dsr` on the shared-IP Services so video
  egresses directly from the GPU node. Needs Cilium `bpf.lbModeAnnotation=true` +
  `loadBalancer.dsrDispatch`. Only relevant if video lands on a non-GPU node.
