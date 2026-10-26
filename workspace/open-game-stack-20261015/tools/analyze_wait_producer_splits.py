#!/usr/bin/env python3
"""Read an existing wait audit's hashed native prefix; report all producer splits.

No process, GPU, game, configuration or cache operations. Public GPU intervals
can include waits and are not GPU busy time or exclusive critical-path cost.
"""
import argparse
from collections import defaultdict
from decimal import Decimal
import hashlib
import json
from pathlib import Path


def union_ns(intervals):
    total = 0
    end = None
    for a, b in sorted(intervals):
        if b < a:
            raise ValueError("negative interval")
        total += b - max(a, end if end is not None else a) if end is None or b > end else 0
        end = max(b, end if end is not None else b)
    return total


def analyze(audit_path):
    audit = json.loads(audit_path.read_text())
    source = audit["source"]
    start, end = source["nativeReadByteRange"]
    if start != 0 or end > 512 * 1024 * 1024:
        raise ValueError("unsupported prefix range (cap 512 MiB)")
    raw = Path(source["native"]).open("rb")
    try:
        prefix = raw.read(end)
    finally:
        raw.close()
    digest = hashlib.sha256(prefix).hexdigest()
    if len(prefix) != end or digest != source["nativePrefixSHA256"]:
        raise ValueError("native source prefix changed")
    rows = [json.loads(line, parse_float=Decimal) for line in prefix.splitlines()]
    if len(rows) > 400000:
        raise ValueError("row cap exceeded")
    clocks = {r["session"]: r for r in rows if r.get("type") == "clockCalibration"}
    cbs = defaultdict(dict)
    signals = defaultdict(list)
    for row in rows:
        if row.get("type") == "nativeCB":
            cbs[row["nativeCB"]][row["phase"]] = row
        elif row.get("type") == "event" and row.get("phase") == "signal":
            signals[row["event"]].append(row)

    def to_ns(row, key):
        cal = clocks.get(row.get("session"))
        value = row.get(key)
        return round(cal["monotonicNS"] + (value - cal["timeCA"]) * 1000000000) if cal and value and value > 0 else None

    out = []
    for record in audit["hostLogicalSubmissionWaits"]:
        wait = record.get("wait")
        if not wait:
            continue
        begin, finish = wait["beginMachNS"], wait["endMachNS"]
        item = dict(waitSubmission=record["submission"], waitDurationNS=finish-begin, producers=[])
        # Retain all captured >=value encodes. Their existence is ambiguity, not
        # proof of which notification released the host gate.
        alternatives = [r for r in signals[wait["event"]]
                        if r["requested"] >= wait["value"] and to_ns(r, "timeCA") is not None
                        and to_ns(r, "timeCA") <= finish]
        item["capturedAtLeastValueSignalCandidatesBeforeReturn"] = len(alternatives)
        for candidate in record["producerCandidates"]:
            sub = candidate["submission"]
            splits = []
            intervals = []
            for native_id, phases in cbs.items():
                row = phases.get("completed") or phases.get("associated") or next(iter(phases.values()))
                if row.get("logicalSubmit") != sub:
                    continue
                gs, ge = to_ns(row, "gpuStartCA"), to_ns(row, "gpuEndCA")
                valid = gs is not None and ge is not None and ge >= gs
                clipped = max(0, min(finish, ge)-max(begin, gs)) if valid else None
                if valid and clipped:
                    intervals.append((max(begin, gs), min(finish, ge)))
                splits.append(dict(nativeCB=native_id, split=row.get("split"), phases=sorted(phases),
                                   signalCarrier=native_id == candidate["nativeCB"], completed="completed" in phases,
                                   partialPrefix=any(r.get("partialPrefix") for r in phases.values()),
                                   publicGPUIntervalNS=ge-gs if valid else None,
                                   publicGPUIntervalOverlappingWaitNS=clipped))
            splits.sort(key=lambda r: (r["split"] if r["split"] is not None else -1, r["nativeCB"]))
            ordinals = [r["split"] for r in splits if r["split"] is not None]
            item["producers"].append(dict(submission=sub, signalCarrier=candidate["nativeCB"],
                observedSplitCount=len(splits), uniqueSplitOrdinals=len(set(ordinals)) == len(ordinals),
                contiguousObservedOrdinalsFromZero=bool(ordinals) and ordinals == list(range(len(ordinals))),
                allObservedSplitsCompleted=bool(splits) and all(r["completed"] for r in splits),
                clippedPublicGPUIntervalUnionNS=union_ns(intervals), splits=splits))
        out.append(item)
    producers = [p for r in out for p in r["producers"]]
    return dict(schema="wait-producer-splits-v1", source=source, nativePrefixReverified=True,
        summary=dict(waits=len(out), producers=len(producers), observedProducerCBs=sum(p["observedSplitCount"] for p in producers),
                     producersWithMultipleSplits=sum(p["observedSplitCount"] > 1 for p in producers),
                     producersWithContiguousObservedOrdinalsFromZero=sum(p["contiguousObservedOrdinalsFromZero"] for p in producers),
                     producersAllObservedSplitsCompleted=sum(p["allObservedSplitsCompleted"] for p in producers),
                     waitSumOfClippedProducerPublicGPUIntervalUnionsNS=sum(p["clippedPublicGPUIntervalUnionNS"] for p in producers)),
        waits=out, limits=["Observed contiguous ordinals do not prove the final split or capture suffix is complete.",
            "GPU public intervals can include waits and scheduling; union overlap is not exclusive GPU busy cost.",
            "A unique exact signal candidate does not prove the actual notifier; host/external signals may be absent.",
            "NativeRead cumulative producer totals cannot be subtracted from wait or GPU time.",
            "Across-wait interval sums can overlap and are not elapsed frame time."],
        operations=dict(game=False, GPU=False, Wine=False, newSampling=False, productionChange=False))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("audit", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    result = analyze(args.audit)
    with args.output.open("x") as handle:
        json.dump(result, handle, indent=2)
        handle.write("\n")
    print(json.dumps(result["summary"], indent=2))
