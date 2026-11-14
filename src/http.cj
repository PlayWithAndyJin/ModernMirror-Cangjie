package modernmirror

import std.collection.*
import std.fs.*
import std.io.*
import std.convert.*
import stdx.encoding.json.*
import stdx.net.http.*

class RouteDistributor <: HttpRequestDistributor {
    public init() {}

    public func register(path: String, handler: HttpRequestHandler): Unit {
        ()
    }

    public func distribute(path: String): HttpRequestHandler {
        return FuncHandler({ctx => handleRequest(ctx)})
    }
}

class MultipartPart {
    let name: String
    let filename: String
    let data: Array<Byte>

    init(name: String, filename: String, data: Array<Byte>) {
        this.name = name
        this.filename = filename
        this.data = data
    }
}

func corsHeaders(builder: HttpResponseBuilder): HttpResponseBuilder {
    builder.header("Access-Control-Allow-Origin", "*")
    builder.header("Access-Control-Allow-Methods", "GET, HEAD, POST, PUT, DELETE, OPTIONS")
    builder.header("Access-Control-Allow-Headers", "*")
    builder.header("Access-Control-Expose-Headers", "X-Cache-Status, Content-Range, ETag")
    return builder
}

func respondJson(ctx: HttpContext, status: UInt16, value: JsonValue): Unit {
    corsHeaders(ctx.responseBuilder.status(status).header("content-type", "application/json"))
    ctx.responseBuilder.body(compactJson(value))
}

func respondJsonObject(ctx: HttpContext, status: UInt16, value: JsonObject): Unit {
    respondJson(ctx, status, value)
}

func respondJsonArray(ctx: HttpContext, status: UInt16, value: JsonArray): Unit {
    respondJson(ctx, status, value)
}

func respondText(ctx: HttpContext, status: UInt16, text: String, contentType!: String = "text/plain; charset=utf-8"): Unit {
    corsHeaders(ctx.responseBuilder.status(status).header("content-type", contentType))
    ctx.responseBuilder.body(text)
}

func respondError(ctx: HttpContext, status: UInt16, detail: String): Unit {
    let obj = jObj()
    obj.put("detail", jStr(detail))
    respondJsonObject(ctx, status, obj)
}

func respondOk(ctx: HttpContext): Unit {
    let obj = jObj()
    obj.put("ok", jBool(true))
    respondJsonObject(ctx, 200, obj)
}

func headerOrEmpty(req: HttpRequest, name: String): String {
    return match (req.headers.getFirst(name)) {
        case Some(v) => v
        case None => ""
    }
}

func queryValue(req: HttpRequest, name: String, def!: String = ""): String {
    return match (req.url.queryForm.get(name)) {
        case Some(v) => v
        case None => def
    }
}

func queryInt(req: HttpRequest, name: String, def!: Int64 = 0): Int64 {
    let raw = queryValue(req, name)
    if (raw.isEmpty()) {
        return def
    }
    return match (Int64.tryParse(raw.trimAscii())) {
        case Some(v) => v
        case None => def
    }
}

func readRequestBody(req: HttpRequest, limit: Int64): Array<Byte> {
    return readAllStreaming(req.body, limit)
}

func readJsonBody(req: HttpRequest): JsonObject {
    let raw = readRequestBody(req, 32 * 1024 * 1024)
    let text = String.fromUtf8(raw)
    return match (jsonParseObject(text)) {
        case Some(obj) => obj
        case None => throw HttpError(422, "请求内容不是合法的 JSON")
    }
}

func requireSession(ctx: HttpContext, ip: String): AuthCtx {
    let auth = authCtx(ctx.request)
    match (auth) {
        case Some(a) => return a
        case None =>
            auditFail(ip)
            throw HttpError(401, "login required")
    }
}

func requireAdmin(ctx: HttpContext, ip: String): AuthCtx {
    let a = requireSession(ctx, ip)
    if (!a.isAdmin) {
        throw HttpError(403, "admin required")
    }
    if (!mfaEnforcedOk(a)) {
        throw HttpError(403, "mfa required")
    }
    return a
}

func requireRepoPermission(ctx: HttpContext, ip: String, repo: String, perm: String): AuthCtx {
    let a = requireSession(ctx, ip)
    if (!canAccess(a, repo, perm)) {
        throw HttpError(403, "no " + perm + " permission on repo " + repo)
    }
    return a
}

