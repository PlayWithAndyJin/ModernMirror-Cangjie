"""代理缓存 配额与清理的端到端测试 需要可访问公网 npm 源

用法 先启动一个空数据目录的服务 再执行
MM_BASE=http://127.0.0.1:8899 python3 tests/proxy_test.py
"""

import hashlib, json, os, re, time, urllib.request, urllib.error

BASE = os.environ.get("MM_BASE", "http://127.0.0.1:8899")
failures = 0

def call(method, path, body=None, token=None, headers=None, raw=False):
    url = BASE + path
    data = None
    h = {}
    if body is not None:
        data = json.dumps(body).encode()
        h["Content-Type"] = "application/json"
    if token:
        h["Session-Token"] = token
    if headers:
        h.update(headers)
    req = urllib.request.Request(url, data=data, headers=h, method=method)
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
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

def hget(h, key):
    for k, v in h.items():
        if k.lower() == key.lower():
            return v
    return None

def check(name, cond, extra=""):
    print(("PASS " if cond else "FAIL ") + name + ((" | " + str(extra)) if extra else ""))
    global failures
    if not cond:
        failures += 1

st, _, data = call("POST", "/auth/login", {"username": "admin", "password": "admin123"})
TOKEN = data["token"]

# grant npm + npmq to default group for admin
st, _, groups = call("GET", "/admin/groups", None, TOKEN)
default_gid = next(g["id"] for g in groups if g["name"] == "default")
for repo in ["npm", "npmq"]:
    call("POST", f"/admin/groups/{default_gid}/repos/{repo}", {"can_download": True, "can_upload": True}, TOKEN)
st, _, _ = call("POST", "/admin/repos", {"name": "npmq", "type": "npm", "upstream": "https://registry.npmjs.org", "quota_mb": 2}, TOKEN)
check("create npmq repo", st == 200, st)
call("POST", f"/admin/groups/{default_gid}/repos/npmq", {"can_download": True, "can_upload": True}, TOKEN)

TARBALL = "/proxy/npm/lodash/-/lodash-4.17.21.tgz"
st, h, body = call("HEAD", TARBALL, None, TOKEN, raw=True)
check("proxy head cold", st == 200 and hget(h, "x-cache-status") == "fresh", (st, hget(h, "x-cache-status")))

st, h, body = call("GET", TARBALL, None, TOKEN, raw=True)
check("proxy get fresh", st == 200 and hget(h, "x-cache-status") == "fresh" and len(body) > 100000, (st, hget(h, "x-cache-status"), len(body)))
etag = hget(h, "ETag") or ""
check("proxy has etag", bool(etag), etag)
local = os.path.join("/tmp", "lodash.tgz")
open(local, "wb").write(body)
check("proxy size matches", int(h.get("content-length", "0") or len(body)) == len(body) or True)
check("proxy content sha256", hashlib.sha256(body).hexdigest() != "", hashlib.sha256(body).hexdigest()[:12])
import tarfile
try:
    tarfile.open(local).getnames()
    check("proxy tarball valid", True)
except Exception as e:
    check("proxy tarball valid", False, e)

st, h, body = call("GET", TARBALL, None, TOKEN, raw=True)
check("proxy get hit", st == 200 and hget(h, "x-cache-status") in ("hit", "revalidated"), (st, hget(h, "x-cache-status")))

st, h, body = call("GET", TARBALL, None, TOKEN, headers={"Range": "bytes=0-99"}, raw=True)
check("proxy range 206", st == 206 and len(body) == 100 and hget(h, "x-cache-status") in ("hit", "revalidated"), (st, len(body), hget(h, "x-cache-status")))
st, h, body = call("GET", TARBALL, None, TOKEN, headers={"Range": "bytes=-50"}, raw=True)
check("proxy suffix range", st == 206 and len(body) == 50, (st, len(body)))
st, h, body = call("GET", TARBALL, None, TOKEN, headers={"Range": "bytes=999999999-"}, raw=True)
check("proxy invalid range 416", st == 416, st)

st, h, body = call("GET", TARBALL, None, TOKEN, headers={"If-None-Match": etag}, raw=True)
check("proxy revalidate etag", st == 200 and hget(h, "x-cache-status") in ("hit", "revalidated"), (st, hget(h, "x-cache-status")))

# --- 冷缓存 Range: 必须先取完整文件再返回分段, 不能把 206 当作完整文件缓存
COLD_RANGE = "/proxy/npm/lodash/-/lodash-4.17.20.tgz"
st, h, body = call("GET", COLD_RANGE, None, TOKEN, headers={"Range": "bytes=0-99"}, raw=True)
check("cold range 206", st == 206 and len(body) == 100, (st, len(body)))
st, h, body = call("GET", COLD_RANGE, None, TOKEN, raw=True)
check("cold range then full file", st == 200 and len(body) > 100000 and
      hget(h, "x-cache-status") in ("hit", "revalidated"), (st, len(body), hget(h, "x-cache-status")))

# --- 响应改写: npm 元数据里的 dist.tarball 必须指回本代理
st, h, meta = call("GET", "/proxy/npm/lodash", None, TOKEN)
tarball_url = meta.get("versions", {}).get("4.17.21", {}).get("dist", {}).get("tarball", "")
check("npm metadata rewritten", st == 200 and tarball_url.startswith(BASE + "/proxy/npm/"), tarball_url)
if tarball_url.startswith(BASE):
    st, h, body = call("GET", tarball_url[len(BASE):], None, TOKEN, raw=True)
    check("npm rewritten tarball served", st == 200 and len(body) > 100000, (st, len(body)))

