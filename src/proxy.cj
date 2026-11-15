package modernmirror

import std.collection.*
import std.fs.*
import std.io.*
import std.regex.*
import std.sync.*
import std.time.*
import std.convert.*
import stdx.encoding.json.*
import stdx.net.http.*
import stdx.net.tls.*

func buildProxyClient(host: String): Client {
    var tlsConfig = TlsClientConfig()
    // 部分 CDN(Fastly 等)要求 TLS 握手里带 SNI, 否则返回 421。
    // 标准库客户端不会按 URL 自动填 SNI, 这里按上游主机逐个配置并缓存。
    tlsConfig.domain = Some(host)
    return ClientBuilder()
        .autoRedirect(false)
        .readTimeout(Duration.second * 60)
        .writeTimeout(Duration.second * 60)
        .tlsConfig(tlsConfig)
        .build()
}

let PROXY_CLIENTS = HashMap<String, Client>()
let PROXY_CLIENT_LOCK = Mutex()

func urlHostName(url: String): String {
    match (url.indexOf("://")) {
        case Some(s) =>
            let rest = url[s + 3..]
            var host = rest
            match (rest.indexOf("/")) {
                case Some(i) => host = rest[0..i]
                case None => ()
            }
            match (host.lastIndexOf(":")) {
                case Some(p) => host = host[0..p]
                case None => ()
            }
            return host
        case None => return ""
    }
}

func proxyClientFor(url: String): Client {
    let host = urlHostName(url)
    synchronized(PROXY_CLIENT_LOCK) {
        match (PROXY_CLIENTS.get(host)) {
            case Some(c) => return c
            case None => ()
        }
        let client = buildProxyClient(host)
        PROXY_CLIENTS.add(host, client)
        return client
    }
}

let VERIFY_CACHE = HashMap<String, HashMap<String, (String, String)>>()
let VERIFY_LOCK = Mutex()

class RangeBody <: InputStream {
    let file: File
    var remaining: Int64
    var closed: Bool = false

    init(path: String, start: Int64, length: Int64) {
        file = File(path, OpenMode.Read)
        if (start > 0) {
            file.seek(SeekPosition.Begin(start))
        }
        remaining = length
    }

    public func read(buffer: Array<UInt8>): Int64 {
        if (closed || remaining <= 0) {
            return 0
        }
        if (Int64(buffer.size) <= remaining) {
            let got = file.read(buffer)
            if (got > 0) {
                remaining = remaining - got
            }
            return got
        }
        let tmp = Array<UInt8>(remaining, repeat: 0)
        let got = file.read(tmp)
        if (got > 0) {
            tmp.copyTo(buffer, 0, 0, got)
            remaining = remaining - got
        }
        return got
    }

    public func close(): Unit {
        if (!closed) {
            closed = true
            file.close()
        }
    }
}

func cacheGet(key: String): HashMap<String, (String, String)> {
    synchronized(VERIFY_LOCK) {
        return match (VERIFY_CACHE.get(key)) {
            case Some(v) => v
            case None =>
                if (VERIFY_CACHE.size > 256) {
                    VERIFY_CACHE.clear()
                }
                let fresh = HashMap<String, (String, String)>()
                VERIFY_CACHE.add(key, fresh)
                fresh
        }
    }
}

func resolveRedirect(base: String, location: String): String {
    if (location.startsWith("http://") || location.startsWith("https://")) {
        return location
    }
    match (base.indexOf("://")) {
        case Some(s) =>
            let rest = base[s + 3..]
            let hostEnd = match (rest.indexOf("/")) {
                case Some(i) => s + 3 + i
                case None => base.size
            }
            let origin = base[0..hostEnd]
            if (location.startsWith("/")) {
                return origin + location
            }
            let dir = match (base.lastIndexOf("/")) {
                case Some(i) => base[0..i]
                case None => base
            }
            return dir + "/" + location
        case None => return location
    }
}