func routeSegments(path: String): ArrayList<String> {
    let out = ArrayList<String>()
    for (part in path.split("/")) {
        if (!part.isEmpty()) {
            out.add(part)
        }
    }
    return out
}

func joinSegments(parts: ArrayList<String>, start: Int64): String {
    let sb = StringBuilder()
    var i = start
    while (i < parts.size) {
        if (i > start) {
            sb.append("/")
        }
        sb.append(parts[i])
        i = i + 1
    }
    return sb.toString()
}

func crlfBytes(): Array<Byte> {
    let value = Array<Byte>(4, repeat: 0)
    value[0] = 13
    value[1] = 10
    value[2] = 13
    value[3] = 10
    return value
}

func indexOfBytes(haystack: Array<Byte>, needle: Array<Byte>, from: Int64): Int64 {
    if (needle.size == 0 || haystack.size < needle.size) {
        return -1
    }
    var i = from
    let last = haystack.size - needle.size
    while (i <= last) {
        var ok = true
        for (j in 0..needle.size) {
            if (haystack[i + j] != needle[j]) {
                ok = false
                break
            }
        }
        if (ok) {
            return i
        }
        i = i + 1
    }
    return -1
}

func sliceBytes(data: Array<Byte>, start: Int64, end: Int64): Array<Byte> {
    var from = start
    var to = end
    if (from < 0) {
        from = 0
    }
    if (to > data.size) {
        to = data.size
    }
    if (to <= from) {
        return Array<Byte>()
    }
    return data[from..to].clone()
}

func headerParam(headerText: String, key: String): String {
    let lower = headerText.toAsciiLower()
    let marker = key.toAsciiLower() + "=\""
    let idx = lower.indexOf(marker)
    match (idx) {
        case Some(i) =>
            let start = i + marker.size
            let rest = headerText[start..]
            let end = rest.indexOf("\"")
            match (end) {
                case Some(e) => return rest[0..e]
                case None => return rest
            }
        case None => return ""
    }
}

func parseMultipart(req: HttpRequest, limit: Int64): ArrayList<MultipartPart> {
    let raw = readRequestBody(req, limit)
    let contentType = headerOrEmpty(req, "content-type")
    let marker = "boundary="
    let idx = contentType.indexOf(marker)
    var boundary = ""
    if (let Some(i) <- idx) {
        boundary = contentType[i + marker.size..]
        if (boundary.startsWith("\"")) {
            boundary = boundary[1..]
            let end = boundary.indexOf("\"")
            match (end) {
                case Some(e) => boundary = boundary[0..e]
                case None => ()
            }
        }
    }
    let parts = ArrayList<MultipartPart>()
    if (boundary.isEmpty()) {
        return parts
    }
    let delim = ("--" + boundary).toArray()
    var pos = indexOfBytes(raw, delim, 0)
    while (pos >= 0) {
        pos = pos + delim.size
        if (pos + 1 < raw.size && raw[pos] == 45 && raw[pos + 1] == 45) {
            break
        }
        if (pos + 1 < raw.size && raw[pos] == 13 && raw[pos + 1] == 10) {
            pos = pos + 2
        }
        let next = indexOfBytes(raw, delim, pos)
        if (next < 0) {
            break
        }
        var end = next
        if (end >= 2 && raw[end - 2] == 13 && raw[end - 1] == 10) {
            end = end - 2
        }
        var headerEnd = indexOfBytes(raw, crlfBytes(), pos)
        if (headerEnd < 0 || headerEnd > end) {
            headerEnd = end
        }
        let headerText = String.fromUtf8(sliceBytes(raw, pos, headerEnd))
        var dataStart = headerEnd
        if (headerEnd + 4 <= end) {
            dataStart = headerEnd + 4
        }
        let data = sliceBytes(raw, dataStart, end)
        var name = ""
        var filename = ""
        for (line in headerText.split("\r\n")) {
            let low = line.toAsciiLower()
            if (low.startsWith("content-disposition:")) {
                name = headerParam(line, "name")
                filename = headerParam(line, "filename")
            }
        }
        if (!name.isEmpty() || !filename.isEmpty()) {
            parts.add(MultipartPart(name, filename, data))
        }
        pos = next
    }
    return parts
}

func multipartFile(req: HttpRequest, limit: Int64): MultipartPart {
    for (part in parseMultipart(req, limit)) {
        if (!part.filename.isEmpty()) {
            return part
        }
    }
    throw HttpError(422, "请选择要上传的文件")
}

