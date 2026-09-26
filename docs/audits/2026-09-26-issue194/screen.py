#!/usr/bin/env python3
"""Screen every exported entity for routing risks; this is not a classifier.

Only direct, stored P31 values are matched. No network requests, inferred
subclass closure, label heuristics, route allocation, or database writes.
The small probe deliberately undercounts reclassification needs. All outputs
are candidates for review, never validated classifications or publishability.
"""

import argparse
import collections
import csv
import hashlib
import json
from pathlib import Path


# Meaning checked against the corresponding wikidata.org/wiki/Q... pages on
# 2026-09-26. These are audit probes, not the proposed production mapping.
PROBES = {
    "Q482994": ("album", "works"),
    "Q11424": ("film", "works"),
    "Q5398426": ("television series", "works"),
    "Q7889": ("video game", "works"),
    "Q215380": ("musical group", "organizations"),
    "Q4022": ("river", "places"),
    "Q8502": ("mountain", "places"),
    "Q3504248": ("inner planet of the Solar System", "nature"),
}
SOURCE_PAGES = {
    "Q4167410": "Wikimedia disambiguation page",
    "Q13406463": "Wikimedia list article",
    "Q15623926": "Wikimedia set index article",
}
KIND_FAMILIES = {
    "person": "people", "organization": "organizations", "place": "places",
    "work": "works", "taxon": "nature", "concept": "concepts", "event": "events",
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("--rows", type=Path, required=True)
    parser.add_argument("--summary", type=Path, required=True)
    args = parser.parse_args()
    with args.input.open(newline="") as source:
        rows = list(csv.DictReader(source))
    assert len({row["object_id"] for row in rows}) == len(rows)
    statuses = collections.Counter()
    reasons = collections.Counter()
    probes = collections.Counter()
    source_types = collections.Counter()
    no_classes = collections.Counter()
    collisions = collections.Counter()
    disambiguation = collections.Counter()
    with args.rows.open("w", newline="") as output:
        writer = csv.DictWriter(output, fieldnames=[
            "object_id", "preferred_label", "stored_kind", "status",
            "candidate_family", "matched_p31", "reason",
        ])
        writer.writeheader()
        for row in rows:
            p31 = set(json.loads(row["instance_of"]))
            p279 = set(json.loads(row["subclass_of"]))
            kind = row["entity_kind"]
            if not p31 and not p279:
                no_classes[kind] += 1
            for qid in p31.intersection(PROBES):
                if kind == "concept":
                    probes[qid] += 1
            for qid in p31.intersection(SOURCE_PAGES):
                source_types[qid] += 1
            flag = row["disambiguation"] == "true"
            typed = "Q4167410" in p31
            disambiguation[f"flag_{flag}_p31_{typed}"] += 1
            matches = sorted(p31.intersection(PROBES))
            families = {PROBES[qid][1] for qid in matches}
            family = ""
            if row["lifecycle_state"] != "active":
                status, reason = "identity_review", row["lifecycle_state"]
            elif p31.intersection(SOURCE_PAGES):
                status, reason = "source_page_review", "source page is not its named subject"
            elif flag:
                status, reason = "metadata_review", "disambiguation flag without matching P31"
            elif len(families) > 1:
                status, reason = "multiple_family_review", "direct probes disagree"
            elif kind in ("event", "edition", "artifact", "other"):
                status, reason = "boundary_review", "page role or family scope requires a decision"
            elif families:
                family = next(iter(families))
                if KIND_FAMILIES.get(kind) != family:
                    status, reason = "reclassification_candidate", "direct P31 differs from kind mapping"
                else:
                    status, reason = "kind_candidate", "kind and direct P31 agree; not semantically verified"
            elif kind == "concept":
                status, reason = "unresolved_concept", "no audited probe establishes a family"
            else:
                family = KIND_FAMILIES.get(kind, "")
                status, reason = "kind_candidate", "existing kind only; not semantically verified"
            statuses[status] += 1
            reasons[reason] += 1
            if family:
                # Case-folded label collisions, NOT normalized URL collisions.
                collisions[(family, row["preferred_label"].casefold())] += 1
            writer.writerow({
                "object_id": row["object_id"], "preferred_label": row["preferred_label"],
                "stored_kind": kind, "status": status, "candidate_family": family,
                "matched_p31": "|".join(matches), "reason": reason,
            })
    summary = {
        "screen_version": "issue194-risk-probe-v1",
        "input_sha256": hashlib.sha256(args.input.read_bytes()).hexdigest(),
        "entity_rows": len(rows), "status_counts": dict(sorted(statuses.items())),
        "reason_counts": dict(sorted(reasons.items())),
        "concept_direct_probes": {
            qid: {"label": label, "candidate_family": family, "count": probes[qid]}
            for qid, (label, family) in PROBES.items()
        },
        "source_page_p31": {qid: {"label": label, "count": source_types[qid]}
                            for qid, label in SOURCE_PAGES.items()},
        "disambiguation_flag_vs_p31": dict(sorted(disambiguation.items())),
        "no_p31_or_p279_by_kind": dict(sorted(no_classes.items())),
        "candidate_family_casefolded_label_collision_groups": sum(n > 1 for n in collisions.values()),
        "candidate_family_casefolded_label_collision_rows": sum(n for n in collisions.values() if n > 1),
        "limitations": [
            "Complete row coverage; no claim of complete semantic classification.",
            "Probes match direct stored P31 only; not an exhaustive vocabulary.",
            "Metadata may be stale or contradictory; no source revision adjudication.",
            "Kind candidates do not establish publishable or indexable pages.",
            "Label collision counts are not slug allocation results.",
        ],
    }
    assert sum(statuses.values()) == len(rows)
    args.summary.write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