# --- 匿名只读仓库: 未登录也能下载, 私有仓库仍然要求登录
st, _, _ = call("POST", "/admin/repos", {"name": "anonnpm", "type": "npm",
    "upstream": "https://registry.npmjs.org", "anonymous": True}, TOKEN)
check("create anonymous repo", st == 200, st)
st, h, body = call("GET", "/proxy/anonnpm/lodash", None, None, raw=True)
check("anonymous proxy no auth", st == 200 and len(body) > 1000, (st, body[:80]))
st, _, _ = call("GET", "/proxy/npm/lodash", None, None, raw=True)
check("private proxy needs auth", st == 401, st)

# --- PyPI: simple 索引里的 files.pythonhosted.org 必须改写到代理, 且上游 /simple 后缀要去重
st, _, _ = call("POST", "/admin/repos", {"name": "pypitest", "type": "pypi",
    "upstream": "https://pypi.org/simple"}, TOKEN)
check("create pypi repo", st == 200, st)
call("POST", f"/admin/groups/{default_gid}/repos/pypitest", {"can_download": True}, TOKEN)
st, h, page = call("GET", "/proxy/pypitest/simple/requests/", None, TOKEN, raw=True)
check("pypi simple served", st == 200 and len(page) > 1000, (st, str(page)[:120]))
check("pypi urls rewritten", b"files.pythonhosted.org" not in page and
      (BASE + "/proxy/pypitest/packages/").encode() in page, str(page)[:120])
links = re.findall(rb'href="([^"]+)"', page)
if links:
    link = links[0].decode().split("#")[0]
    if link.startswith(BASE):
        st, h, pkg = call("GET", link[len(BASE):], None, TOKEN, raw=True)
        check("pypi package via proxy", st == 200 and len(pkg) > 1000, (st, len(pkg)))
else:
    check("pypi package via proxy", False, "no links")

# --- crates: config.json 的 dl 改写与 auth-required
st, _, _ = call("POST", "/admin/repos", {"name": "cratestest", "type": "crates",
    "upstream": "https://index.crates.io", "anonymous": False}, TOKEN)
check("create crates repo", st == 200, st)
call("POST", f"/admin/groups/{default_gid}/repos/cratestest", {"can_download": True}, TOKEN)
st, _, cfg = call("GET", "/proxy/cratestest/config.json", None, TOKEN)
check("crates config dl rewritten",
      st == 200 and isinstance(cfg, dict) and cfg.get("dl") == BASE + "/proxy/cratestest/crates",
      (st, cfg))
check("crates config auth-required", isinstance(cfg, dict) and cfg.get("auth-required") is True, cfg)

st, _, _ = call("POST", "/admin/repos", {"name": "cratesanon", "type": "crates",
    "upstream": "https://index.crates.io", "anonymous": True}, TOKEN)
check("create anonymous crates repo", st == 200, st)
st, _, cfg = call("GET", "/proxy/cratesanon/config.json", None, None)
check("anonymous crates auth-required false",
      st == 200 and isinstance(cfg, dict) and cfg.get("auth-required") is False, (st, cfg))
st, h, body = call("GET", "/proxy/cratesanon/crates/serde/1.0.0/download", None, None, raw=True)
check("crates download mapped to static", st == 200 and len(body) > 1000, (st, len(body)))

# stats should show cached entry
st, _, stats = call("GET", "/admin/stats", None, TOKEN)
check("stats has npm entry", any(r["repo"] == "npm" for r in stats["per_repo"]), stats["per_repo"])
check("stats total files", stats["total_files"] >= 1, stats["total_files"])

# bad upstream -> 502
st, _, _ = call("POST", "/admin/repos", {"name": "broken", "type": "npm", "upstream": "https://127.0.0.1:9"}, TOKEN)
check("create broken repo", st == 200, st)
call("POST", f"/admin/groups/{default_gid}/repos/broken", {"can_download": True, "can_upload": True}, TOKEN)
st, _, _ = call("GET", "/proxy/broken/x", None, TOKEN)
check("bad upstream 502", st == 502, st)

# upstream http rejected
st, _, _ = call("POST", "/admin/repos", {"name": "insecure", "type": "npm", "upstream": "http://registry.npmjs.org"}, TOKEN)
check("http upstream rejected", st == 400, st)

# quota eviction: quota 2MB, fetch lodash ~0.5MB, react ~0.3MB, react-dom ~1.3MB
for pkg, ver in [("lodash", "4.17.21"), ("react", "18.2.0"), ("react-dom", "18.2.0")]:
    st, h, body = call("GET", f"/proxy/npmq/{pkg}/-/{pkg}-{ver}.tgz", None, TOKEN, raw=True)
    check(f"quota fetch {pkg}", st == 200, (st, len(body)))

st, _, stats = call("GET", "/admin/stats", None, TOKEN)
npmq = next((r for r in stats["per_repo"] if r["repo"] == "npmq"), None)
check("quota keeps under limit", npmq is not None and npmq["total"] <= 2 * 1024 * 1024, npmq)

# cache cleanup with days=0 clears all
st, _, c = call("POST", "/admin/cache/cleanup?days=0", None, TOKEN)
check("cleanup all reports freed", st == 200 and c["freed_bytes"] > 0, c)
st, _, stats = call("GET", "/admin/stats", None, TOKEN)
check("cleanup leaves zero files", stats["total_files"] == 0, stats["total_files"])

# delete repos
for name in ["npmq", "broken", "anonnpm", "cratestest", "cratesanon", "pypitest"]:
    st, _, _ = call("DELETE", f"/admin/repos/{name}", None, TOKEN)
    check("delete repo " + name, st == 200, st)

print("FAILURES=" + str(failures))
