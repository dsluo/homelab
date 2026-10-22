#!/usr/bin/env python3
"""Throughput benchmark for OpenAI-compatible LLM servers.

Runtime-agnostic: every number in the summary is measured client-side from the
SSE stream and the usage block, so llama.cpp, vLLM, SGLang and friends are
scored the same way. Server-reported timings (llama.cpp) are kept as extra
columns, never as the headline.

  llmbench.py run --service ai/qwen3-8-flash-next --label rocm-b11783-ncmoe34
  llmbench.py run --base-url http://127.0.0.1:8080/v1 --suite full --max-context 196608
  llmbench.py compare results/*.json
"""

from __future__ import annotations

import argparse
import concurrent.futures
import datetime as dt
import json
import random
import socket
import statistics
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid
from dataclasses import dataclass
from pathlib import Path

HERE = Path(__file__).resolve().parent
RESULTS = HERE / "results"

# Qwen thinking-mode preset. Sent explicitly so runtimes with different
# defaults sample the same way; --sampling server skips it.
SAMPLING = {"temperature": 1.0, "top_p": 0.95, "top_k": 20, "min_p": 0.0, "seed": 1234}

CODE_PROMPT = (
    "Rewrite the following Python module for clarity and robustness. Keep the "
    "public behaviour identical, add type hints and docstrings, and replace the "
    "ad-hoc error handling with proper exceptions. Return only the complete "
    "rewritten file in one code block.\n\n```python\n{code}\n```"
)
PROSE_PROMPT = (
    "Write a detailed essay of about 1500 words on how the transition from sail "
    "to steam changed maritime trade in the nineteenth century. Cover technology, "
    "economics, labour and geopolitics, with concrete examples."
)
NEEDLE_QUESTION = (
    "\n\nWhat is the access code mentioned in the document above? State the code "
    "first, then summarize the document in about 200 words."
)

# Seeded filler for the long-context cases: random but non-repeating, so n-gram
# drafting and prompt caches get no help from the padding.
WORDS = """
the a of and to in is was for on that with as by at from it his her they this
which be are or had have one not but all were when we there can an their more
if will would about out up into so no time some could them other than then now
only its over also after new most two first well way even because any these
give day years man water long little very still between world school against
house part place while found under never system each much before right through
same where city might country another three land small large food river market
north south east west harbour ship cargo engine coal sail crew port price trade
merchant company route weather season voyage steam iron wood timber grain cotton
wool salt record ledger clerk office letter report account value contract board
council member bridge road station signal line track wagon load measure weight
""".split()


@dataclass(frozen=True)
class Case:
    name: str
    kind: str  # code | prose | needle
    ctx: int = 0  # target prompt tokens for needle cases
    max_tokens: int = 2048


CASES = {
    "code": Case("code", "code"),
    "prose": Case("prose", "prose"),
    "ctx-8k": Case("ctx-8k", "needle", 8192, 1024),
    "ctx-32k": Case("ctx-32k", "needle", 32768, 1024),
    "ctx-64k": Case("ctx-64k", "needle", 65536, 1024),
    "ctx-128k": Case("ctx-128k", "needle", 131072, 1024),
    "ctx-max": Case("ctx-max", "needle", -1, 1024),  # sized from --max-context
}
SUITES = {
    "quick": ["code", "prose"],
    "standard": ["code", "prose", "ctx-8k", "ctx-32k", "ctx-64k"],
    "full": ["code", "prose", "ctx-8k", "ctx-32k", "ctx-64k", "ctx-128k", "ctx-max"],
}
LONG_CTX = 65536  # cases at or above this run --long-reps times


def log(msg: str) -> None:
    print(f"[{dt.datetime.now():%H:%M:%S}] {msg}", file=sys.stderr, flush=True)


def filler(rng: random.Random, n_chars: int) -> str:
    out, size = [], 0
    while size < n_chars:
        para = []
        for _ in range(rng.randint(4, 7)):
            words = [rng.choice(WORDS) for _ in range(rng.randint(8, 20))]
            para.append(" ".join(words).capitalize() + ".")
        text = " ".join(para)
        out.append(text)
        size += len(text) + 2
    return "\n\n".join(out)[:n_chars]


