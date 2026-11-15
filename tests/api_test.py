"""接口与权限的端到端测试 需要全新的数据目录

用法 先启动一个空数据目录的服务 再执行
MM_BASE=http://127.0.0.1:8899 python3 tests/api_test.py
"""

import base64, hashlib, hmac, json, os, struct, time, urllib.request, urllib.error

BASE = os.environ.get("MM_BASE", "http://127.0.0.1:8899")
TOKEN = None

def call(method, path, body=None, token=None, headers=None, raw=False, rawbody=None):
    url = BASE + path
    data = None
    h = {}
    if rawbody is not None:
        data = rawbody
    elif body is not None:
        data = json.dumps(body).encode()
        h["Content-Type"] = "application/json"
    if token:
        h["Session-Token"] = token
    if headers:
        h.update(headers)
    req = urllib.request.Request(url, data=data, headers=h, method=method)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            content = r.read()
            if raw:
                return r.status, dict(r.headers), content
            try:
                return r.status, dict(r.headers), json.loads(content or b"null")
            except Exception:
                return r.status, dict(r.headers), content.decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        content = e.read()
        try:
            return e.code, dict(e.headers), json.loads(content or b"null")
        except Exception:
            return e.code, dict(e.headers), content.decode("utf-8", "replace")

def check(name, cond, extra=""):
    print(("PASS " if cond else "FAIL ") + name + ((" | " + str(extra)) if extra else ""))
    if not cond:
        global failures
        failures += 1

failures = 0

