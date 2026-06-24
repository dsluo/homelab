# Games-on-Whales — reference topics

Deep-dive references for the `games` namespace (Games-on-Whales / Wolf GPU
streaming), split out by topic. For the chronological story of how the deployment
reached its current state, see **[`../games-on-whales-bringup.md`](../games-on-whales-bringup.md)**.

| Topic | What's in it |
| --- | --- |
| [gpu-handoff-and-time-slicing.md](gpu-handoff-and-time-slicing.md) | How the LLM yields GPUs to a game session (preemption), why GPU time-slicing breaks it, the llmkube `count`↔`tensor-split` mechanics, and what you'd have to do to re-enable time-slicing. |
| [gpu-co-location.md](gpu-co-location.md) | Why a real game's app container can't be HW-accelerated yet (same-GPU placement), why this stack disables device selection, and the three real fix paths. |
| [known-issues.md](known-issues.md) | Open quirks: the Test Ball video override, and controller/keyboard input. |
| [upstream-issues.md](upstream-issues.md) | Drafted upstream issues (fenrir/wolf and defilantech/LLMKube) not yet filed. |

> These are committed reference docs. A separate untracked working scratchpad
> (`../fenrir-bringup-handoff.md`) may exist during active sessions; anything
> durable from it belongs here.
