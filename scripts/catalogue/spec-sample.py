#!/usr/bin/env python3
"""Downloads a few real specifications from the boards (into a folder you name, never the repo) and writes each
one's text lines with positions as JSON, the way the apps read a PDF, so the TroveCore test `RealSpecTests` can
read them into statements: TROVE_SPEC_LINES=<folder> swift test --filter RealSpec.

    python3 scripts/catalogue/spec-sample.py /tmp/specs aqa-7408 aqa-8461 ocr-h240 pearson-1ma1 cie-0625 eduqas-a420

Needs `pdftotext` (poppler). The specifications stay in that folder; nothing of theirs is committed.
"""
import importlib.util, json, os, sys, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..", "..", "catalogue")
spec_ = importlib.util.spec_from_file_location("split_sample", os.path.join(HERE, "split-sample.py"))
split_sample = importlib.util.module_from_spec(spec_)
spec_.loader.exec_module(split_sample)


def main(folder, spec_ids):
    os.makedirs(folder, exist_ok=True)
    for sid in spec_ids:
        spec = json.load(open(os.path.join(ROOT, "specs", f"{sid}.json")))
        doc = next((d for d in spec["docs"] if d["type"] == "spec"), None)
        if not doc:
            print(sid, "has no specification in the catalogue")
            continue
        pdf = os.path.join(folder, f"{doc['id']}.pdf")
        if not os.path.exists(pdf):
            req = urllib.request.Request(doc["url"], headers={"User-Agent": "Trove spec check"})
            with urllib.request.urlopen(req, timeout=120) as r, open(pdf, "wb") as f:
                f.write(r.read())
        ls, w, h = split_sample.lines(pdf)
        with open(os.path.join(folder, f"{doc['id']}.json"), "w") as f:
            json.dump({"doc": doc["id"], "spec": sid, "board": spec["board"], "width": w, "height": h, "lines": ls}, f)
        print(doc["id"], len(ls), "lines")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2:])
