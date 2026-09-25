import sys, json, urllib.request, os
BASE = os.environ.get("WDA_BASE", "http://localhost:8200")
SID_FILE = os.environ.get("WDA_SID_FILE", "/tmp/phone-ui-wda-sid.txt")
def call(method, path, body=None, timeout=60):
    req = urllib.request.Request(BASE + path, data=(json.dumps(body).encode() if body is not None else None), method=method, headers={"Content-Type": "application/json"})
    try:
        return json.load(urllib.request.urlopen(req, timeout=timeout))
    except urllib.error.HTTPError as e:
        return {"error": e.code, "body": e.read()[:300].decode(errors="replace")}
def sid():
    if os.path.exists(SID_FILE):
        s = open(SID_FILE).read().strip()
        if call("GET", f"/session/{s}/wda/screen").get("value") is not None: return s
    r = call("POST", "/session", {"capabilities": {"alwaysMatch": {}}})
    s = r["sessionId"]; open(SID_FILE, "w").write(s); return s
def tree(node, out, depth=0):
    r = node.get("rect", {}); lbl = node.get("label") or node.get("name") or node.get("value") or ""
    if node.get("isVisible") in (True, "1", 1) and (lbl or node.get("type") in ("TextField", "SecureTextField", "Button", "Switch")):
        out.append(f"{node.get('type')} {lbl!r} [{r.get('x')}, {r.get('y')}, {r.get('width')}, {r.get('height')}]")
    for c in node.get("children", []) or []: tree(c, out, depth + 1)
cmd = sys.argv[1]; s = sid()
if cmd == "source":
    r = call("GET", f"/session/{s}/source?format=json"); out = []; tree(r["value"], out); print("\n".join(out[:80]))
elif cmd == "tap":
    print(call("POST", f"/session/{s}/wda/tap", {"x": float(sys.argv[2]), "y": float(sys.argv[3])}).get("value"))
elif cmd == "type":
    print(call("POST", f"/session/{s}/wda/keys", {"value": list(sys.argv[2])}).get("value"))
elif cmd == "click":
    r = call("POST", f"/session/{s}/element", {"using": "predicate string", "value": sys.argv[2]})
    el = r.get("value", {}).get("ELEMENT") or (list(r.get("value", {}).values()) or [None])[0]
    print("element", el, "->", call("POST", f"/session/{s}/element/{el}/click", {}).get("value") if el else r)
elif cmd == "activate":
    print(call("POST", f"/session/{s}/wda/apps/activate", {"bundleId": sys.argv[2]}))
elif cmd == "alert":
    print(call("GET", f"/session/{s}/alert/text"))
elif cmd == "alert-accept":
    print(call("POST", f"/session/{s}/alert/accept", {}))
elif cmd == "shot":
    import base64; open(sys.argv[2], "wb").write(base64.b64decode(call("GET", f"/session/{s}/screenshot")["value"])); print("saved", sys.argv[2])
