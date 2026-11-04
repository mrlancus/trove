#!/usr/bin/env python3
"""Checks the paper catalogue's links (docs/CATALOGUE.md): every link must be on its board's own site;
a sample (and each spec's newest question paper) must answer a HEAD (or GET) with 200. Prints the
broken ones and exits 1 if any are, so CI reports them; the apps show a broken link as unavailable.

    python3 scripts/check-catalogue.py catalogue              # every link (slow: ~25,000)
    python3 scripts/check-catalogue.py catalogue --sample 400
"""
import json, os, random, sys, urllib.request
from urllib.parse import urlparse

BOARD_HOSTS = {"aqa": ("aqa.org.uk", "cdn.sanity.io"), "ocr": ("ocr.org.uk",), "eduqas": ("wjec.co.uk", "eduqas.co.uk"),
               "wjec": ("wjec.co.uk",), "cie": ("cambridgeinternational.org",), "pearson": ("pearson.com",), "ccea": ("ccea.org.uk",)}


def status(url):
    last = ""
    for method in ("HEAD", "GET"):
        try:
            req = urllib.request.Request(url, method=method, headers={"User-Agent": "Trove catalogue link check"})
            with urllib.request.urlopen(req, timeout=30) as r:
                return r.status, r.headers.get("Content-Type", "")
        except Exception as e:  # noqa: BLE001
            last = str(e)
    return None, last


def main(root, sample=None):
    index = json.load(open(os.path.join(root, "index.json")))
    broken, docs, newest = [], [], []
    for summary in index["specs"]:
        spec = json.load(open(os.path.join(root, "specs", f"{summary['id']}.json")))
        hosts = BOARD_HOSTS.get(spec["board"], ())
        qps = [d for d in spec["docs"] if d["type"] == "qp"]
        if qps:
            newest.append(qps[0])
        for doc in spec["docs"]:
            host = urlparse(doc["url"]).hostname or ""
            if not any(host == h or host.endswith("." + h) for h in hosts):
                broken.append((doc["id"], doc["url"], f"not on {spec['board']}'s site"))
            docs.append(doc)
    random.seed(len(docs))
    checked = docs if sample is None else list({d["id"]: d for d in random.sample(docs, min(sample, len(docs))) + newest}.values())
    for doc in checked:
        code, kind = status(doc["url"])
        if code != 200:
            broken.append((doc["id"], doc["url"], f"{code} {kind}"))
    for b in broken:
        print("BROKEN", *b)
    print(f"{len(docs)} links on the boards' sites checked for host; {len(checked)} fetched; {len(broken)} broken")
    return 1 if broken else 0


if __name__ == "__main__":
    args = sys.argv[1:]
    n = int(args[args.index("--sample") + 1]) if "--sample" in args else None
    paths = [a for a in args if not a.startswith("--") and not a.isdigit()]
    sys.exit(main(paths[0] if paths else "catalogue", n))
