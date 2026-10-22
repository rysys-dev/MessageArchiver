"""Reads `cargo metadata` on stdin; prints THIRD-PARTY-NOTICES.txt (see third-party-notices.sh)."""
import json, os, sys
m = json.load(sys.stdin)
res = m["resolve"]
nodes = {n["id"]: n for n in res["nodes"]}
packages = {p["id"]: p for p in m["packages"]}
# What is compiled into the binary: normal and build dependencies, not dev ones.
# MA_PACKAGE names a plug-in (Scripts/release-plugin.sh): its crates, not ma-engine's.
wanted = os.environ.get("MA_PACKAGE")
root = next(p["id"] for p in m["packages"] if p["name"] == wanted) if wanted else res["root"]
name = wanted or "ma-engine"
seen, stack = set(), [root]
while stack:
    i = stack.pop()
    if i in seen:
        continue
    seen.add(i)
    for d in nodes[i]["deps"]:
        if any(k["kind"] in (None, "build") for k in d["dep_kinds"]):
            stack.append(d["pkg"])
seen.discard(root)
# This repo's own crates (engine/protocol, Milestone 15) aren't third-party: they come from a
# path here, not a registry.
crates = sorted((packages[i] for i in seen if packages[i]["source"] is not None), key=lambda p: (p['name'].lower(), p['version']))

out = []
out.append("MessageArchiver — third-party notices\n")
out.append("MessageArchiver is free software under the GNU General Public License v3 (see LICENSE).")
out.append(f"Its engine, {name}, is built from these Rust crates, each under the license shown and")
out.append("reproduced below. The Traditional conversation style adapts the CSS of imessage-exporter")
out.append("(https://github.com/ReagentX/imessage-exporter, GPL-3.0). SQLite, compiled in through")
out.append("rusqlite, is in the public domain (https://sqlite.org/copyright.html).\n")
for p in crates:
    out.append(f"  {p['name']} {p['version']} — {p['license'] or 'see below'}")
for p in crates:
    folder = os.path.dirname(p["manifest_path"])
    texts = sorted(f for f in os.listdir(folder)
                   if f.upper().startswith(("LICENSE", "LICENCE", "COPYING", "UNLICENSE", "NOTICE")) and os.path.isfile(os.path.join(folder, f)))
    out.append("\n" + "=" * 78)
    out.append(f"{p['name']} {p['version']} — {p['license']}")
    if p.get("repository"):
        out.append(p["repository"])
    out.append("=" * 78)
    if not texts:
        out.append(f"(No license file in the crate; licensed {p['license']}." + (" The GPL's text is in LICENSE.)" if "GPL" in (p["license"] or "") else ")"))
    for t in texts:
        with open(os.path.join(folder, t), encoding="utf-8", errors="replace") as f:
            out.append(f"\n--- {t} ---\n")
            out.append(f.read().rstrip())
print("\n".join(out))
print(f"{len(crates)} crates", file=sys.stderr)