def totp(secret, t=None):
    t = int(time.time()) if t is None else t
    key = base64.b32decode(secret + "=" * ((8 - len(secret) % 8) % 8))
    msg = struct.pack(">Q", t // 30)
    d = hmac.new(key, msg, hashlib.sha1).digest()
    o = d[-1] & 0x0F
    code = str((struct.unpack(">I", d[o:o+4])[0] & 0x7FFFFFFF) % 1000000)
    return code.zfill(6)

def login(u, p):
    code, _, data = call("POST", "/auth/login", {"username": u, "password": p})
    return code, data

st, data = login("admin", "admin123")
check("login admin", st == 200 and data.get("mfa_required") is False)
TOKEN = data["token"]

# ---- users CRUD ----
st, _, _ = call("POST", "/admin/users", {"username": "alice", "password": "alicepass1", "role": "user"}, TOKEN)
check("create user alice", st == 200, st)
st, _, _ = call("POST", "/admin/users", {"username": "bob", "password": "bobpass11", "role": "user"}, TOKEN)
check("create user bob", st == 200, st)
st, _, users = call("GET", "/admin/users", None, TOKEN)
check("list users has alice/bob", st == 200 and {u["username"] for u in users} >= {"alice", "bob"})
st, _, _ = call("PUT", "/admin/users/alice", {"password": "alicepass2", "enabled": True}, TOKEN)
check("update alice password", st == 200, st)
st, d = login("alice", "alicepass2")
check("alice login new password", st == 200 and d.get("token"))
alice_token = d["token"]

st, _, _ = call("PUT", "/admin/users/bob", {"enabled": False}, TOKEN)
check("disable bob", st == 200, st)
st, d = login("bob", "bobpass11")
check("bob login denied", st == 403, st)

# cannot demote self
st, _, _ = call("PUT", "/admin/users/admin", {"role": "user"}, TOKEN)
check("cannot demote self", st == 400, st)

# ---- groups ----
st, _, _ = call("POST", "/admin/groups", {"name": "devs", "description": "dev group"}, TOKEN)
check("create group devs", st == 200, st)
st, _, groups = call("GET", "/admin/groups", None, TOKEN)
gid = next((g["id"] for g in groups if g["name"] == "devs"), None)
check("find group devs", gid is not None)
st, _, _ = call("POST", f"/admin/groups/{gid}/members", {"username": "alice"}, TOKEN)
check("add alice to devs", st == 200, st)
st, _, _ = call("POST", f"/admin/groups/{gid}/repos/pypi", {"can_download": True, "can_upload": True}, TOKEN)
check("grant pypi to devs", st == 200, st)
st, _, groups = call("GET", "/admin/groups", None, TOKEN)
devs = next(g for g in groups if g["id"] == gid)
check("devs has alice", "alice" in devs["members"], devs)
check("devs has pypi grant", any(r["repo"] == "pypi" for r in devs["repos"]), devs)
st, _, _ = call("DELETE", f"/admin/groups/{gid}/members/alice", None, TOKEN)
check("remove alice from devs", st == 200, st)
st, _, _ = call("POST", f"/admin/groups/{gid}/repos/pypi", {"can_download": True, "can_upload": True}, TOKEN)
st, _, _ = call("DELETE", f"/admin/groups/{gid}/repos/pypi", None, TOKEN)
check("revoke pypi", st == 200, st)

# ---- member import ----
def upload(path, content, filename):
    boundary = "----mmtestboundary"
    body = (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="file"; filename="{filename}"\r\n'
        f"Content-Type: application/octet-stream\r\n\r\n"
    ).encode() + content + f"\r\n--{boundary}--\r\n".encode()
    return call("POST", path, None, TOKEN, headers={"Content-Type": "multipart/form-data; boundary=" + boundary}, rawbody=body)

csv_data = b"username,password,role,groups\ncarol,carolpass1,user,devs\ncarol,carolpass1,user,devs\ndave,,user,devs\nbad user,x,user,devs\n"
st, _, res = upload(f"/admin/groups/{gid}/members/import", csv_data, "members.csv")
check("csv import ok", st == 200 and res["total"] == 2 and len(res["created"]) == 2, res)
check("csv import duplicate error", any("重复" in e["reason"] for e in res["errors"]), res.get("errors"))
check("csv import bad username error", any("空白" in e["reason"] for e in res["errors"]), res.get("errors"))
check("csv import generated password", any(u["username"] == "dave" and u["generated"] and len(u["password"]) >= 8 for u in res["created"]), res.get("created"))

json_data = json.dumps([
    {"username": "erin", "password": "erinpass1", "role": "user", "groups": ["devs"]},
    "frank",
    {"username": "gina", "groups": "devs"},
]).encode()
st, _, res = upload(f"/admin/groups/{gid}/members/import", json_data, "members.json")
check("json import ok", st == 200 and res["total"] == 3 and len(res["created"]) == 3, res)

toml_data = b"""[[members]]
username = "helen"
password = "helenpass1"
role = "user"
groups = ["devs"]

[[members]]
username = "ivan"
groups = ["devs"]
"""
st, _, res = upload(f"/admin/groups/{gid}/members/import", toml_data, "members.toml")
check("toml import ok", st == 200 and res["total"] == 2, res)

txt_data = b"# comment\njudy,judypass1,user,devs\nkarl\n"
st, _, res = upload(f"/admin/groups/{gid}/members/import", txt_data, "members.txt")
check("txt import ok", st == 200 and res["total"] == 2, res)

st, _, _ = upload(f"/admin/groups/{gid}/members/import", b"x", "members.xlsx")
check("unsupported import rejected", st == 400, st)

# import must have created users
st, _, users = call("GET", "/admin/users", None, TOKEN)
names = {u["username"] for u in users}
check("imported users exist", {"carol", "dave", "erin", "frank", "gina", "helen", "ivan", "judy", "karl"} <= names, sorted(names))

# non-admin cannot import
st, _, _ = call("GET", f"/admin/groups", None, alice_token)
check("non-admin cannot list all groups", st == 403, st)

# ---- templates ----
for name in ["members.csv", "members.json", "members.toml", "members.txt"]:
    st, h, body = call("GET", "/templates/" + name, None, TOKEN, raw=True)
    check("template " + name, st == 200 and len(body) > 0, st)

# ---- MFA flow for alice ----
st, _, setup = call("POST", "/auth/mfa/setup", None, alice_token)
check("mfa setup", st == 200 and setup.get("secret"), setup)
secret = setup["secret"]
st, _, _ = call("POST", "/auth/mfa/enable", {"code": "000000"}, alice_token)
check("mfa enable wrong code rejected", st == 401, st)
st, _, _ = call("POST", "/auth/mfa/enable", {"code": totp(secret)}, alice_token)
check("mfa enable", st == 200, st)
st, d = login("alice", "alicepass2")
check("login now needs totp", st == 200 and d.get("mfa_required") is True and d.get("nonce"), d)
nonce = d["nonce"]
st, _, _ = call("POST", "/auth/verify-totp", {"nonce": nonce, "code": "000000"})
check("totp wrong code rejected", st == 401, st)
st, d = call("POST", "/auth/verify-totp", {"nonce": nonce, "code": totp(secret)})[0:3:2]
check("totp login ok", st == 200 and d.get("token"), d)
alice_token = d["token"]

# ---- API token ----
st, _, created = call("POST", "/auth/tokens", {"name": "ci"}, alice_token)
check("create api token", st == 200 and created.get("token", "").startswith("mm_"), created)
api_token = created["token"]
st, _, lst = call("GET", "/auth/tokens", None, alice_token)
check("list api tokens", st == 200 and any(t["name"] == "ci" for t in lst), lst)
st, _, me = call("GET", "/auth/me", None, api_token)
check("api token auth me", st == 200 and me["username"] == "alice", me)
tid = next(t["id"] for t in lst if t["name"] == "ci")
st, _, _ = call("POST", "/auth/tokens/revoke", {"id": tid}, alice_token)
check("revoke api token", st == 200, st)
st, _, _ = call("GET", "/auth/me", None, api_token)
check("revoked token rejected", st == 401, st)

# ---- password change ----
st, _, _ = call("POST", "/auth/password", {"old_password": "wrong", "new_password": "alicepass3"}, alice_token)
check("wrong old password rejected", st == 403, st)
st, _, _ = call("POST", "/auth/password", {"old_password": "alicepass2", "new_password": "alicepass3"}, alice_token)
check("change password", st == 200, st)
st, d = login("alice", "alicepass3")
check("login with new password", st == 200 and d.get("mfa_required") is True, d)

# ---- mfa disable ----
# get fresh session
nonce = d["nonce"]
st, d = call("POST", "/auth/verify-totp", {"nonce": nonce, "code": totp(secret)})[0:3:2]
alice_token = d["token"]
st, _, _ = call("POST", "/auth/mfa/disable", {"password": "alicepass3", "code": "000000"}, alice_token)
check("mfa disable wrong code rejected", st == 401, st)
st, _, _ = call("POST", "/auth/mfa/disable", {"password": "alicepass3", "code": totp(secret)}, alice_token)
check("mfa disable", st == 200, st)
st, d = login("alice", "alicepass3")
check("login without mfa after disable", st == 200 and d.get("mfa_required") is False, d)

# ---- 内置技能与普通用户可见仓库 ----
st, _, body = call("GET", "/skill/modernmirror-config/SKILL.md", None, alice_token, raw=True)
check("skill file for user", st == 200 and b"modernmirror-config" in body, st)
st, _, _ = call("GET", "/skill/modernmirror-config/SKILL.md", None, None)
check("skill requires login", st == 401, st)

st, _, _ = call("POST", "/admin/repos", {"name": "anonapi", "type": "npm",
    "upstream": "https://registry.npmjs.org", "anonymous": True}, TOKEN)
st, _, _ = call("POST", "/admin/repos", {"name": "hiddenapi", "type": "npm",
    "upstream": "https://registry.npmjs.org", "anonymous": False}, TOKEN)
st, _, repos = call("GET", "/admin/repos", None, alice_token)
visible = {r["name"] for r in repos}
check("user sees anonymous repository", "anonapi" in visible, sorted(visible))
check("user cannot see unshared private repository", "hiddenapi" not in visible, sorted(visible))
call("DELETE", "/admin/repos/anonapi", None, TOKEN)
call("DELETE", "/admin/repos/hiddenapi", None, TOKEN)

# ---- admin reset mfa ----
st, _, _ = call("POST", "/auth/mfa/disable", {"password": "alicepass3", "code": "000000"}, alice_token)
check("mfa disable when not enabled rejected", st == 400, st)

# 重新绑定后再由管理员重置, 验证重置真正生效而不只是接口返回 200
st, _, d = call("POST", "/auth/mfa/setup", None, alice_token)
check("mfa setup before reset", st == 200 and bool(d.get("secret")), d)
st, _, _ = call("POST", "/auth/mfa/enable", {"code": totp(d["secret"])}, alice_token)
check("mfa enable before reset", st == 200, st)
st, _, r = call("POST", "/admin/users/alice/reset-mfa", None, TOKEN)
check("admin reset mfa", st == 200 and r.get("ok") is True, r)
st, d = login("alice", "alicepass3")
check("login without mfa after admin reset", st == 200 and d.get("mfa_required") is False, d)
st, _, r = call("POST", "/admin/users/nobody/reset-mfa", None, TOKEN)
check("admin reset mfa unknown user", st == 200 and r.get("ok") is False, r)

# ---- settings ----
st, _, s = call("PUT", "/admin/settings?mfa_enforced=1", None, TOKEN)
check("set mfa enforced", st == 200 and s["mfa_enforced"] is True, s)
st, _, _ = call("GET", "/admin/settings", None, TOKEN)
check("get settings", st == 200, st)
st, _, s = call("PUT", "/admin/settings?mfa_enforced=0&cleanup_enabled=1&cache_retention_days=15", None, TOKEN)
check("settings update cache days", st == 200 and s["cache_retention_days"] == 15, s)

# ---- cleanup ----
st, _, c = call("POST", "/admin/cache/cleanup?days=7", None, TOKEN)
check("cache cleanup", st == 200 and "freed_bytes" in c, c)

# ---- security ----
st, _, sec = call("GET", "/admin/security/status", None, TOKEN)
check("security status", st == 200 and "legacy_api_tokens" in sec, sec)

# ---- delete users/groups ----
st, _, _ = call("DELETE", "/admin/users/bob", None, TOKEN)
check("delete bob", st == 200, st)
st, _, _ = call("DELETE", f"/admin/groups/{gid}", None, TOKEN)
check("delete group devs", st == 200, st)

print("FAILURES=" + str(failures))
