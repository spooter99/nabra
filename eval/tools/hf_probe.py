#!/usr/bin/env python3
"""Read-only probe of the public Hugging Face Hub / datasets-server APIs.

Anonymous on purpose: no token, no login, no huggingface_hub import (so no
cached credential on this machine can be picked up). Only prints text.

Usage (run with `python3 -I`):
  hf_probe.py info   <repo>
  hf_probe.py splits <repo>
  hf_probe.py rows   <repo> <config> <split> [offset] [length]
  hf_probe.py search <term> [limit]
  hf_probe.py filter <repo> <config> <split> <where-sql> [length]
  hf_probe.py find   <repo> <config> <split> <query> [length]
"""
import json
import sys
import urllib.error
import urllib.parse
import urllib.request

DS = "https://datasets-server.huggingface.co"
HUB = "https://huggingface.co"
UA = "eval-set-builder/1.0 (anonymous; python-urllib)"


def get(url, timeout=90):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")
        try:
            j = json.loads(body)
        except Exception:
            j = {"error": body[:300]}
        j["_http_status"] = e.code
        return j
    except Exception as e:  # network / timeout
        return {"error": "%s: %s" % (type(e).__name__, e), "_http_status": None}


def q(**kw):
    return urllib.parse.urlencode(kw)


def compact(row, maxlen=260):
    out = {}
    for k, v in row.items():
        if isinstance(v, list) and v and isinstance(v[0], dict) and "src" in v[0]:
            out[k] = "<audio %s>" % v[0].get("type")
        elif isinstance(v, dict) and "src" in v:
            out[k] = "<media>"
        elif isinstance(v, str) and len(v) > maxlen:
            out[k] = v[:maxlen] + "…"
        else:
            out[k] = v
    return out


def print_rows(d):
    if "error" in d:
        print("ERROR", d.get("_http_status"), str(d["error"])[:400])
        return
    feats = d.get("features") or []
    print("features:", ", ".join("%s:%s" % (f["name"], (f["type"].get("dtype") or f["type"].get("_type"))) for f in feats))
    print("num_rows_total:", d.get("num_rows_total"), "| partial:", d.get("partial"))
    for r in d.get("rows", []):
        print(r["row_idx"], json.dumps(compact(r["row"]), ensure_ascii=False))


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    cmd = argv[1]
    if cmd == "info":
        d = get("%s/api/datasets/%s" % (HUB, argv[2]))
        if "error" in d:
            print("ERROR", d.get("_http_status"), d["error"])
            return 1
        cd = d.get("cardData") or {}
        print("id:", d.get("id"), "| private:", d.get("private"), "| gated:", d.get("gated"),
              "| disabled:", d.get("disabled"), "| downloads:", d.get("downloads"), "| likes:", d.get("likes"))
        print("license:", cd.get("license"), "| license_name:", cd.get("license_name"))
        print("tags:", [t for t in d.get("tags", []) if not t.startswith("region")][:25])
        sibs = [s.get("rfilename") for s in d.get("siblings", [])]
        print("files(%d):" % len(sibs), sibs[:25])
    elif cmd == "splits":
        d = get("%s/splits?%s" % (DS, q(dataset=argv[2])))
        if "error" in d:
            print("ERROR", d.get("_http_status"), str(d["error"])[:400])
            return 1
        for s in d.get("splits", []):
            print(s.get("config"), "/", s.get("split"))
        for s in (d.get("pending") or []) + (d.get("failed") or []):
            print("pending/failed:", str(s)[:300])
    elif cmd == "rows":
        repo, cfg, split = argv[2], argv[3], argv[4]
        off = int(argv[5]) if len(argv) > 5 else 0
        ln = int(argv[6]) if len(argv) > 6 else 10
        print_rows(get("%s/rows?%s" % (DS, q(dataset=repo, config=cfg, split=split, offset=off, length=ln))))
    elif cmd == "search":
        lim = int(argv[3]) if len(argv) > 3 else 40
        d = get("%s/api/datasets?%s" % (HUB, q(search=argv[2], limit=lim, full="false")))
        if isinstance(d, dict) and "error" in d:
            print("ERROR", d)
            return 1
        for x in d:
            tags = x.get("tags", [])
            lic = [t for t in tags if t.startswith("license:")]
            mod = [t for t in tags if t.startswith("modality:") or t.startswith("task_categories:")]
            print("%-60s gated=%-6s dl=%-7s %s %s" % (x.get("id"), x.get("gated"), x.get("downloads"), lic, mod))
    elif cmd == "filter":
        repo, cfg, split, where = argv[2], argv[3], argv[4], argv[5]
        ln = int(argv[6]) if len(argv) > 6 else 10
        print_rows(get("%s/filter?%s" % (DS, q(dataset=repo, config=cfg, split=split, where=where, offset=0, length=ln))))
    elif cmd == "find":
        repo, cfg, split, query = argv[2], argv[3], argv[4], argv[5]
        ln = int(argv[6]) if len(argv) > 6 else 10
        print_rows(get("%s/search?%s" % (DS, q(dataset=repo, config=cfg, split=split, query=query, offset=0, length=ln))))
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
