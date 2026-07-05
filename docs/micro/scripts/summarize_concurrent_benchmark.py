#!/usr/bin/env python3
"""Generate summary tables from parsed concurrent benchmark data."""
import re
from pathlib import Path

LOGS = {
    "Group 1": "/root/benchmark-group1.log",
    "Group 2": "/root/benchmark-group2.log",
    "Group 3": "/root/benchmark-group3.log",
    "Group 4": "/root/benchmark-group4.log",
    "Docker-1": "/root/benchmark-vllm-host-d1.log",
    "Docker-2": "/root/benchmark-vllm-host-d2.log",
}

TEST_HEADER_RE = re.compile(
    r"Starting test: random-input-len=(\d+), random-output-len=(\d+), num-prompts=(\d+)"
)
OUTPUT_RE = re.compile(r"Output token throughput.*?:\s+([\d.]+)")
TTFT_RE = re.compile(r"Mean TTFT \(ms\):\s+([\d.]+)")
TPOT_RE = re.compile(r"Mean TPOT \(ms\):\s+([\d.]+)")


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
                "mean_ttft": None,
                "mean_tpot": None,
            }
            continue
        if not current:
            continue
        if (r := OUTPUT_RE.search(line)) and current["output_tok_s"] is None:
            current["output_tok_s"] = float(r.group(1))
        elif (r := TTFT_RE.search(line)) and current["mean_ttft"] is None:
            current["mean_ttft"] = float(r.group(1))
        elif (r := TPOT_RE.search(line)) and current["mean_tpot"] is None:
            current["mean_tpot"] = float(r.group(1))
    if current:
        results.append(current)
    return results


def main():
    data = {name: parse_log(path) for name, path in LOGS.items()}
    cases = list({(r["input_len"], r["output_len"], r["num_prompts"]) for r in next(iter(data.values()))})
    cases.sort()

    print("### Output token throughput (tok/s)")
    print()
    print("| input_len | output_len | num_prompts | Group 1 | Group 2 | Group 3 | Group 4 | Docker-1 | Docker-2 |")
    print("|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    for il, ol, np in cases:
        row = [il, ol, np]
        for name in LOGS:
            r = next((x for x in data[name] if (x["input_len"], x["output_len"], x["num_prompts"]) == (il, ol, np)), None)
            row.append(f"{r['output_tok_s']:.1f}" if r and r["output_tok_s"] is not None else "-")
        print("| " + " | ".join(str(x) for x in row) + " |")

    print()
    print("### Mean TTFT (ms)")
    print()
    print("| input_len | output_len | num_prompts | Group 1 | Group 2 | Group 3 | Group 4 | Docker-1 | Docker-2 |")
    print("|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    for il, ol, np in cases:
        row = [il, ol, np]
        for name in LOGS:
            r = next((x for x in data[name] if (x["input_len"], x["output_len"], x["num_prompts"]) == (il, ol, np)), None)
            row.append(f"{r['mean_ttft']:.1f}" if r and r["mean_ttft"] is not None else "-")
        print("| " + " | ".join(str(x) for x in row) + " |")

    print()
    print("### Mean TPOT (ms)")
    print()
    print("| input_len | output_len | num_prompts | Group 1 | Group 2 | Group 3 | Group 4 | Docker-1 | Docker-2 |")
    print("|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    for il, ol, np in cases:
        row = [il, ol, np]
        for name in LOGS:
            r = next((x for x in data[name] if (x["input_len"], x["output_len"], x["num_prompts"]) == (il, ol, np)), None)
            row.append(f"{r['mean_tpot']:.1f}" if r and r["mean_tpot"] is not None else "-")
        print("| " + " | ".join(str(x) for x in row) + " |")

    # Summary per group/instance
    print()
    print("### Average output token throughput per instance")
    print()
    print("| Instance | Avg output tok/s | Min | Max |")
    print("|---|---:|---:|---:|")
    for name in LOGS:
        vals = [r["output_tok_s"] for r in data[name] if r["output_tok_s"] is not None]
        if vals:
            print(f"| {name} | {sum(vals)/len(vals):.1f} | {min(vals):.1f} | {max(vals):.1f} |")

    print()
    print("### Aggregate output token throughput")
    print()
    print("| input_len | output_len | num_prompts | Kata 4 groups sum | Docker 2 instances sum | Total 48 GPU |")
    print("|---:|---:|---:|---:|---:|---:|")
    for il, ol, np in cases:
        kata_sum = 0.0
        docker_sum = 0.0
        for name in LOGS:
            r = next((x for x in data[name] if (x["input_len"], x["output_len"], x["num_prompts"]) == (il, ol, np)), None)
            if r and r["output_tok_s"] is not None:
                if name.startswith("Group"):
                    kata_sum += r["output_tok_s"]
                else:
                    docker_sum += r["output_tok_s"]
        total = kata_sum + docker_sum
        print(f"| {il} | {ol} | {np} | {kata_sum:.1f} | {docker_sum:.1f} | {total:.1f} |")


if __name__ == "__main__":
    main()