func frontendDist(): String {
    let candidates = ArrayList<String>()
    let fromEnv = envOr("MODERNMIRROR_DIST", "")
    if (!fromEnv.isEmpty()) {
        candidates.add(fromEnv)
    }
    candidates.add("frontend/dist")
    candidates.add("../frontend/dist")
    candidates.add("../../frontend/dist")
    for (candidate in candidates) {
        if (fileExists(joinPath(candidate, "index.html"))) {
            return candidate
        }
    }
    return ""
}

func mimeType(path: String): String {
    match (extName(path)) {
        case "html" => return "text/html; charset=utf-8"
        case "js" => return "text/javascript; charset=utf-8"
        case "mjs" => return "text/javascript; charset=utf-8"
        case "css" => return "text/css; charset=utf-8"
        case "json" => return "application/json"
        case "svg" => return "image/svg+xml"
        case "png" => return "image/png"
        case "jpg" => return "image/jpeg"
        case "jpeg" => return "image/jpeg"
        case "gif" => return "image/gif"
        case "ico" => return "image/x-icon"
        case "woff" => return "font/woff"
        case "woff2" => return "font/woff2"
        case "ttf" => return "font/ttf"
        case "map" => return "application/json"
        case "txt" => return "text/plain; charset=utf-8"
        case "md" => return "text/markdown; charset=utf-8"
        case _ => return "application/octet-stream"
    }
}

func safeRelativePath(rel: String): Bool {
    for (part in rel.split("/")) {
        if (part == "..") {
            return false
        }
    }
    return true
}

func serveFile(ctx: HttpContext, filePath: String, downloadName!: String = ""): Unit {
    if (!fileExists(filePath)) {
        throw HttpError(404, "not found")
    }
    let data = readAllBytes(filePath)
    corsHeaders(ctx.responseBuilder.status(200).header("content-type", mimeType(filePath)))
    if (!downloadName.isEmpty()) {
        ctx.responseBuilder.header("content-disposition", "attachment; filename=\"" + downloadName + "\"")
    }
    ctx.responseBuilder.body(data)
}

func serveStatic(ctx: HttpContext, rel: String): Unit {
    let dist = frontendDist()
    if (dist.isEmpty()) {
        throw HttpError(404, "static files not built")
    }
    if (!safeRelativePath(rel)) {
        throw HttpError(400, "invalid path")
    }
    var target = joinPath(dist, rel)
    if (!fileExists(target)) {
        target = joinPath(dist, "index.html")
    }
    serveFile(ctx, target)
}

func loadOptionalFile(path: String): String {
    if (!fileExists(path)) {
        return ""
    }
    return String.fromUtf8(readAllBytes(path))
}

func cookieValue(req: HttpRequest, name: String): String {
    let raw = headerOrEmpty(req, "cookie")
    if (raw.isEmpty()) {
        return ""
    }
    for (part in raw.split(";")) {
        let item = part.trimAscii()
        if (item.startsWith(name + "=")) {
            return item[name.size + 1..]
        }
    }
    return ""
}

func docsAllowed(ctx: HttpContext): (Bool, String) {
    let token = extractToken(ctx.request)
    match (authCtx(ctx.request)) {
        case Some(a) =>
            if (a.isAdmin) {
                if (a.hasUser()) {
                    return (true, sessionHash(token))
                }
                return (true, "")
            }
        case None => ()
    }
    let cookie = cookieValue(ctx.request, "modernmirror_docok")
    if (!cookie.isEmpty()) {
        let row = db().queryOne(
            "SELECT username FROM sessions WHERE token=? AND expires > datetime('now', 'localtime')",
            [DbText(cookie)])
        match (row) {
            case Some(s) =>
                match (getUserByName(vText(s, "username"))) {
                    case Some(u) =>
                        if (vText(u, "role") == "admin") {
                            return (true, "")
                        }
                    case None => ()
                }
            case None => ()
        }
    }
    return (false, "")
}

func handleRequest(ctx: HttpContext): Unit {
    let ip = clientIp(ctx.request)
    try {
        if (!rateLimitCheck(ip)) {
            throw HttpError(429, "太频繁, 触发限流")
        }
        routeRequest(ctx, ip)
    } catch (e: HttpError) {
        respondError(ctx, e.status, e.detail)
    } catch (e: Exception) {
        respondError(ctx, 500, "internal error")
    }
}