// 手动跟随 302/307 等跳转: 每个跳转目标都按它自己的主机重新建立 TLS 连接并带正确 SNI。
// 这样 api.nuget.org -> nuget.azure.cn -> globalcdn.nuget.org 这类跨域跳转才能正常工作。
func upstreamGet(url: String, ifNoneMatch!: String = "", ifModifiedSince!: String = "",
                 range!: String = "", userAgent!: String = "", head!: Bool = false): HttpResponse {
    var current = url
    var hop = 0
    while (hop <= 5) {
        var builder = HttpRequestBuilder()
        if (head) {
            builder.head()
        } else {
            builder.get()
        }
        builder.url(current)
        if (!ifNoneMatch.isEmpty()) {
            builder.header("If-None-Match", ifNoneMatch)
        }
        if (!ifModifiedSince.isEmpty()) {
            builder.header("If-Modified-Since", ifModifiedSince)
        }
        if (!range.isEmpty()) {
            builder.header("Range", range)
        }
        if (!userAgent.isEmpty()) {
            builder.header("User-Agent", userAgent)
        }
        let resp = proxyClientFor(current).send(builder.build())
        if (resp.status >= 300 && resp.status < 400 && resp.status != 304) {
            let location = respHeader(resp, "location")
            if (location.isEmpty()) {
                return resp
            }
            current = resolveRedirect(current, location)
            hop = hop + 1
            continue
        }
        return resp
    }
    throw HttpError(502, "too many upstream redirects")
}

func expectedPypiHash(repo: DbRow, fname: String): ?(String, String) {
    var pkg = fname
    let dash = pkg.indexOf("-")
    match (dash) {
        case Some(i) => pkg = pkg[0..i]
        case None => ()
    }
    let under = pkg.indexOf("_")
    match (under) {
        case Some(i) => pkg = pkg[0..i]
        case None => ()
    }
    let dot = pkg.indexOf(".")
    match (dot) {
        case Some(i) => pkg = pkg[0..i]
        case None => ()
    }
    pkg = pkg.toAsciiLower()
    let key = "pypi:" + vText(repo, "name") + ":" + pkg
    let table = cacheGet(key)
    synchronized(VERIFY_LOCK) {
        if (table.size == 0) {
            try {
                var base = vText(repo, "upstream")
                while (base.endsWith("/")) {
                    base = base[0..base.size - 1]
                }
                let resp = upstreamGet(base + "/simple/" + pkg + "/")
                let text = String.fromUtf8(readAllStreaming(resp.body, 64 * 1024 * 1024))
                let pattern = Regex("href=\"[^\"]*/([^/\"#]+)#(?:sha256=([A-Za-z0-9]{64})|md5=([a-f0-9]{32}))")
                for (m in pattern.findAll(text, group: true)) {
                    let name = m.matchString(1)
                    let sha = m.matchString(2)
                    let md5 = m.matchString(3)
                    if (!name.isEmpty() && (!sha.isEmpty() || !md5.isEmpty())) {
                        if (!sha.isEmpty()) {
                            table.add(name, ("sha256", sha))
                        } else {
                            table.add(name, ("md5", md5))
                        }
                    }
                }
            } catch (e: Exception) {
                (e)
            }
        }
        return table.get(fname)
    }
}

