#!/usr/bin/env python3
# analyze-autobahn.py <index.json> — resumo de conformidade do fuzzingclient.
import json, sys, collections

idx = json.load(open(sys.argv[1]))
# estrutura: { agent: { caseId: { "behavior":..., "behaviorClose":..., "duration":... } } }
by_behavior = collections.Counter()
fails = []
for agent, cases in idx.items():
    for cid, info in cases.items():
        b = info.get("behavior", "?")
        bc = info.get("behaviorClose", "?")
        by_behavior[b] += 1
        # problemas de conformidade: tudo que nao e OK/NON-STRICT/INFORMATIONAL
        if b in ("FAILED", "WRONG CODE", "UNCLEAN") or bc in ("FAILED", "WRONG CODE"):
            fails.append((cid, b, bc))

print("=== Autobahn fuzzingclient — resumo por behavior ===")
for b, n in sorted(by_behavior.items(), key=lambda x: -x[1]):
    print(f"  {b:16} {n}")
total = sum(by_behavior.values())
ok = by_behavior.get("OK", 0) + by_behavior.get("NON-STRICT", 0) + by_behavior.get("INFORMATIONAL", 0)
print(f"  ---")
print(f"  total={total}  conformes(OK+NON-STRICT+INFO)={ok}  problemas={len(fails)}")
if fails:
    print("=== casos com problema ===")
    def keyf(c):
        try: return tuple(int(x) for x in c[0].split("."))
        except: return (9999,)
    for cid, b, bc in sorted(fails, key=keyf):
        print(f"  {cid:10} behavior={b} close={bc}")
