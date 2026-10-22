# llm-bench

Throughput benchmark for any OpenAI-compatible server (llama.cpp, vLLM, SGLang,
Strata, NInfer, ...). Stdlib Python only.

```sh
just llm-bench run --service ai/qwen3-8-flash-next --label rocm-b11783-ncmoe34 --suite full --max-context 196608
just llm-bench compare scripts/llm-bench/results/*.json
```

`--service` port-forwards to the Service directly. For a ModelPool member,
go through the router-proxy instead (`--base-url` plus `--model <isvc>`) once
the member is resident: the pool counts idleness from router traffic, so a run
that bypasses it gets reclaimed after `reclaimAfter`. Never go through LiteLLM,
and never start a run on a non-resident member, or the swap lands in the numbers.
Results land in `results/` (gitignored), one JSON per run with the
InferenceService spec, llama.cpp build and every request.

## What it measures

| case | prompt | out cap | reps |
|---|---|---|---|
| `code` | rewrite of `corpus/code.py.txt` (~1.8k tok) | 2048 | 3 |
| `prose` | short essay prompt | 2048 | 3 |
| `ctx-8k` ... `ctx-128k` | seeded filler + needle at `--needle-depth` | 1024 | 3 below 64k, else 1 |
| `ctx-max` | as above, sized to `--max-context` | 1024 | 1 |

Suites: `quick` (code, prose), `standard` (+ 8k/32k/64k), `full` (+ 128k, max).

Headline numbers are client-side so runtimes compare like for like:

- `prefill_tps` = prompt tokens / time to first token (content or reasoning)
- `decode_tps` = (completion tokens - 1) / time from first to last token
- `batch_tps` = all completion tokens / wall time, with `--concurrency` > 1
- `needle` = runs that recalled the code, in the answer or the reasoning

`srv_*` and `draft_acc` come from llama.cpp's `timings` and are absent on
other runtimes. Expect client prefill to read a little low on short prompts.

## Keeping runs comparable

- Every prompt starts with a fresh UUID, so no prefix cache helps.
- Sampling is pinned to Qwen's thinking preset (temp 1.0, top-p 0.95, top-k
  20, seed 1234) unless `--sampling server`. Speculative acceptance moves with
  sampling, so keep this fixed across runtimes.
- Reasoning effort is server config on llama.cpp; on other runtimes pass it
  with `--extra-body`, e.g. `'{"chat_template_kwargs":{"reasoning_effort":"xhigh"}}'`.
- `--max-context` is per slot: llama.cpp divides `contextSize` by `parallelSlots`.
- The first request after a load pays the mmap fault-in. The default warmup
  absorbs part of it; for hybrid MoE, run `--suite quick` once before the real run.
- Nothing else on the GPU or contending for talos1 RAM during a run. VRAM and
  page-cache refaults are not captured; read them from Grafana for the run window.