func expectedNpmHash(repo: DbRow, fname: String): ?(String, String) {
    var pkg = fname
    try {
        let pattern = Regex("^([@][^/]+/[^/]+|[^@/]+?)-[0-9]+\\.[0-9]+")
        let found = pattern.find(fname, group: true)
        match (found) {
            case Some(m) => pkg = m.matchString(1)
            case None => ()
        }
    } catch (e: Exception) {
        (e)
    }
    let key = "npm:" + vText(repo, "name") + ":" + pkg
    let table = cacheGet(key)
    synchronized(VERIFY_LOCK) {
        if (table.size == 0) {
            try {
                var base = vText(repo, "upstream")
                while (base.endsWith("/")) {
                    base = base[0..base.size - 1]
                }
                let resp = upstreamGet(base + "/" + pkg)
                let text = String.fromUtf8(readAllStreaming(resp.body, 64 * 1024 * 1024))
                match (jsonParseObject(text)) {
                    case Some(root) =>
                        match (root.get("versions")) {
                            case Some(versions) =>
                                match (versions.kind()) {
                                    case JsonKind.JsObject =>
                                    for ((_, info) in versions.asObject().getFields()) {
                                        match (info.kind()) {
                                            case JsonKind.JsObject =>
                                            let dist = info.asObject().get("dist")
                                            match (dist) {
                                                case Some(d) =>
                                                    match (d.kind()) {
                                                    case JsonKind.JsObject =>
                                                        let tarball = jsonGetString(d.asObject(), "tarball")
                                                        let integrity = jsonGetString(d.asObject(), "integrity")
                                                        var tarName = tarball
                                                        let slash = tarName.lastIndexOf("/")
                                                        match (slash) {
                                                            case Some(i) => tarName = tarName[i + 1..]
                                                            case None => ()
                                                        }
                                                        if (!tarName.isEmpty() && integrity.startsWith("sha512-")) {
                                                            table.add(tarName, ("sha512", integrity[7..]))
                                                        }
                                                    case _ => ()
                                                    }
                                                case None => ()
                                            }
                                            case _ => ()
                                        }
                                    }
                                    case _ => ()
                                }
                            case None => ()
                        }
                    case None => ()
                }
            } catch (e: Exception) {
                (e)
            }
        }
        return table.get(fname)
    }
}

func verifyMetadata(repoName: String, path: String, filePath: String, ip: String): Bool {
    let repo = getRepo(repoName)
    let fname = baseName(path)
    var expected: ?(String, String) = None
    try {
        let repoType = vText(repo, "type")
        if (repoType == "pypi" && (fname.endsWith(".whl") || fname.endsWith(".tar.gz") ||
            fname.endsWith(".zip") || fname.endsWith(".egg") || fname.endsWith(".bz2"))) {
            expected = expectedPypiHash(repo, fname)
        } else if (repoType == "npm" && fname.endsWith(".tgz")) {
            expected = expectedNpmHash(repo, fname)
        }
    } catch (e: Exception) {
        expected = None
    }
    match (expected) {
        case Some(pair) =>
            let algo = pair[0]
            let digest = pair[1]
            var got = ""
            if (algo == "sha256") {
                got = fileSha256(filePath)
            } else if (algo == "md5") {
                got = fileMd5(filePath)
            } else {
                got = fileSha512B64(filePath)
            }
            if (got != digest) {
                let detail = jObj()
                detail.put("repo", jStr(repoName))
                detail.put("file", jStr(path))
                detail.put("expected", jStr(algo + ":" + digest))
                detail.put("got", jStr(got))
                audit("verify.fail", ip, detail)
                throw HttpError(502, "上游返回的 " + algo + " 校验不匹配, 已拒绝缓存 (疑似投毒或篡改): " + path)
            }
            return true
        case None =>
            let detail = jObj()
            detail.put("repo", jStr(repoName))
            detail.put("file", jStr(path))
            detail.put("detail", jStr("upstream metadata offered no checksum for this file"))
            audit("verify.skipped", ip, detail)
            return false
    }
}

func upstreamUrls(repo: DbRow): ArrayList<String> {
    let out = ArrayList<String>()
    let raw = vText(repo, "upstreams")
    if (!raw.isEmpty()) {
        try {
            let value = JsonValue.fromStr(raw)
            match (value.kind()) {
                case JsonKind.JsArray =>
                    for (item in value.asArray().getItems()) {
                        match (item.kind()) {
                            case JsonKind.JsString =>
                                var url = item.asString().getValue().trimAscii()
                                while (url.endsWith("/")) {
                                    url = url[0..url.size - 1]
                                }
                                if (!url.isEmpty()) {
                                    out.add(url)
                                }
                            case _ => ()
                        }
                    }
                case _ => ()
            }
        } catch (e: Exception) {
            (e)
        }
    }
    if (out.size == 0) {
        let fallback = vText(repo, "upstream")
        if (!fallback.isEmpty()) {
            var url = fallback
            while (url.endsWith("/")) {
                url = url[0..url.size - 1]
            }
            out.add(url)
        }
    }
    return out
}

