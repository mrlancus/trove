#!/usr/bin/env python3
"""Pearson Edexcel: the past-paper finder on qualifications.pearson.com.

Pearson's finder page searches its documents through a hosted search service, with a search-only key it
gives every visitor in the page itself. This reads that key from the page on each run (nothing is kept
in the repo), asks for past papers, mark schemes and examiner reports, and keeps links to Pearson's own
PDFs. Running it is the user's choice (2026-11-04; .claude/settings.json allows it in Claude sessions).

    python3 scripts/catalogue/pearson.py probe     # one sample record, to see the fields
"""
import json, re, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import fetch, doc_id, level_of  # noqa: E402

PAGE = "https://qualifications.pearson.com/en/support/support-topics/exams/past-papers.html"


def config():
    page = fetch(PAGE)
    def val(cls):
        m = re.search(rf'value="([^"]+)"\s+class="{cls}"', page)
        if not m:
            raise RuntimeError(f"{cls} not found on Pearson's page")
        return m.group(1)
    return val("algoliaAppId"), val("algoliaAPIKey"), val("algoliaIndexName")


def query(cfg, filters, page=0, per=1000, attributes=None):
    app, key, index = cfg
    import urllib.request
    body = {"query": "", "filters": filters, "hitsPerPage": per, "page": page}
    if attributes:
        body["attributesToRetrieve"] = attributes
    req = urllib.request.Request(f"https://{app}-dsn.algolia.net/1/indexes/{index}/query", data=json.dumps(body).encode(),
                                 headers={"X-Algolia-Application-Id": app, "X-Algolia-API-Key": key, "Content-Type": "application/json",
                                          "Referer": "https://qualifications.pearson.com/", "User-Agent": "Trove catalogue builder"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read())


if __name__ == "__main__" and sys.argv[1:2] == ["probe"]:
    cfg = config()
    d = query(cfg, 'category:"Pearson-UK:Document-Type/Question-paper"', per=2)
    print("hits:", d.get("nbHits"), "pages:", d.get("nbPages"))
    print(json.dumps(d.get("hits", [])[:2], indent=1)[:4000])
