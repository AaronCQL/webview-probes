#!/usr/bin/env python3
"""Collect `RESULT <phase> <json>` lines from probe logs into one JSON file.

usage: collect.py out.json name=log [name=log ...]
"""
import json
import sys


def parse(path):
    res = {}
    try:
        lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
    except OSError as e:
        return {"_error": str(e)}
    for line in lines:
        i = line.find("RESULT ")
        if i < 0:
            continue
        parts = line[i + 7 :].split(" ", 1)
        phase = parts[0]
        raw = parts[1] if len(parts) > 1 else ""
        try:
            res[phase] = json.loads(raw)
        except ValueError:
            res[phase] = {"_raw": raw[:2000]}
    res["_done"] = any("PROBE_DONE" in l for l in lines)
    return res


def main():
    out = sys.argv[1]
    allres = {}
    for arg in sys.argv[2:]:
        name, path = arg.split("=", 1)
        allres[name] = parse(path)
    blob = json.dumps(allres, indent=1, sort_keys=True)
    if len(blob) > 1_000_000:
        blob = json.dumps(allres, sort_keys=True)[:1_000_000]
    open(out, "w").write(blob)
    print("==== RESULT block ====")
    for name, res in allres.items():
        for phase, val in res.items():
            print(f"RESULT {name}.{phase} {json.dumps(val, sort_keys=True)[:4000]}")


if __name__ == "__main__":
    main()