func getRepo(repoName: String): DbRow {
    let row = db().queryOne("SELECT * FROM repos WHERE name=? AND enabled=1", [DbText(repoName)])
    match (row) {
        case Some(r) => return r
        case None => throw HttpError(404, "repo '" + repoName + "' not found or disabled")
    }
}

func originOf(url: String): String {
    match (url.indexOf("://")) {
        case Some(s) =>
            let rest = url[s + 3..]
            return match (rest.indexOf("/")) {
                case Some(j) => url[0..s + 3 + j]
                case None => url
            }
        case None => return ""
    }
}

func trimTrailingSlash(value: String): String {
    var out = value
    while (out.endsWith("/")) {
        out = out[0..out.size - 1]
    }
    return out
}

// 用户常把 PyPI 上游写成 https://host/simple, 而代理路径本身已经包含 /simple/,
// 这里统一去掉重复后缀, 避免请求变成 /simple/simple/。
func pypiBase(url: String): String {
    var out = trimTrailingSlash(url)
    if (out.endsWith("/simple")) {
        out = trimTrailingSlash(out[0..out.size - 7])
    }
    return out
}

// 取上游基地址; crates 的 sparse 索引与 .crate 文件分属不同主机,
// 索引侧把 dl 指向本代理的 /crates/ 路径, 这里再映射回 static.crates.io。
// PyPI 官方索引里的包文件地址指向 files.pythonhosted.org, 与主站不同主机,
// 因此 /packages/ 路径需要映射到文件主机; 其他镜像仍使用镜像自身的包路径。
func proxyUpstreamBases(repoRow: DbRow, subPath: String): ArrayList<String> {
    let rtype = vText(repoRow, "type")
    if (rtype == "crates" && subPath.startsWith("crates/")) {
        let out = ArrayList<String>()
        out.add("https://static.crates.io")
        return out
    }
    let urls = upstreamUrls(repoRow)
    if (rtype != "pypi") {
        return urls
    }
    let out = ArrayList<String>()
    for (u in urls) {
        let base = pypiBase(u)
        if (subPath.startsWith("packages/") && originOf(base) == "https://pypi.org") {
            out.add("https://files.pythonhosted.org")
        } else {
            out.add(base)
        }
    }
    return out
}

func proxyBaseUrl(ctx: HttpContext, repoName: String): String {
    let host = headerOrEmpty(ctx.request, "host")
    var proto = headerOrEmpty(ctx.request, "x-forwarded-proto").trimAscii()
    if (proto.isEmpty()) {
        proto = "http"
    }
    return proto + "://" + host + "/proxy/" + repoName
}

func upstreamOrigins(urls: ArrayList<String>): ArrayList<String> {
    let out = ArrayList<String>()
    for (u in urls) {
        let origin = originOf(u)
        if (!origin.isEmpty()) {
            out.add(origin)
        }
    }
    return out
}

func rewriteCratesConfig(raw: String, base: String, needAuth: Bool): String {
    match (jsonParseObject(raw)) {
        case Some(obj) =>
            obj.put("dl", jStr(base + "/crates"))
            obj.put("auth-required", jBool(needAuth))
            return compactJson(obj)
        case None => return raw
    }
}

func needsProxyRewrite(repoRow: DbRow, path: String, contentType: String): Bool {
    let rtype = vText(repoRow, "type")
    let ct = contentType.toAsciiLower()
    if (rtype == "pypi") {
        // simple 索引是 HTML, JSON API 也可能被前端工具使用
        return ct.contains("html") || ct.contains("json")
    }
    if (rtype != "npm" && rtype != "pub" && rtype != "nuget" && rtype != "crates") {
        return false
    }
    if (rtype == "crates") {
        return path == "config.json"
    }
    return ct.contains("json")
}

