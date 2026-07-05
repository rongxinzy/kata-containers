#!/usr/bin/env python3
"""Parse vllm bench serve logs from concurrent benchmark."""
import re
import sys
from pathlib import Path

LOGS = {
    "Group 1": "/root/benchmark-group1.log",
    "Group 2": "/root/benchmark-group2.log",
    "Group 3": "/root/benchmark-group3.log",
    "Group 4": "/root/benchmark-group4.log",
    "Docker-1": "/root/benchmark-vllm-host-d1.log",
    "Docker-2": "/root/benchmark-vllm-host-d2.log",
}

METRIC_RE = re.compile(
    r"(?:Mean|median)\s+(TTFT|TPOT|IT)\s+\(ms\):\s+([\d.]+)",
    re.IGNORECASE,
)
THROUGHPUT_RE = re.compile(
    r"(Output token throughput|Request throughput|Total token throughput).*?:\s+([\d.]+)",
    re.IGNORECASE,
)
TEST_HEADER_RE = re.compile(
    r"Starting test: random-input-len=(\d+), random-output-len=(\d+), num-prompts=(\d+)"
)


def parse_log(path: str):
    text = Path(path).read_text(encoding="utf-8", errors="ignore")
    results = []
    current = None
    for line in text.splitlines():
        m = TEST_HEADER_RE.search(line)
        if m:
            if current:
                results.append(current)
            current = {
                "input_len": int(m.group(1)),
                "output_len": int(m.group(2)),
                "num_prompts": int(m.group(3)),
                "output_tok_s": None,
                "request_tok_s": None,
                "total_tok_s": None,
                "mean_ttft": None,
                "mean_tpot": None,
                "mean_itl": None,
            }
            continue
        if not current:
            continue
        tm = THROUGHPUT_RE.search(line)
        if tm:
            key = tm.group(1).lower().replace(" ", "_")
            val = float(tm.group(2))
            if "output_token" in key:
                current["output_tok_s"] = val
            elif "request" in key:
                current["request_tok_s"] = val
            elif "total_token" in key:
                current["total_tok_s"] = val
            continue
        mm = METRIC_RE.search(line)
        if mm:
            metric = mm.group(1).upper()
            val = float(mm.group(2))
            if metric == "TTFT":
                current["mean_ttft"] = val
            elif metric == "TPOT":
                current["mean_tpot"] = val
            elif metric == "IT":
                current["mean_itl"] = val
    if current:
        results.append(current)
    return results


def main():
    all_data = {}
    for name, path in LOGS.items():
        if not Path(path).exists():
            print(f"WARN: {name} log not found: {path}", file=sys.stderr)
            continue
        all_data[name] = parse_log(path)
        print(f"{name}: parsed {len(all_data[name])} test cases", file=sys.stderr)

    # Header
    header = ["input_len", "output_len", "num_prompts"] + [
        f"{name}_{col}"
        for col in ["output_tok_s", "mean_ttft", "mean_tpot"]
        for name in LOGS.keys()
    ]
    print("| " + " | ".join(header) + " |")
    print("| " + " | ".join(["---"] * len(header)) + " |")

    # Assume all logs have same test cases in same order
    first = next(iter(all_data.values()))
    for i, case in enumerate(first):
        row = [case["input_len"], case["output_len"], case["num_prompts"]]
        for col in ["output_tok_s", "mean_ttft", "mean_tpot"]:
            for name in LOGS.keys():
                data = all_data.get(name, [])
                val = data[i].get(col) if i < len(data) else None
                row.append(f"{val:.1f}" if val is not None else "-")
        print("| " + " | ".join(str(x) for x in row) + " |")


if __name__ == "__main__":
    main()
