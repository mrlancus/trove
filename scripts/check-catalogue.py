#!/usr/bin/env python3
"""Checks every link in catalogue/papers.json (docs/DEVELOP_PLAN.md Appendix D): each must be on its
board's own site and answer a HEAD (or GET) with 200 and a PDF or page. Prints the broken ones and
exits 1 if any are, so CI reports them; the apps show a broken link as "Unavailable"."""
import json, sys, urllib.request
from urllib.parse import urlparse

BOARD_HOSTS = {"aqa": ("aqa.org.uk",), "pearson": ("pearson.com",), "ocr": ("ocr.org.uk", "cambridgeassessment.org.uk"),
               "wjec": ("wjec.co.uk", "eduqas.co.uk", "cbac.co.uk"), "ccea": ("ccea.org.uk",)}

def status(url):
    for method in ("HEAD", "GET"):
        try:
            req = urllib.request.Request(url, method=method, headers={"User-Agent": "Trove catalogue link check"})
            with urllib.request.urlopen(req, timeout=30) as r:
                return r.status, r.headers.get("Content-Type", "")
        except Exception as e:  # noqa: BLE001
            last = str(e)
    return None, last

def main(path):
    cat = json.load(open(path))
    broken = []
    for spec in cat["specs"]:
        hosts = BOARD_HOSTS.get(spec["board"], ())
        for doc in [{"id": spec["id"], "url": spec["url"]}] + spec["docs"]:
            host = urlparse(doc["url"]).hostname or ""
            if not any(host == h or host.endswith("." + h) for h in hosts):
                broken.append((doc["id"], doc["url"], f"not on {spec['board']}'s site"))
                continue
            code, kind = status(doc["url"])
            if code != 200:
                broken.append((doc["id"], doc["url"], f"{code} {kind}"))
    for b in broken:
        print("BROKEN", *b)
    print(f"{sum(1 + len(s['docs']) for s in cat['specs'])} links, {len(broken)} broken")
    return 1 if broken else 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "catalogue/papers.json"))