// 把上游元数据里的绝对地址改写回本代理, 让客户端后续的包文件请求仍然经过缓存。
func rewriteProxyFile(ctx: HttpContext, repoRow: DbRow, repoName: String, path: String,
                      contentType: String, filePath: String, size: Int64): Int64 {
    if (!needsProxyRewrite(repoRow, path, contentType)) {
        return size
    }
    if (size <= 0 || size > 64 * 1024 * 1024) {
        return size
    }
    try {
        let raw = readAllBytes(filePath)
        let text = String.fromUtf8(raw)
        let base = proxyBaseUrl(ctx, repoName)
        let rtype = vText(repoRow, "type")
        var out = text
        if (rtype == "crates") {
            out = rewriteCratesConfig(text, base, vInt(repoRow, "anonymous") != 1)
        } else {
            if (rtype == "pypi") {
                out = out.replace("https://files.pythonhosted.org", base)
            }
            for (origin in upstreamOrigins(upstreamUrls(repoRow))) {
                out = out.replace(origin, base)
            }
            if (rtype == "npm") {
                out = out.replace("https://registry.npmjs.org", base)
            } else if (rtype == "nuget") {
                out = out.replace("https://api.nuget.org", base)
                out = out.replace("https://nuget.azure.cn", base)
            } else if (rtype == "pub") {
                out = out.replace("https://pub.dev", base)
            }
        }
        if (out == text) {
            return size
        }
        // 临时文件已经存在, writeAllBytes 用 File.create 会失败, 因此先写旁路文件再原子替换。
        let bytes = out.toArray()
        let rwTmp = filePath + ".rw"
        writeAllBytes(rwTmp, bytes)
        moveFile(rwTmp, filePath)
        return Int64(bytes.size)
    } catch (e: Exception) {
        return size
    }
}

func handleProxy(ctx: HttpContext, ip: String, path: String, head: Bool): Unit {
    let parts = routeSegments(path)
    if (parts.size < 3) {
        throw HttpError(404, "Not Found")
    }
    let repo = parts[1]
    if (repo.startsWith(".")) {
        throw HttpError(400, "invalid repo name")
    }
    let subPath = joinSegments(parts, 2)
    let repoRow = getRepo(repo)
    requireProxyAccess(ctx, ip, repo, repoRow)
    let urls = ArrayList<String>()
    for (base in proxyUpstreamBases(repoRow, subPath)) {
        urls.add(base + "/" + subPath)
    }
    let range = headerOrEmpty(ctx.request, "range")
    let userAgent = headerOrEmpty(ctx.request, "user-agent")
    if (head) {
        proxyHead(ctx, repo, subPath, urls, range, userAgent)
        return
    }
    let entry = db().queryOne("SELECT * FROM cache_entries WHERE repo=? AND path=?",
        [DbText(repo), DbText(subPath)])
    match (entry) {
        case Some(e) =>
            if (fileExists(vText(e, "file_path"))) {
                var current = e
                if (vInt(current, "verified") == 0) {
                    verifyMetadata(repo, subPath, vText(current, "file_path"), ip)
                    db().execParams("UPDATE cache_entries SET verified=1 WHERE id=?",
                        [DbInt(vInt(current, "id"))])
                    match (db().queryOne("SELECT * FROM cache_entries WHERE repo=? AND path=?",
                        [DbText(repo), DbText(subPath)])) {
                        case Some(fresh) => current = fresh
                        case None => ()
                    }
                }
                let etag = vText(current, "etag")
                if (!etag.isEmpty()) {
                    var check: ?HttpResponse = None
                    for (u in urls) {
                        try {
                            let candidate = upstreamGet(u, ifNoneMatch: etag, head: true)
                            if (candidate.status < 500) {
                                check = Some(candidate)
                                break
                            }
                        } catch (e2: Exception) {
                            (e2)
                        }
                    }
                    match (check) {
                        case Some(r) =>
                            if (r.status == 304) {
                                respondCached(ctx, hitEntry(current, "revalidated"), head, range, cacheStatus: "revalidated")
                                return
                            }
                            if (r.status == 200) {
                                let newEtag = respHeader(r, "etag")
                                if (!newEtag.isEmpty() && newEtag != etag) {
                                    downloadAndRespond(ctx, urls, repo, subPath, ip, head, range, userAgent)
                                    return
                                }
                            }
                        case None => ()
                    }
                }
                respondCached(ctx, hitEntry(current, "hit"), head, range, cacheStatus: "hit")
                return
            }
        case None => ()
    }
    downloadAndRespond(ctx, urls, repo, subPath, ip, head, range, userAgent)
}

