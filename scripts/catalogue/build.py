#!/usr/bin/env python3
"""Builds the paper catalogue from the exam boards' own public listings (docs/CATALOGUE.md).

    python3 scripts/catalogue/build.py            # every board
    python3 scripts/catalogue/build.py aqa ocr    # just these

Writes catalogue/index.json (boards and specs, no documents) and catalogue/specs/<spec id>.json (one
spec's documents). Links and facts only: the apps download each paper from the board's own site onto
the device. A board whose site fails keeps its previous files, so a bad week never empties it.
"""
import json, os, sys, datetime
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import aqa, ocr, wjec, cie, pearson  # noqa: E402
from common import dedupe, sort_docs  # noqa: E402

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "catalogue")
FINDERS = {"aqa": aqa.find, "ocr": ocr.find, "eduqas": wjec.find_eduqas, "wjec": wjec.find_wjec, "cie": cie.find,
           "pearson": pearson.find}
# Boards that can't be read automatically, and why (shown in the app so it can say so).
NOT_LISTED = {
    "ccea": "CCEA's website blocks automated requests.",
}


def load_index():
    try:
        return json.load(open(os.path.join(ROOT, "index.json")))
    except (OSError, ValueError):
        return {"boards": [], "specs": []}


def summary(spec):
    years = [d["year"] for d in spec["docs"] if d.get("year")]
    qps = sum(1 for d in spec["docs"] if d["type"] == "qp")
    return {k: spec[k] for k in ("id", "board", "qualification", "subject", "code", "level", "url")} | {
        "papers": qps, "files": len(spec["docs"]), "years": [min(years), max(years)] if years else []}


def main(names):
    os.makedirs(os.path.join(ROOT, "specs"), exist_ok=True)
    old = load_index()
    boards = {b["id"]: b for b in old.get("boards", [])}
    specs = {s["id"]: s for s in old.get("specs", [])}
    for s in specs.values():  # older indexes counted files as "docs"
        if isinstance(s.get("docs"), int):
            s["files"] = s.pop("docs")
    for name in names:
        try:
            board, found = FINDERS[name]()
        except Exception as e:  # noqa: BLE001
            print(f"{name}: failed ({e}); keeping the previous listing")
            continue
        found = [s for s in found if any(d["type"] == "qp" for d in s["docs"])]
        if not found:
            print(f"{name}: nothing found; keeping the previous listing")
            continue
        for sid in [s for s, v in specs.items() if v["board"] == name]:
            specs.pop(sid)
            try:
                os.remove(os.path.join(ROOT, "specs", f"{sid}.json"))
            except OSError:
                pass
        boards[name] = board
        for s in found:
            s["docs"] = sort_docs(dedupe(s["docs"]))
            with open(os.path.join(ROOT, "specs", f"{s['id']}.json"), "w") as f:
                json.dump(s, f, separators=(",", ":"), ensure_ascii=False)
            specs[s["id"]] = summary(s)
        print(f"{name}: {len(found)} specs, {sum(len(s['docs']) for s in found)} documents")
    index = {"v": 2, "updated": old.get("updated") or datetime.date.today().isoformat(),
             "note": "Facts and links only, from each board's own site. Built by scripts/catalogue/build.py.",
             "boards": sorted(boards.values(), key=lambda b: b["name"]),
             "unlisted": [{"id": k, "why": v} for k, v in NOT_LISTED.items()],
             "specs": sorted(specs.values(), key=lambda s: (s["board"], s["level"], s["subject"], s["qualification"]))}
    if {k: v for k, v in index.items() if k != "updated"} != {k: v for k, v in old.items() if k != "updated"}:
        index["updated"] = datetime.date.today().isoformat()
    with open(os.path.join(ROOT, "index.json"), "w") as f:
        json.dump(index, f, indent=0, ensure_ascii=False)
    print(f"index: {len(index['boards'])} boards, {len(index['specs'])} specs")


if __name__ == "__main__":
    main(sys.argv[1:] or list(FINDERS))