class Client:
    def __init__(self, base_url: str, model: str | None, sampling: dict, extra: dict, timeout: float):
        self.base = base_url.rstrip("/")
        self.model = model
        self.sampling = sampling
        self.extra = extra
        self.timeout = timeout

    def get(self, path: str, base: str | None = None) -> dict:
        with urllib.request.urlopen((base or self.base) + path, timeout=30) as r:
            return json.load(r)

    def wait_ready(self, wait: float) -> None:
        deadline = time.monotonic() + wait
        while True:
            try:
                models = self.get("/models")
                if not self.model:
                    self.model = models["data"][0]["id"]
                return
            except (urllib.error.URLError, OSError, KeyError, IndexError) as e:
                if time.monotonic() > deadline:
                    raise SystemExit(f"server not ready after {wait:.0f}s: {e}")
                time.sleep(5)

    def chat(self, prompt: str, max_tokens: int) -> dict:
        body = {
            "model": self.model,
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": max_tokens,
            "stream": True,
            "stream_options": {"include_usage": True},
            **self.sampling,
            **self.extra,
        }
        req = urllib.request.Request(
            self.base + "/chat/completions",
            data=json.dumps(body).encode(),
            headers={"Content-Type": "application/json", "Authorization": "Bearer none"},
        )
        res = {"content": "", "reasoning": "", "chunks": 0, "usage": None, "timings": None, "finish": None}
        t0 = time.monotonic()
        t_first = t_last = None
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                for raw in resp:
                    line = raw.decode("utf-8", "replace").strip()
                    if not line.startswith("data:"):
                        continue
                    data = line[5:].strip()
                    if data == "[DONE]":
                        break
                    chunk = json.loads(data)
                    res["usage"] = chunk.get("usage") or res["usage"]
                    res["timings"] = chunk.get("timings") or res["timings"]
                    for choice in chunk.get("choices") or []:
                        delta = choice.get("delta") or {}
                        text = delta.get("content") or ""
                        think = delta.get("reasoning_content") or delta.get("reasoning") or ""
                        if text or think:
                            now = time.monotonic()
                            t_first = t_first or now
                            t_last = now
                            res["chunks"] += 1
                            res["content"] += text
                            res["reasoning"] += think
                        res["finish"] = choice.get("finish_reason") or res["finish"]
        except (urllib.error.URLError, OSError, json.JSONDecodeError) as e:
            detail = e.read().decode()[:300] if isinstance(e, urllib.error.HTTPError) else ""
            res["error"] = f"{e} {detail}".strip()
        res["t_start"], res["t_first"], res["t_last"], res["t_end"] = t0, t_first, t_last, time.monotonic()
        return res


def metrics(res: dict) -> dict:
    usage = res.get("usage") or {}
    prompt = usage.get("prompt_tokens")
    completion = usage.get("completion_tokens") or res["chunks"]
    m = {"prompt_tokens": prompt, "completion_tokens": completion, "finish": res["finish"]}
    if res.get("error"):
        m["error"] = res["error"]
    if res["t_first"] is not None:
        ttft = res["t_first"] - res["t_start"]
        span = res["t_last"] - res["t_first"]
        m["ttft_s"] = round(ttft, 3)
        m["e2e_s"] = round(res["t_end"] - res["t_start"], 3)
        m["prefill_tps"] = round(prompt / ttft, 1) if prompt else None
        m["decode_tps"] = round((completion - 1) / span, 2) if span > 0 and completion > 1 else None
    t = res.get("timings")
    if t:
        m["srv_prefill_tps"] = round(t.get("prompt_per_second") or 0, 1)
        m["srv_decode_tps"] = round(t.get("predicted_per_second") or 0, 2)
        m["srv_prompt_n"] = t.get("prompt_n")
        if t.get("draft_n"):
            m["draft_accept"] = round(t["draft_n_accepted"] / t["draft_n"], 3)
    return m


