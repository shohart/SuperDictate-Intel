#!/usr/bin/env python3
"""Benchmark runner: starts llama-server per model config, runs corpus suites,
saves raw outputs + timing. Usage: run_model.py --config <model.json> [--suites correction,rewrite,stress] [--runs N]"""
import argparse, json, os, re, signal, subprocess, sys, time, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LLAMA = os.path.join(ROOT, "runtime", "build", "bin", "llama-server")
NOPROXY = urllib.request.build_opener(urllib.request.ProxyHandler({}))

def read_jsonl(p):
    with open(p, encoding="utf-8") as f:
        return [json.loads(l) for l in f if l.strip()]

def post_stream(url, payload, timeout=900):
    """Streaming POST; returns (content, ttft_s, total_s, usage)."""
    req = urllib.request.Request(url, json.dumps(payload).encode(), {"Content-Type": "application/json"})
    t0 = time.monotonic()
    ttft = None
    content = ""
    usage = {}
    with NOPROXY.open(req, timeout=timeout) as r:
        for raw in r:
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                break
            try:
                chunk = json.loads(data)
            except Exception:
                continue
            if chunk.get("usage"):
                usage = chunk["usage"]
            for ch in chunk.get("choices", []):
                delta = ch.get("delta", {}).get("content")
                if delta:
                    if ttft is None:
                        ttft = time.monotonic() - t0
                    content += delta
                elif ch.get("message", {}).get("content") and ttft is None:
                    ttft = time.monotonic() - t0
                    content += ch["message"]["content"]
    total = time.monotonic() - t0
    return content, ttft if ttft is not None else total, total, usage

def wait_health(port, proc, timeout=300):
    t0 = time.monotonic()
    while time.monotonic() - t0 < timeout:
        if proc.poll() is not None:
            return False
        try:
            with NOPROXY.open(f"http://127.0.0.1:{port}/health", timeout=3) as r:
                if r.status == 200:
                    return True
        except Exception:
            pass
        time.sleep(1.0)
    return False

def parse_vram(logpath):
    """Peak Vulkan buffer usage from server log (MiB)."""
    total = 0.0
    try:
        with open(logpath, encoding="utf-8", errors="replace") as f:
            txt = f.read()
        for m in re.finditer(r"Vulkan0 (?:compute|model|KV) buffer size =\s*([\d.]+) MiB", txt):
            pass  # take max-of-sums below instead
        bufs = {}
        for m in re.finditer(r"(\w+)\s+(compute|model|KV|Host) buffer size =\s*([\d.]+) MiB", txt):
            key = m.group(1) + " " + m.group(2)
            bufs[key] = max(bufs.get(key, 0.0), float(m.group(3)))
        total = sum(v for k, v in bufs.items() if k.startswith("Vulkan0"))
    except Exception:
        pass
    return round(total, 1)

def peak_rss_mb(pid_marker, logpath):
    return None  # reserved

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    ap.add_argument("--suites", default="correction,rewrite,stress")
    ap.add_argument("--runs", type=int, default=1, help="quality passes over full corpus")
    ap.add_argument("--perf-runs", type=int, default=3, help="repeat runs over perf subset")
    ap.add_argument("--perf-subset", type=int, default=12, help="first N items of each suite for latency medians")
    args = ap.parse_args()

    cfg = json.load(open(args.config, encoding="utf-8"))
    name = cfg["name"]
    port = cfg.get("port", 8399)
    outdir = os.path.join(ROOT, "results", "raw", name)
    os.makedirs(outdir, exist_ok=True)
    logpath = os.path.join(ROOT, "logs", f"{name}.server.log")

    cmd = [LLAMA, "-m", cfg["model"], "--port", str(port), "-c", str(cfg.get("ctx", 4096)),
           "-np", "1", "--jinja", "--metrics", "--seed", "20260821",
           "-ngl", str(cfg.get("gpu_layers", 999))]
    if cfg.get("lora"):
        cmd += ["--lora-scaled", f"{cfg['lora']}:{cfg.get('lora_scale', 1.0)}"]
    cmd += cfg.get("extra_args", [])

    env = os.environ.copy()
    env["DYLD_LIBRARY_PATH"] = os.path.join(ROOT, "runtime", "build", "bin")
    with open(logpath, "w") as lf:
        proc = subprocess.Popen(cmd, stdout=lf, stderr=subprocess.STDOUT, env=env)
    try:
        if not wait_health(port, proc):
            print(f"FAIL {name}: server did not become healthy, see {logpath}", file=sys.stderr)
            sys.exit(2)
        # warm-up
        post_stream(f"http://127.0.0.1:{port}/v1/chat/completions",
                    {"messages": [{"role": "user", "content": "Привет."}], "temperature": 0,
                     "max_tokens": 8, "stream": True, "stream_options": {"include_usage": True}})

        sys_prompt = open(os.path.join(ROOT, "prompts", cfg.get("prompt", "correction.txt")), encoding="utf-8").read().strip()
        suites = args.suites.split(",")
        for suite in suites:
            corpus = read_jsonl(os.path.join(ROOT, "corpus", f"{suite}.jsonl"))
            if suite == "rewrite":
                sys_p = open(os.path.join(ROOT, "prompts", "rewrite.txt"), encoding="utf-8").read().strip()
            else:
                sys_p = sys_prompt
            results = []
            n_runs = max(1, args.runs)
            for run in range(n_runs):
                for i, case in enumerate(corpus):
                    key = case["id"]
                    msgs = [{"role": "system", "content": sys_p}]
                    if suite == "rewrite":
                        user = case["input"] + "\n\nРежим: " + case["mode"]
                    elif suite == "stress":
                        user = case["input"]
                    else:
                        user = case["input"]
                    payload = {"messages": msgs + [{"role": "user", "content": user}],
                               "temperature": 0, "seed": 20260821,
                               "max_tokens": cfg.get("max_tokens", {}).get(suite, 1200),
                               "stream": True, "stream_options": {"include_usage": True}}
                    if cfg.get("thinking_off"):
                        payload["chat_template_kwargs"] = {"enable_thinking": False}
                    try:
                        content, ttft, total, usage = post_stream(f"http://127.0.0.1:{port}/v1/chat/completions", payload)
                    except Exception as e:
                        content, ttft, total, usage = f"__ERROR__ {e}", -1, -1, {}
                    rec = {"id": key, "run": run, "input": case["input"], "output": content,
                           "ttft_s": round(ttft, 3), "total_s": round(total, 3),
                           "prompt_tokens": usage.get("prompt_tokens"), "completion_tokens": usage.get("completion_tokens")}
                    if suite != "correction":
                        rec["mode"] = case.get("mode", case.get("kind", ""))
                    results.append(rec)
                    if (i + 1) % 10 == 0:
                        print(f"  {name}/{suite} run{run}: {i+1}/{len(corpus)}", flush=True)
            with open(os.path.join(outdir, f"{suite}.jsonl"), "w", encoding="utf-8") as f:
                for r in results:
                    f.write(json.dumps(r, ensure_ascii=False) + "\n")
            print(f"DONE {name}/{suite}: {len(results)} records", flush=True)
    finally:
        proc.send_signal(signal.SIGTERM)
        try:
            proc.wait(timeout=10)
        except Exception:
            proc.kill()
    vram = parse_vram(logpath)
    meta = {"model": name, "vram_mib_reported": vram, "model_file_bytes": os.path.getsize(cfg["model"])}
    with open(os.path.join(outdir, "server_meta.json"), "w") as f:
        json.dump(meta, f, indent=2)
    print(f"OK {name} vram_mib={vram}")

if __name__ == "__main__":
    main()