func proxyHead(ctx: HttpContext, repo: String, subPath: String, urls: ArrayList<String>,
               range: String, userAgent: String): Unit {
    let entry = db().queryOne("SELECT * FROM cache_entries WHERE repo=? AND path=?",
        [DbText(repo), DbText(subPath)])
    match (entry) {
        case Some(e) =>
            if (fileExists(vText(e, "file_path"))) {
                respondCached(ctx, hitEntry(e, "hit"), true, range, cacheStatus: "hit")
                return
            }
        case None => ()
    }
    var lastError = ""
    for (u in urls) {
        try {
            let resp = upstreamGet(u, range: range, userAgent: userAgent, head: true)
            if (resp.status < 500) {
                if (resp.status >= 400) {
                    throw HttpError(resp.status, "upstream returned " + resp.status.toString())
                }
                corsHeaders(ctx.responseBuilder.status(resp.status)
                    .header("content-type", respHeader(resp, "content-type"))
                    .header("x-cache-status", "fresh"))
                let etag = respHeader(resp, "etag")
                if (!etag.isEmpty()) {
                    ctx.responseBuilder.header("ETag", etag)
                }
                let length = respHeader(resp, "content-length")
                if (!length.isEmpty()) {
                    ctx.responseBuilder.header("content-length", length)
                }
                ctx.responseBuilder.body("")
                return
            }
            lastError = "HTTP " + resp.status.toString()
        } catch (e: Exception) {
            lastError = e.message
        }
    }
    throw HttpError(502, "upstream error: " + (if (lastError.isEmpty()) { "unreachable" } else { lastError }))
}

func respHeader(resp: HttpResponse, name: String): String {
    return match (resp.headers.getFirst(name)) {
        case Some(v) => v
        case None => ""
    }
}

func hitEntry(entry: DbRow, kind: String): DbRow {
    db().execParams(
        "UPDATE cache_entries SET hits=hits+1, last_hit_at=datetime('now', 'localtime') WHERE id=?",
        [DbInt(vInt(entry, "id"))])
    return entry
}

func respondCached(ctx: HttpContext, entry: DbRow, head: Bool, range: String,
                   cacheStatus!: String = "hit"): Unit {
    if (!range.isEmpty()) {
        respondRange(ctx, entry, range, cacheStatus)
        return
    }
    let filePath = vText(entry, "file_path")
    let contentType = vText(entry, "content_type")
    let media = if (contentType.isEmpty()) { "application/octet-stream" } else { contentType }
    corsHeaders(ctx.responseBuilder.status(200)
        .header("content-type", media)
        .header("accept-ranges", "bytes")
        .header("content-length", vInt(entry, "size").toString())
        .header("x-cache-status", cacheStatus))
    let etag = vText(entry, "etag")
    if (!etag.isEmpty()) {
        ctx.responseBuilder.header("ETag", etag)
    }
    if (head) {
        ctx.responseBuilder.body("")
    } else {
        ctx.responseBuilder.body(FileBody(filePath))
    }
}