class Bench:
    def __init__(self, client: Client, args: argparse.Namespace):
        self.c = client
        self.args = args
        self.code = (HERE / "corpus" / "code.py.txt").read_text()
        self.chars_per_token = None
        self.base_tokens = 0

    def nonce(self) -> str:
        # First line differs per request so no runtime can serve it from a prefix cache.
        return f"Request {uuid.uuid4()}.\n\n"

    def calibrate(self) -> None:
        rng = random.Random(0)
        body = filler(rng, 32000)
        a = metrics(self.c.chat(self.nonce() + NEEDLE_QUESTION, 1))
        b = metrics(self.c.chat(self.nonce() + body + NEEDLE_QUESTION, 1))
        if not (a.get("prompt_tokens") and b.get("prompt_tokens")):
            raise SystemExit(f"calibration needs usage.prompt_tokens; got {a} / {b}")
        self.base_tokens = a["prompt_tokens"]
        self.chars_per_token = len(body) / (b["prompt_tokens"] - a["prompt_tokens"])
        log(f"calibrated: {self.chars_per_token:.2f} chars/token, {self.base_tokens} template tokens")

    def prompt(self, case: Case, rng: random.Random) -> tuple[str, str | None]:
        if case.kind == "code":
            return self.nonce() + CODE_PROMPT.format(code=self.code), None
        if case.kind == "prose":
            return self.nonce() + PROSE_PROMPT, None
        target = case.ctx
        if target < 0:
            target = self.args.max_context - case.max_tokens - 512
        n_chars = int((target - self.base_tokens) * self.chars_per_token)
        code = f"{rng.choice('BCDFGHJKLMNPQRSTVWXZ')}{rng.randint(1000, 9999)}-{rng.choice(WORDS).upper()}"
        needle = f"\n\nNote for the reader: the access code is {code}. Remember it.\n\n"
        pad = filler(rng, n_chars)
        cut = int(len(pad) * self.args.needle_depth)
        cut = pad.rfind(" ", 0, cut) if cut else 0
        return self.nonce() + pad[:cut] + needle + pad[cut:] + NEEDLE_QUESTION, code

    def run_one(self, case: Case, rep: int, rng: random.Random) -> list[dict]:
        max_tokens = self.args.max_tokens or case.max_tokens
        jobs = [self.prompt(case, rng) for _ in range(self.args.concurrency)]
        with concurrent.futures.ThreadPoolExecutor(len(jobs)) as pool:
            raws = list(pool.map(lambda j: self.c.chat(j[0], max_tokens), jobs))
        wall = max(r["t_end"] for r in raws) - min(r["t_start"] for r in raws)
        out = []
        for i, (raw, (_, code)) in enumerate(zip(raws, jobs)):
            m = {"case": case.name, "rep": rep, "slot": i, **metrics(raw)}
            if code:
                if code in raw["content"]:
                    m["needle"] = "pass"
                elif code in raw["reasoning"]:
                    m["needle"] = "reasoning-only"
                else:
                    m["needle"] = "truncated" if raw["finish"] == "length" else "fail"
            if len(raws) > 1:
                m["batch_decode_tps"] = round(sum(metrics(r)["completion_tokens"] for r in raws) / wall, 2)
            out.append(m)
        return out

    def run(self) -> list[dict]:
        names = self.args.cases.split(",") if self.args.cases else SUITES[self.args.suite]
        cases = [CASES[n] for n in names]
        if any(c.ctx < 0 for c in cases) and not self.args.max_context:
            log("skipping ctx-max: pass --max-context (per-slot context) to run it")
            cases = [c for c in cases if c.ctx >= 0]
        if any(c.kind == "needle" for c in cases):
            self.calibrate()
        if self.args.warmup:
            log("warmup (discarded)")
            self.c.chat(self.nonce() + CODE_PROMPT.format(code=self.code), 256)
        rng = random.Random(self.args.seed)
        runs = []
        for case in cases:
            reps = self.args.long_reps if case.ctx < 0 or case.ctx >= LONG_CTX else self.args.reps
            for rep in range(reps):
                log(f"{case.name} rep {rep + 1}/{reps}")
                for m in self.run_one(case, rep, rng):
                    log("  " + ", ".join(f"{k}={v}" for k, v in m.items() if k not in ("case", "rep")))
                    runs.append(m)
        return runs


