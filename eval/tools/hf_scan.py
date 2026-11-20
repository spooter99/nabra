#!/usr/bin/env python3
"""Page through a split on the public HF datasets-server and cache the
non-audio columns as JSONL (one object per row, plus "row_idx").

Anonymous on purpose (no token, no huggingface_hub). Audio is NOT downloaded
here; only row metadata/transcripts are written, to the given output file
(which should live under eval/data/_raw/scan/).

Usage (run with `python3 -I`):
  hf_scan.py <repo> <config> <split> <out.jsonl> [--start N] [--max N] [--page N] [--sleep S]
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

DS = "https://datasets-server.huggingface.co"
UA = "eval-set-builder/1.0 (anonymous; python-urllib)"


def get(url, timeout=120, tries=6):
    last = None
    for i in range(tries):
        req = urllib.request.Request(url, headers={"User-Agent": UA})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return json.loads(r.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8", "replace")[:200].replace("\n", " ")
            last = "HTTP %s %s" % (e.code, body)
            if e.code in (401, 403, 404, 422, 501):
                break
        except Exception as e:
            last = "%s: %s" % (type(e).__name__, e)
        time.sleep(3 + 4 * i)
    raise RuntimeError(last)


def is_media(v):
    return (isinstance(v, list) and v and isinstance(v[0], dict) and "src" in v[0]) or (
        isinstance(v, dict) and "src" in v)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("repo")
    ap.add_argument("config")
    ap.add_argument("split")
    ap.add_argument("out")
    ap.add_argument("--start", type=int, default=0)
    ap.add_argument("--max", type=int, default=100000)
    ap.add_argument("--page", type=int, default=100)
    ap.add_argument("--sleep", type=float, default=0.6)
    a = ap.parse_args()

    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    n = 0
    total = None
    off = a.start
    with open(a.out, "a", encoding="utf-8") as f:
        while n < a.max:
            ln = min(a.page, a.max - n)
            url = "%s/rows?%s" % (DS, urllib.parse.urlencode(dict(
                dataset=a.repo, config=a.config, split=a.split, offset=off, length=ln)))
            try:
                d = get(url)
            except RuntimeError as e:
                print("STOP at offset %d: %s" % (off, e), file=sys.stderr)
                break
            total = d.get("num_rows_total")
            rows = d.get("rows", [])
            if not rows:
                break
            for r in rows:
                o = {"row_idx": r["row_idx"]}
                for k, v in r["row"].items():
                    if is_media(v):
                        continue
                    if isinstance(v, list) and len(v) > 50:
                        continue  # feature arrays etc.
                    o[k] = v
                f.write(json.dumps(o, ensure_ascii=False) + "\n")
                n += 1
            off += len(rows)
            if total is not None and off >= total:
                break
            time.sleep(a.sleep)
    print("wrote %d rows (offset %d..%d of %s) -> %s" % (n, a.start, off, total, a.out))


if __name__ == "__main__":
    main()
