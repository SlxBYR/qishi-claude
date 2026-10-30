#!/usr/bin/env python3
"""Restore the pinned upstream Claude images without replacing local additions."""
import concurrent.futures, hashlib, json, pathlib, urllib.request
root = pathlib.Path(__file__).resolve().parents[1]
lock = json.loads((root / 'Upstream/upstream-lock.json').read_text())['crosspet']
dest = root / 'Resources/Claude'
dest.mkdir(parents=True, exist_ok=True)
def fetch(item):
    if not item['path'].endswith('.webp'): return
    p = dest / pathlib.Path(item['path']).name
    def blob(data): return hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()
    if p.exists() and blob(p.read_bytes()) == item['sha']: return 'existing'
    url = f"https://raw.githubusercontent.com/lokicorvus/crosspet/{lock['commit']}/{item['path']}"
    data = urllib.request.urlopen(url, timeout=30).read()
    assert blob(data) == item['sha'], item['path']
    p.write_bytes(data)
    return 'downloaded'
with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
    results = list(pool.map(fetch, lock['files']))
print({kind: results.count(kind) for kind in ('existing','downloaded')})