func routeRequest(ctx: HttpContext, ip: String): Unit {
    let req = ctx.request
    let method = req.method
    let path = req.url.path

    if (method == "OPTIONS") {
        corsHeaders(ctx.responseBuilder.status(204).header("content-length", "0"))
        return
    }

    if (path == "/api/health" && method == "GET") {
        let obj = jObj()
        obj.put("status", jStr("ok"))
        respondJsonObject(ctx, 200, obj)
        return
    }
    if (path == "/api/whoami" && method == "GET") {
        handleWhoami(ctx)
        return
    }
    if (path.startsWith("/auth/")) {
        handleAuthRoute(ctx, ip, path, method)
        return
    }
    if (path.startsWith("/admin/")) {
        handleAdminRoute(ctx, ip, path, method)
        return
    }
    if (path.startsWith("/templates/") && method == "GET") {
        handleTemplate(ctx, path)
        return
    }
    if (path == "/skill/modernmirror-config/SKILL.md" && method == "GET") {
        let a = requireSession(ctx, ip)
        let content = loadOptionalFile(joinPath("skills", "SKILL.md"))
        if (content.isEmpty()) {
            throw HttpError(404, "skill file not found")
        }
        respondText(ctx, 200, content, contentType: "text/markdown; charset=utf-8")
        return
    }
    if ((path == "/proxy" || path.startsWith("/proxy/")) && (method == "GET" || method == "HEAD")) {
        handleProxy(ctx, ip, path, method == "HEAD")
        return
    }
    if (path.startsWith("/pkg/") && method == "GET") {
        handlePackageDownload(ctx, ip, path)
        return
    }
    if ((path == "/simple" || path.startsWith("/simple/")) && method == "GET") {
        handleSimpleIndex(ctx, ip, path)
        return
    }
    if (path == "/docs" || path == "/redoc" || path == "/openapi.json") {
        let (allowed, cookieHash) = docsAllowed(ctx)
        if (!allowed) {
            throw HttpError(401, "管理员登录后才能访问接口文档")
        }
        if (!cookieHash.isEmpty()) {
            ctx.responseBuilder.header("Set-Cookie",
                "modernmirror_docok=" + cookieHash + "; Max-Age=3600; Path=/; HttpOnly; SameSite=Lax")
        }
        if (path == "/openapi.json") {
            respondJsonObject(ctx, 200, buildOpenApi())
        } else if (path == "/redoc") {
            respondText(ctx, 200, redocHtml(), contentType: "text/html; charset=utf-8")
        } else {
            respondText(ctx, 200, docsHtml(), contentType: "text/html; charset=utf-8")
        }
        return
    }
    if (path == "/" || path.isEmpty()) {
        corsHeaders(ctx.responseBuilder.status(302).header("location", "/ui/"))
        ctx.responseBuilder.body("")
        return
    }
    if (path == "/ui" || path.startsWith("/ui/")) {
        var rel = ""
        if (path.size > 4) {
            rel = path[4..]
        }
        if (rel.startsWith("/")) {
            rel = rel[1..]
        }
        if (rel.isEmpty()) {
            rel = "index.html"
        }
        serveStatic(ctx, rel)
        return
    }
    throw HttpError(404, "Not Found")
}

main(): Int64 {
    initConfig()
    dbInit()
    dbSeed()
    seedAdmin()
    migrateCryptoData()
    if (!cryptoInit()) {
        eprintln("警告 国密安全模块初始化失败 将使用仓颉标准库兜底")
    }
    ensureDir(CACHE_DIR)
    ensureDir(PRIVATE_DIR)
    startCleanupScheduler()
    if (ADMIN_TOKEN == "admin-token") {
        eprintln("!!! 警告 使用默认管理 Token admin-token，对外部署请设置 MODERNMIRROR_TOKEN 环境变量")
        auditEvent("startup.warn", "local")
    }
    if (MASTER_KEY_SOURCE == "generated") {
        eprintln("!!! 已自动生成数据安全主密钥 " + MASTER_KEY_PATH)
        eprintln("    该文件用于保护 MFA 密钥与审计日志，请务必备份且不要提交到版本库，丢失将无法恢复")
    }
    let server = ServerBuilder()
        .addr(if (HOST.isEmpty()) { "0.0.0.0" } else { HOST })
        .port(PORT)
        .distributor(RouteDistributor())
        .build()
    println("ModernMirror 仓颉后端已启动 http://" + HOST + ":" + PORT.toString())
    server.serve()
    cryptoCleanup()
    return 0
}
