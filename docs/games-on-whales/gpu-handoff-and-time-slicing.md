# GPU handoff: LLM ↔ game sessions (and why time-slicing breaks it)

`talos1`'s two GPUs (3090 Ti + 3070) are normally held by **llmkube**
(`qwen3-6-27b-mtp`, `nvidia.com/gpu: 2`). A game session pod needs both (the Wolf
sidecar's compositor+NVENC, plus the app container's rendering), so the LLM must
yield. This doc explains the mechanism we use, why an earlier attempt (GPU
time-slicing) broke it, and exactly what it would take to re-introduce time-slicing
without breaking the LLM.

## The mechanism: scheduler preemption

The Fenrir operator can't set a `priorityClassName` on the session pods it
generates (the `User` CRD only exposes resources/volumes/sidecar policies), so the
lever lives on the **consumer** side instead:

- llmkube's model is pinned to a negative PriorityClass **`gpu-preemptible`** (value
  `-100`, in `kubernetes/apps/ai/llmkube/models/priorityclass.yaml`).
- A game session pod runs at the default priority (`0`). When it requests
  `nvidia.com/gpu` and both GPUs are held by llmkube, the scheduler **preempts** the
  `-100` llmkube pod to free the GPUs. llmkube reschedules and reloads its model
  once the session ends.

No custom controller, no fork patch. Validated live (see the chronology doc for the
`Preempted by pod …` event). The trade-off: preemption evicts llmkube's whole pod
(both GPUs), so the LLM is offline during play and takes time to reload afterward.

## Why GPU time-slicing broke preemption

Preemption only fires under **scarcity** — the scheduler must be unable to fit the
incoming pod, and evicting a lower-priority pod must make room.

GPU time-slicing (gpu-operator `devicePlugin.config` with `replicas: 4`) makes
`talos1` advertise `nvidia.com/gpu: 8` (4 logical slices per physical card). With 8
logical GPUs:

- qwen's *real* request is 2 (see the count mechanics below), so it holds 2 of 8
  slices → **6 free**.
- A session needs 2 → it fits in the leftover slices and schedules **alongside**
  qwen, with **no preemption**.
- The two then contend for VRAM on the same physical card (time-slicing multiplexes
  CUDA contexts; it does **not** partition VRAM).

So time-slicing removed the scarcity preemption depends on — *and* it never
delivered co-location either (the device plugin spreads a pod's GPU allocations
across cards; see [gpu-co-location.md](gpu-co-location.md)). It was reverted; the
node is back to `nvidia.com/gpu: 2`, qwen holds both, a session needs both → the
scheduler preempts qwen. (PR #1117; supersedes the over-correction in #1108, which
had removed the PriorityClass too.)

## llmkube `count` ↔ `tensor-split` mechanics

This matters because the model's GPU **count** drives *three* things at once — the
pod request, `--split-mode`, and the `--tensor-split` ratios. Verified against
defilantech/LLMKube @ `cc957aa` (`internal/controller/{runtime,runtime_llamacpp,
gpu_sharding}.go`).

- **`resolveGPUCount`** → `Model.hardware.gpu.count` if `> 0`, else
  `InferenceService.spec.resources.gpu`, else `0`. So the Model count **shadows**
  `resources.gpu`. This is why PR #1107 (which set `resources.gpu: 8` to force
  scarcity) was a silent **no-op** — `count: 2` won, so qwen still requested 2.
- **`resolveSplitMode(sharding)`** → `nil` ⇒ **`layer`** (omitting sharding does
  *not* disable it); `strategy: none` ⇒ `none`; `row`/`tensor` ⇒ `row`;
  `layer`/`pipeline`/`""`/default ⇒ `layer`.
- **`calculateTensorSplit(gpuCount, sharding)`** → uses the `layerSplit` ratios
  **only if `len(layerSplit) == gpuCount`**; otherwise it returns a `gpuCount`-length
  **equal** split (`"1,1,…"`). `--tensor-split` is appended only when
  `splitMode != none`.

### The `count: 0` escape hatch (and why it's a trap)

The only way to make `resources.gpu` authoritative is to drop `count` from the Model
— it's a non-pointer `int32`, so omitting it yields `0`, never nil. But `count: 0`
also disables sharding (`Sharding` is "only applicable when Count > 1"), which is
what emits our `--tensor-split 6,1`. So `count: 0` would break the 3090 Ti / 3070
layer split. Not worth it.

## If time-slicing is ever re-enabled

Our model has **2 physical cards** and a **2-entry `layerSplit`** tuned 6:1 (the
3070 has only 8 GB and can't hold half the model). If a future, unrelated need
brings time-slicing back and you want preemption to keep working, qwen must request
all 8 slices — i.e. `gpuCount = 8`. But then `len(layerSplit) = 2 ≠ 8`, so llmkube
emits `--tensor-split 1,1,1,1,1,1,1,1`. Time-slicing dedupes the 8 slices to **2
CUDA UUIDs**, so llama.cpp applies a **1:1** split across the asymmetric cards →
the 8 GB 3070 **OOMs**. The 6:1 split is gone.

To force request=8 *and* keep the 6:1 split (fragile):

```yaml
# Model
hardware.gpu.count: 8                  # or unset count + InferenceService resources.gpu: 8
hardware.gpu.sharding.strategy: none   # suppress llmkube's auto --tensor-split
# InferenceService.extraArgs (re-add BOTH, since strategy:none ⇒ --split-mode none)
- --split-mode
- layer
- --tensor-split
- "6,1"
```

⚠️ `strategy: none` still emits `--split-mode none`, so `--split-mode` lands in the
args **twice** (none + your layer). This only works if `extraArgs` are appended
*after* the generated flags and llama.cpp takes the last occurrence — **verify the
rendered pod args** (`kubectl get pod … -o jsonpath='{…args}'`) before trusting it.
This is the "passed twice" hazard the model manifest comment warns about, now
unavoidable.

**Recommended instead:** don't make qwen request 8. Keep `count: 2`, sharding
untouched (6:1 keeps working, zero hacks), and accept that preemption won't fire
(the node has slack) → drive the handoff manually:

```sh
kubectl -n ai scale inferenceservice qwen3-6-27b-mtp --replicas=0   # before gaming
kubectl -n ai scale inferenceservice qwen3-6-27b-mtp --replicas=1   # after
```

(This manual path is preserved on the `chore/gpu-without-preemption` branch.) The
`count: 8` recipe is only worth it if you need time-slicing *and* automatic
preemption simultaneously — a narrow corner.

## Rejected approaches

- **qwen `resources.gpu: 8` (#1107)** — no-op; `resolveGPUCount` binds the request
  to `Model.hardware.gpu.count` and ignores `resources.gpu`. See above.
- **KEDA** — wrong polarity (scales on *external* activity, not GPU contention), HPA
  stabilization windows, no scheduling-gate / VRAM-aware handoff, and it adds a
  whole new operator. Half a fix at best.
- **An arbiter** (scale the LLM down on a scheduling gate, wait on
  `DCGM_FI_DEV_FB_FREE`, then ungate) is a viable *manual-handoff* alternative if
  preemption is ever unavailable — see [gpu-co-location.md](gpu-co-location.md),
  where it also gates UUID-pinned co-location.

Full post-mortem: issue #1109.
