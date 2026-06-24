# Upstream issues to file (not yet filed)

Two upstream projects have gaps we worked around. Drafts below.

## 1. fenrir / wolf — configurable session Services

**Target:** `games-on-whales/fenrir` (canonical) or `shrinedogg/fenrir` (the fork we
run). **Refs:** dsluo/homelab#1099, dsluo/homelab#1100.

**Title:** Allow setting `externalTrafficPolicy` / annotations / labels on
operator-generated session Services

**Body:**

> **Problem.** The operator creates a LoadBalancer Service per session
> (`<user>-<app>-<id>-rtp`) but exposes no way to configure it. Behind a
> Cilium/MetalLB LB in default `externalTrafficPolicy: Cluster` (SNAT), the Moonlight
> client's source IP is masqueraded to a node IP, so Wolf streams RTP video to the
> node instead of the client ("No video received"). Control/RTSP works
> (client-initiated); only server-initiated video breaks.
>
> **Current workaround.** A `MutatingAdmissionPolicy` injecting
> `externalTrafficPolicy: Local` (or `service.cilium.io/forwarding-mode: dsr`) onto
> the session Services. Works, but every deployment reinvents it and it needs
> cluster-admin. (Note: `externalTrafficPolicy: Local` also breaks Cilium LB-IPAM IP
> sharing, so DSR is the viable annotation here.)
>
> **Request.** Let users configure the generated session Services —
> `externalTrafficPolicy` and/or arbitrary `annotations`+`labels` — via the
> `User`/`App` CRD or a global operator flag (e.g. `--session-service-annotations`).
> Removes the admission-policy workaround; helps anyone running Wolf behind a
> LoadBalancer needing client source-IP preservation (a common Moonlight
> requirement).

## 2. defilantech/LLMKube — GPU count vs request, and device selection

Two separable asks.

### 2a. Bug/UX: `hardware.gpu.count` silently shadows `resources.gpu`

`resolveGPUCount` returns `Model.hardware.gpu.count` whenever it's `> 0` and only
*then* falls through to `InferenceService.spec.resources.gpu` — with no warning. So
setting `resources.gpu` while a Model `count` is present is silently ignored (this
cost us the #1107 dead end).

**Ask:** honor `resources.gpu` as an explicit override, **or** at minimum **log a
warning** when it's set-but-ignored, **and** decouple it from the `Sharding` gate —
today the only way to make `resources.gpu` authoritative is `count: 0`, which also
kills sharding / `--tensor-split`.

### 2b. Feature: device-level GPU assignment

Today you only get a *count*; the device plugin picks the physical cards. On a mixed
node (e.g. 24 GB 3090 Ti + 8 GB 3070) you can't pin a model to a specific GPU or
co-locate two workloads on one card. The clean path is **DRA**: llmkube already
checks `Model.hardware.gpu.resourceClaims` in `hasGPUPresent`, so fleshing out a
ResourceClaims/DRA device-selection path would cover both pinning and shared
allocation. (Same DRA dependency as the games co-location work — see
[gpu-co-location.md](gpu-co-location.md).)
