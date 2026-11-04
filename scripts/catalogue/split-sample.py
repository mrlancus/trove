#!/usr/bin/env python3
"""Downloads a few real question papers from the boards (into a folder you name, never the repo) and
writes each one's text lines with positions as JSON, the way the apps read a PDF, so the TroveCore
test `RealPaperSplitTests` can split them: TROVE_SPLIT_LINES=<folder> swift test --filter RealPaper.

    python3 scripts/catalogue/split-sample.py /tmp/papers aqa-7408 ocr-h556 eduqas-a420 wjec-1420 cie-9702

Needs `pdftotext` (poppler). The papers stay in that folder; nothing of theirs is committed.
"""
import json, os, re, subprocess, sys, urllib.request
import xml.etree.ElementTree as ET

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "catalogue")


def lines(pdf):
    """pdftotext -bbox-layout → [{page, x, y, width, height, text}] in points, origin top-left."""
    xml = subprocess.run(["pdftotext", "-bbox-layout", pdf, "-"], capture_output=True, check=True).stdout
    xml = re.sub(rb"<!DOCTYPE[^>]*>", b"", xml)
    xml = re.sub(rb"[\x00-\x08\x0b\x0c\x0e-\x1f]", b"", xml)
    root = ET.fromstring(xml)
    ns = {"x": "http://www.w3.org/1999/xhtml"}
    out = []
    for p, page in enumerate(root.iter("{http://www.w3.org/1999/xhtml}page")):
        for line in page.iter("{http://www.w3.org/1999/xhtml}line"):
            words = [w.text or "" for w in line.findall("x:word", ns)]
            x0, y0, x1, y1 = (float(line.get(k)) for k in ("xMin", "yMin", "xMax", "yMax"))
            text = " ".join(words).strip()
            if text:
                out.append({"page": p, "x": x0, "y": y0, "width": x1 - x0, "height": y1 - y0, "text": text})
    size = root.find(".//x:page", ns)
    return out, float(size.get("width")), float(size.get("height"))


def main(folder, spec_ids):
    os.makedirs(folder, exist_ok=True)
    index = json.load(open(os.path.join(ROOT, "index.json")))
    boards = {b["id"]: b for b in index["boards"]}
    for arg in spec_ids:
        sid, _, paper = arg.partition("@")  # "cie-9702@4": the newest paper whose number starts with 4
        spec = json.load(open(os.path.join(ROOT, "specs", f"{sid}.json")))
        qp = next(d for d in spec["docs"] if d["type"] == "qp" and d.get("year") and (d.get("paper") or "").startswith(paper))
        pdf = os.path.join(folder, f"{qp['id']}.pdf")
        if not os.path.exists(pdf):
            req = urllib.request.Request(qp["url"], headers={"User-Agent": "Trove split check"})
            with urllib.request.urlopen(req, timeout=60) as r, open(pdf, "wb") as f:
                f.write(r.read())
        ls, w, h = lines(pdf)
        layout = boards.get(spec["board"], {}).get("layout")
        with open(os.path.join(folder, f"{qp['id']}.json"), "w") as f:
            json.dump({"doc": qp["id"], "board": spec["board"], "layout": layout, "width": w, "height": h, "lines": ls}, f)
        print(qp["id"], len(ls), "lines")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2:])