func respondRange(ctx: HttpContext, entry: DbRow, rangeHeader: String, cacheStatus: String): Unit {
    let size = vInt(entry, "size")
    var start: Int64 = 0
    var end: Int64 = size - 1
    var valid = false
    try {
        let pattern = Regex("bytes=([0-9]*)-([0-9]*)")
        let found = pattern.find(rangeHeader, group: true)
        match (found) {
            case Some(m) =>
                let first = m.matchString(1)
                let second = m.matchString(2)
                if (!first.isEmpty()) {
                    start = Int64.parse(first)
                    if (!second.isEmpty()) {
                        end = Int64.parse(second)
                    }
                    valid = true
                } else if (!second.isEmpty()) {
                    let suffix = Int64.parse(second)
                    start = size - suffix
                    if (start < 0) {
                        start = 0
                    }
                    end = size - 1
                    valid = true
                }
            case None => ()
        }
    } catch (e: Exception) {
        valid = false
    }
    if (!valid) {
        respondCached(ctx, entry, false, "", cacheStatus: cacheStatus)
        return
    }
    if (end > size - 1) {
        end = size - 1
    }
    if (start > end || start >= size) {
        corsHeaders(ctx.responseBuilder.status(416)
            .header("content-range", "bytes */" + size.toString())
            .header("x-cache-status", cacheStatus))
        ctx.responseBuilder.body("")
        return
    }
    let length = end - start + 1
    let media = if (vText(entry, "content_type").isEmpty()) {
        "application/octet-stream"
    } else {
        vText(entry, "content_type")
    }
    corsHeaders(ctx.responseBuilder.status(206)
        .header("content-type", media)
        .header("content-range", "bytes " + start.toString() + "-" + end.toString() + "/" + size.toString())
        .header("accept-ranges", "bytes")
        .header("content-length", length.toString())
        .header("x-cache-status", cacheStatus))
    ctx.responseBuilder.body(RangeBody(vText(entry, "file_path"), start, length))
}