def med(vals: list) -> float | None:
    vals = [v for v in vals if isinstance(v, (int, float))]
    return round(statistics.median(vals), 2) if vals else None


def summarize(runs: list[dict]) -> list[dict]:
    rows = []
    for name in dict.fromkeys(r["case"] for r in runs):
        rs = [r for r in runs if r["case"] == name]
        row = {
            "case": name,
            "n": len(rs),
            "errors": sum(1 for r in rs if r.get("error")),
            "prompt_tok": med([r.get("prompt_tokens") for r in rs]),
            "out_tok": med([r.get("completion_tokens") for r in rs]),
            "ttft_s": med([r.get("ttft_s") for r in rs]),
            "prefill_tps": med([r.get("prefill_tps") for r in rs]),
            "decode_tps": med([r.get("decode_tps") for r in rs]),
            "decode_min": min((r["decode_tps"] for r in rs if r.get("decode_tps")), default=None),
            "decode_max": max((r["decode_tps"] for r in rs if r.get("decode_tps")), default=None),
            "batch_tps": med([r.get("batch_decode_tps") for r in rs]),
            "srv_prefill": med([r.get("srv_prefill_tps") for r in rs]),
            "srv_decode": med([r.get("srv_decode_tps") for r in rs]),
            "draft_acc": med([r.get("draft_accept") for r in rs]),
        }
        needles = [r["needle"] for r in rs if "needle" in r]
        if needles:
            # A thinking model often recalls the code in its reasoning before the
            # output cap; that is still recall.
            recalled = sum(1 for n in needles if n in ("pass", "reasoning-only"))
            row["needle"] = f"{recalled}/{len(needles)}"
        rows.append(row)
    return rows


def table(rows: list[dict]) -> str:
    cols = [c for c in dict.fromkeys(k for r in rows for k in r) if any(r.get(c) not in (None, 0) or c == "case" for r in rows)]
    lines = ["| " + " | ".join(cols) + " |", "|" + "---|" * len(cols)]
    for r in rows:
        lines.append("| " + " | ".join("" if r.get(c) is None else str(r.get(c)) for c in cols) + " |")
    return "\n".join(lines)


def port_forward(target: str) -> tuple[subprocess.Popen, str]:
    ns, _, svc = target.rpartition("/")
    ns = ns or "ai"
    remote = subprocess.check_output(
        ["kubectl", "-n", ns, "get", "svc", svc, "-o", "jsonpath={.spec.ports[0].port}"], text=True
    ).strip()
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        local = s.getsockname()[1]
    proc = subprocess.Popen(
        ["kubectl", "-n", ns, "port-forward", f"svc/{svc}", f"{local}:{remote}"],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    )
    line = proc.stdout.readline()
    if "Forwarding" not in line:
        proc.kill()
        raise SystemExit(f"port-forward failed: {line.strip()}")
    return proc, f"http://127.0.0.1:{local}/v1"


def collect_meta(client: Client, args: argparse.Namespace) -> dict:
    meta = {
        "label": args.label,
        "note": args.note,
        "started": dt.datetime.now().astimezone().isoformat(timespec="seconds"),
        "base_url": client.base,
        "service": args.service,
        "model": client.model,
        "suite": args.cases or args.suite,
        "concurrency": args.concurrency,
        "sampling": client.sampling,
        "extra_body": client.extra,
        "needle_depth": args.needle_depth,
    }
    root = client.base.removesuffix("/v1")
    try:
        props = client.get("/props", base=root)
        meta["llamacpp"] = {
            "build": props.get("build_info"),
            "n_ctx": (props.get("default_generation_settings") or {}).get("n_ctx"),
            "total_slots": props.get("total_slots"),
        }
    except (urllib.error.URLError, OSError, ValueError):
        pass
    if args.service:
        ns, _, svc = args.service.rpartition("/")
        try:
            isvc = subprocess.check_output(
                ["kubectl", "-n", ns or "ai", "get", "inferenceservice", svc, "-o", "json"],
                text=True, stderr=subprocess.DEVNULL,
            )
            meta["isvc_spec"] = json.loads(isvc)["spec"]
        except (subprocess.CalledProcessError, FileNotFoundError):
            pass
    return meta