func downloadAndRespond(ctx: HttpContext, targets: ArrayList<String>, repoName: String, path: String,
                        ip: String, head: Bool, range: String, userAgent: String): Unit {
    let ifNoneMatch = headerOrEmpty(ctx.request, "if-none-match")
    let ifModifiedSince = headerOrEmpty(ctx.request, "if-modified-since")
    var resp: ?HttpResponse = None
    var lastError = ""
    var upstreamUrl = ""
    for (u in targets) {
        try {
            // 冷缓存时必须取完整文件: 若把 Range 透传给上游, 只会拿到 206 分段,
            // 随后会被当作完整文件校验和缓存, 导致哈希校验失败或缓存损坏。
            let candidate = upstreamGet(u, ifNoneMatch: ifNoneMatch,
                ifModifiedSince: ifModifiedSince, userAgent: userAgent)
            if (candidate.status < 500) {
                resp = Some(candidate)
                upstreamUrl = u
                break
            }
            lastError = "HTTP " + candidate.status.toString()
        } catch (e: Exception) {
            lastError = e.message
        }
    }
    match (resp) {
        case None =>
            let entry = db().queryOne("SELECT * FROM cache_entries WHERE repo=? AND path=?",
                [DbText(repoName), DbText(path)])
            match (entry) {
                case Some(e) =>
                    if (fileExists(vText(e, "file_path"))) {
                        respondCached(ctx, hitEntry(e, "stale"), head, range, cacheStatus: "stale")
                        return
                    }
                case None => ()
            }
            throw HttpError(502, "upstream error: " + (if (lastError.isEmpty()) { "unreachable" } else { lastError }))
        case Some(r) =>
            if (r.status >= 300 && r.status < 400 && r.status != 304) {
                let location = respHeader(r, "location")
                if (!location.isEmpty()) {
                    var newUrl = location
                    if (!newUrl.startsWith("http")) {
                        let slash = upstreamUrl.lastIndexOf("/")
                        let base = match (slash) {
                            case Some(i) => upstreamUrl[0..i]
                            case None => upstreamUrl
                        }
                        var rel = newUrl
                        while (rel.startsWith("/")) {
                            rel = rel[1..]
                        }
                        newUrl = base + "/" + rel
                    }
                    let next = ArrayList<String>()
                    next.add(newUrl)
                    downloadAndRespond(ctx, next, repoName, path, ip, head, range, userAgent)
                    return
                }
            }
            if (r.status >= 400) {
                throw HttpError(r.status, "upstream returned " + r.status.toString())
            }
            if (r.status == 304) {
                let entry = db().queryOne("SELECT * FROM cache_entries WHERE repo=? AND path=?",
                    [DbText(repoName), DbText(path)])
                match (entry) {
                    case Some(e) =>
                        if (fileExists(vText(e, "file_path"))) {
                            respondCached(ctx, hitEntry(e, "hit"), head, range, cacheStatus: "hit")
                            return
                        }
                    case None => ()
                }
                throw HttpError(404, "not cached")
            }
            let contentType = respHeader(r, "content-type")
            let etag = respHeader(r, "etag")
            let maxBytes = MAX_UPSTREAM_MB * 1024 * 1024
            let declared = respHeader(r, "content-length")
            if (!declared.isEmpty()) {
                match (Int64.tryParse(declared)) {
                    case Some(n) =>
                        if (n > maxBytes) {
                            throw HttpError(502, "upstream file too large (> " + MAX_UPSTREAM_MB.toString() + "MB)")
                        }
                    case None => ()
                }
            }
            let tmp = joinPath(tmpDir(), "dl-" + randomHex(12))
            var size: Int64 = 0
            let outFile = File.create(tmp)
            let buffer = Array<Byte>(262144, repeat: 0)
            try {
                while (true) {
                    let n = r.body.read(buffer)
                    if (n <= 0) {
                        break
                    }
                    size = size + n
                    if (size > maxBytes) {
                        throw HttpError(502, "upstream file too large (> " + MAX_UPSTREAM_MB.toString() + "MB)")
                    }
                    outFile.write(buffer[0..n])
                }
            } catch (e: HttpError) {
                outFile.close()
                deleteFileIfExists(tmp)
                throw e
            } catch (e: Exception) {
                outFile.close()
                deleteFileIfExists(tmp)
                throw HttpError(502, "upstream read error")
            } finally {
                try {
                    outFile.close()
                } catch (e: Exception) {
                    (e)
                }
            }
            let repoRow = getRepo(repoName)
            size = rewriteProxyFile(ctx, repoRow, repoName, path, contentType, tmp, size)
            var savedPath = ""
            try {
                verifyMetadata(repoName, path, tmp, ip)
                savedPath = saveCachedFile(tmp, repoName, path)
            } catch (e: Exception) {
                deleteFileIfExists(tmp)
                throw e
            }
            let typeValue = if (contentType.isEmpty()) { "application/octet-stream" } else { contentType }
            db().execParams(
                "INSERT INTO cache_entries (repo, path, upstream_url, file_path, size, " +
                "content_type, etag, fetched_at, last_hit_at, hits, verified) " +
                "VALUES (?,?,?,?,?,?,?,datetime('now', 'localtime'),datetime('now', 'localtime'),0,?) " +
                "ON CONFLICT(repo, path) DO UPDATE SET " +
                "upstream_url=excluded.upstream_url, file_path=excluded.file_path, " +
                "size=excluded.size, content_type=excluded.content_type, " +
                "etag=excluded.etag, fetched_at=datetime('now', 'localtime'), verified=?",
                [DbText(repoName), DbText(path), DbText(upstreamUrl), DbText(savedPath),
                 DbInt(size), DbText(typeValue), DbText(etag), DbInt(1), DbInt(1)])
            let quota = vInt(repoRow, "quota_mb")
            if (quota > 0) {
                enforceQuota(repoName, quota)
            }
            let fresh = db().queryOne("SELECT * FROM cache_entries WHERE repo=? AND path=?",
                [DbText(repoName), DbText(path)])
            let entry = match (fresh) {
                case Some(f) => f
                case None =>
                    let fallback = DbRow()
                    fallback.add("file_path", DbText(savedPath))
                    fallback.add("size", DbInt(size))
                    fallback.add("content_type", DbText(typeValue))
                    fallback.add("etag", DbText(etag))
                    fallback
            }
            if (head) {
                respondCached(ctx, entry, true, range, cacheStatus: "fresh")
            } else if (!range.isEmpty()) {
                respondRange(ctx, entry, range, "fresh")
            } else {
                respondCached(ctx, entry, false, "", cacheStatus: "fresh")
            }
    }
}