def cmd_run(args: argparse.Namespace) -> None:
    pf = None
    if args.service:
        pf, base = port_forward(args.service)
    elif args.base_url:
        base = args.base_url
    else:
        raise SystemExit("pass --service or --base-url")
    try:
        sampling = {} if args.sampling == "server" else dict(SAMPLING)
        client = Client(base, args.model, sampling, json.loads(args.extra_body), args.timeout)
        log(f"waiting for {base}")
        client.wait_ready(args.wait)
        meta = collect_meta(client, args)
        log(f"model {client.model}; suite {meta['suite']}")
        runs = Bench(client, args).run()
    finally:
        if pf:
            pf.terminate()
    rows = summarize(runs)
    out = args.out or RESULTS / f"{dt.datetime.now():%Y%m%d-%H%M%S}-{args.label}.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps({"meta": meta, "summary": rows, "runs": runs}, indent=2))
    print(f"\n## {args.label}\n\n{table(rows)}\n\nsaved {out}")


def cmd_compare(args: argparse.Namespace) -> None:
    docs = [json.loads(Path(p).read_text()) for p in args.files]
    labels = [d["meta"]["label"] for d in docs]
    cases = list(dict.fromkeys(r["case"] for d in docs for r in d["summary"]))
    for metric in args.metrics.split(","):
        rows = []
        for case in cases:
            row = {"case": case}
            for label, d in zip(labels, docs):
                hit = next((r for r in d["summary"] if r["case"] == case), {})
                row[label] = hit.get(metric)
            rows.append(row)
        print(f"\n### {metric}\n\n{table(rows)}")


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    r = sub.add_parser("run", help="benchmark one server")
    r.add_argument("--service", help="[ns/]svc to port-forward to (ns defaults to ai)")
    r.add_argument("--base-url", help="OpenAI-compatible base URL ending in /v1")
    r.add_argument("--label", required=True, help="names the result file, e.g. rocm-b11783-ncmoe34")
    r.add_argument("--note", default="", help="free text stored with the result")
    r.add_argument("--model", help="model id to send (default: first from /v1/models)")
    r.add_argument("--suite", choices=SUITES, default="standard")
    r.add_argument("--cases", help=f"comma list overriding --suite: {','.join(CASES)}")
    r.add_argument("--max-context", type=int, help="per-slot context; sizes ctx-max")
    r.add_argument("--max-tokens", type=int, help="override every case's output cap")
    r.add_argument("--reps", type=int, default=3)
    r.add_argument("--long-reps", type=int, default=1, help=f"reps for cases >= {LONG_CTX} tokens")
    r.add_argument("--concurrency", type=int, default=1, help="parallel requests per rep")
    r.add_argument("--needle-depth", type=float, default=0.5)
    r.add_argument("--sampling", choices=["preset", "server"], default="preset")
    r.add_argument("--extra-body", default="{}", help='JSON merged into each request, e.g. \'{"chat_template_kwargs":{"enable_thinking":false}}\'')
    r.add_argument("--no-warmup", dest="warmup", action="store_false")
    r.add_argument("--seed", type=int, default=0, help="filler and needle RNG")
    r.add_argument("--wait", type=float, default=1800, help="seconds to wait for the server to load")
    r.add_argument("--timeout", type=float, default=7200, help="per-request seconds")
    r.add_argument("--out", type=Path)
    r.set_defaults(func=cmd_run)

    c = sub.add_parser("compare", help="side-by-side medians from result files")
    c.add_argument("files", nargs="+")
    c.add_argument("--metrics", default="decode_tps,prefill_tps,ttft_s,needle")
    c.set_defaults(func=cmd_compare)

    args = p.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
