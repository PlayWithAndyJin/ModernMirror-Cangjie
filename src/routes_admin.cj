package modernmirror

import std.collection.*
import std.regex.*
import std.fs.*
import std.convert.*
import stdx.encoding.json.*
import stdx.net.http.*

class MemberRow {
    let username: String
    let password: String
    let role: String
    let groups: String
    let hasRole: Bool

    init(username: String, password: String, role: String, groups: String, hasRole: Bool) {
        this.username = username
        this.password = password
        this.role = role
        this.groups = groups
        this.hasRole = hasRole
    }
}

func handleAdminRoute(ctx: HttpContext, ip: String, path: String, method: String): Unit {
    let sub = path[7..]
    if (sub == "users" && method == "GET") {
        adminListUsers(ctx, ip)
        return
    }
    if (sub == "users" && method == "POST") {
        adminAddUser(ctx, ip)
        return
    }
    if (sub.startsWith("users/")) {
        let rest = sub[6..]
        if (rest.endsWith("/reset-mfa") && method == "POST") {
            adminResetMfa(ctx, ip, rest[0..rest.size - 10])
            return
        }
        if (method == "PUT") {
            adminUpdateUser(ctx, ip, rest)
            return
        }
        if (method == "DELETE") {
            adminDeleteUser(ctx, ip, rest)
            return
        }
    }
    if (sub == "groups" && method == "GET") {
        adminListGroups(ctx, ip)
        return
    }
    if (sub == "groups" && method == "POST") {
        adminAddGroup(ctx, ip)
        return
    }
    if (sub.startsWith("groups/")) {
        let rest = sub[7..]
        if (rest.endsWith("/members/import") && method == "POST") {
            adminImportMembers(ctx, ip, rest[0..rest.size - 15])
            return
        }
        if (rest.endsWith("/members") && method == "POST") {
            adminAddMember(ctx, ip, rest[0..rest.size - 8])
            return
        }
        let memberMark = rest.indexOf("/members/")
        match (memberMark) {
            case Some(i) =>
                if (method == "DELETE") {
                    let gid = rest[0..i]
                    let username = rest[i + 9..]
                    adminDeleteMember(ctx, ip, gid, username)
                    return
                }
            case None => ()
        }
        let repoMark = rest.indexOf("/repos/")
        match (repoMark) {
            case Some(i) =>
                let gid = rest[0..i]
                let repo = rest[i + 7..]
                if (method == "POST") {
                    adminGrantRepo(ctx, ip, gid, repo)
                    return
                }
                if (method == "DELETE") {
                    adminRevokeRepo(ctx, ip, gid, repo)
                    return
                }
            case None => ()
        }
        if (method == "PUT") {
            adminUpdateGroup(ctx, ip, rest)
            return
        }
        if (method == "DELETE") {
            adminDeleteGroup(ctx, ip, rest)
            return
        }
    }
    if (sub == "repos" && method == "GET") {
        adminListRepos(ctx, ip)
        return
    }
    if (sub == "repos" && method == "POST") {
        adminAddRepo(ctx, ip)
        return
    }
    if (sub.startsWith("repos/")) {
        let name = sub[6..]
        if (method == "PUT") {
            adminUpdateRepo(ctx, ip, name)
            return
        }
        if (method == "DELETE") {
            adminDeleteRepo(ctx, ip, name)
            return
        }
    }
    if (sub == "ping" && method == "GET") {
        adminPing(ctx, ip)
        return
    }
    if (sub == "stats" && method == "GET") {
        adminStats(ctx, ip)
        return
    }
    if (sub == "cache/cleanup" && method == "POST") {
        adminCleanup(ctx, ip)
        return
    }
    if (sub == "packages" && method == "GET") {
        adminListPackages(ctx, ip)
        return
    }
    if (sub.startsWith("packages/")) {
        let rest = sub[9..]
        if (method == "POST") {
            adminUploadPackage(ctx, ip, rest)
            return
        }
        let slash = rest.indexOf("/")
        match (slash) {
            case Some(i) =>
                if (method == "DELETE") {
                    adminDeletePackage(ctx, ip, rest[0..i], rest[i + 1..])
                    return
                }
            case None => ()
        }
    }
    if (sub == "audit" && method == "GET") {
        adminListAudit(ctx, ip)
        return
    }
    if (sub == "security/status" && method == "GET") {
        adminSecurityStatus(ctx, ip)
        return
    }
    if (sub == "security/reset-passwords" && method == "POST") {
        adminResetPasswords(ctx, ip)
        return
    }
    if (sub == "settings" && method == "GET") {
        adminGetSettings(ctx, ip)
        return
    }
    if (sub == "settings" && method == "PUT") {
        adminPutSettings(ctx, ip)
        return
    }
    throw HttpError(404, "Not Found")
}

func usernameError(name: String): String {
    if (name.isEmpty() || name.size > 64 || containsWhitespace(name)) {
        return "用户名不能为空、不能包含空白字符且最长 64 位"
    }
    return ""
}

func adminListUsers(ctx: HttpContext, ip: String): Unit {
    requireAdmin(ctx, ip)
    let rows = db().query(
        "SELECT id, username, role, mfa_secret, enabled, created_at FROM users", Array<DbValue>())
    let arr = JsonArray()
    for (row in rows) {
        let obj = jObj()
        obj.put("id", jInt(vInt(row, "id")))
        obj.put("username", jStr(vText(row, "username")))
        obj.put("role", jStr(vText(row, "role")))
        obj.put("mfa", jBool(vText(row, "mfa_secret") != ""))
        obj.put("enabled", jInt(vInt(row, "enabled")))
        obj.put("created_at", jStr(vText(row, "created_at")))
        let groups = JsonArray()
        for (g in db().query(
            "SELECT g.name FROM groups g JOIN user_groups ug ON ug.group_id=g.id WHERE ug.username=?",
            [DbText(vText(row, "username"))])) {
            groups.add(jStr(vText(g, "name")))
        }
        obj.put("groups", groups)
        arr.add(obj)
    }
    respondJsonArray(ctx, 200, arr)
}

func adminAddUser(ctx: HttpContext, ip: String): Unit {
    requireAdmin(ctx, ip)
    let body = readJsonBody(ctx.request)
    let role = jsonGetString(body, "role", def: "user")
    if (role != "admin" && role != "user") {
        throw HttpError(400, "role must be admin/user")
    }
    let username = jsonGetString(body, "username").trimAscii()
    let error = usernameError(username)
    if (!error.isEmpty()) {
        throw HttpError(400, error)
    }
    let password = jsonGetString(body, "password")
    if (password.size < 8) {
        throw HttpError(400, "密码至少 8 位")
    }
    let enabled = jsonGetBool(body, "enabled", def: true)
    try {
        db().execParams(
            "INSERT INTO users (username, password_hash, role, enabled) VALUES (?,?,?,?)",
            [DbText(username), DbText(hashPassword(password)), DbText(role),
             DbInt(if (enabled) { 1 } else { 0 })])
    } catch (e: Exception) {
        throw HttpError(400, "用户名已存在或非法")
    }
    let gid = db().queryOne("SELECT id FROM groups WHERE name='default'", Array<DbValue>())
    match (gid) {
        case Some(g) =>
            db().execParams("INSERT OR IGNORE INTO user_groups (username, group_id) VALUES (?,?)",
                [DbText(username), DbInt(vInt(g, "id"))])
        case None => ()
    }
    audit("user.add", ip, auditDetail([("user", username), ("role", role)]))
    respondOk(ctx)
}

func ensureAdminRemains(username: String, newRole: String, hasEnabled: Bool, newEnabled: Bool): Unit {
    let row = db().queryOne("SELECT role, enabled FROM users WHERE username=?", [DbText(username)])
    match (row) {
        case Some(r) =>
            let resultingRole = if (newRole.isEmpty()) { vText(r, "role") } else { newRole }
            let resultingEnabled = if (hasEnabled) { newEnabled } else { vInt(r, "enabled") != 0 }
            if (resultingRole == "admin" && resultingEnabled) {
                return
            }
            let others = db().queryOne(
                "SELECT count(*) c FROM users WHERE role='admin' AND enabled=1 AND username<>?",
                [DbText(username)])
            let count = match (others) {
                case Some(o) => vInt(o, "c")
                case None => 0
            }
            if (count == 0) {
                throw HttpError(400, "系统至少需要保留一个启用状态的管理员")
            }
        case None => ()
    }
}

func adminUpdateUser(ctx: HttpContext, ip: String, username: String): Unit {
    let a = requireAdmin(ctx, ip)
    let body = readJsonBody(ctx.request)
    let exists = db().queryOne("SELECT 1 AS x FROM users WHERE username=?", [DbText(username)])
    if (exists.isNone()) {
        throw HttpError(404, "user not found")
    }
    let password = jsonGetString(body, "password")
    if (!password.isEmpty()) {
        if (password.size < 8) {
            throw HttpError(400, "密码至少 8 位")
        }
        db().execParams("UPDATE users SET password_hash=?, password_algo='sm3' WHERE username=?",
            [DbText(hashPassword(password)), DbText(username)])
    }
    let role = jsonGetString(body, "role")
    if (!role.isEmpty() && role != "admin" && role != "user") {
        throw HttpError(400, "role must be admin/user")
    }
    let hasEnabled = jsonHasKey(body, "enabled")
    let enabled = jsonGetBool(body, "enabled", def: true)
    if (a.hasUser() && a.username() == username) {
        if (!role.isEmpty() && role != "admin") {
            throw HttpError(400, "不能降级当前登录账号")
        }
        if (hasEnabled && !enabled) {
            throw HttpError(400, "不能禁用当前登录账号")
        }
    }
    ensureAdminRemains(username, role, hasEnabled, enabled)
    if (!role.isEmpty()) {
        db().execParams("UPDATE users SET role=? WHERE username=?", [DbText(role), DbText(username)])
    }
    if (hasEnabled) {
        db().execParams("UPDATE users SET enabled=? WHERE username=?",
            [DbInt(if (enabled) { 1 } else { 0 }), DbText(username)])
    }
    audit("user.update", ip, auditDetail([("user", username), ("operator", a.username())]))
    respondOk(ctx)
}

func adminDeleteUser(ctx: HttpContext, ip: String, username: String): Unit {
    let a = requireAdmin(ctx, ip)
    if (a.hasUser() && a.username() == username) {
        throw HttpError(400, "不能删除当前登录账号")
    }
    ensureAdminRemains(username, "user", true, false)
    let affected = db().execParams("DELETE FROM users WHERE username=?", [DbText(username)])
    db().execParams("DELETE FROM user_groups WHERE username=?", [DbText(username)])
    db().execParams("DELETE FROM sessions WHERE username=?", [DbText(username)])
    if (affected == 0) {
        throw HttpError(404, "user not found")
    }
    audit("user.delete", ip, auditDetail([("user", username), ("operator", a.username())]))
    respondOk(ctx)
}

func adminResetMfa(ctx: HttpContext, ip: String, username: String): Unit {
    requireAdmin(ctx, ip)
    let affected = db().execParams("UPDATE users SET mfa_secret=NULL WHERE username=?", [DbText(username)])
    // 同时丢掉未确认的待生效密钥，避免用户重新绑定时被旧状态干扰
    setSetting("pending_mfa:" + username, "")
    audit("user.mfa_reset", ip, auditDetail([("user", username)]))
    let obj = jObj()
    obj.put("ok", jBool(affected > 0))
    respondJsonObject(ctx, 200, obj)
}

func adminListGroups(ctx: HttpContext, ip: String): Unit {
    requireAdmin(ctx, ip)
    let arr = JsonArray()
    for (g in db().query("SELECT * FROM groups", Array<DbValue>())) {
        let obj = jObj()
        obj.put("id", jInt(vInt(g, "id")))
        obj.put("name", jStr(vText(g, "name")))
        obj.put("description", jStr(vText(g, "description")))
        obj.put("created_at", jStr(vText(g, "created_at")))
        let members = JsonArray()
        for (m in db().query("SELECT username FROM user_groups WHERE group_id=?",
            [DbInt(vInt(g, "id"))])) {
            members.add(jStr(vText(m, "username")))
        }
        obj.put("members", members)
        let repos = JsonArray()
        for (r in db().query(
            "SELECT repo, can_download, can_upload FROM group_repos WHERE group_id=?",
            [DbInt(vInt(g, "id"))])) {
            let ro = jObj()
            ro.put("repo", jStr(vText(r, "repo")))
            ro.put("can_download", jInt(vInt(r, "can_download")))
            ro.put("can_upload", jInt(vInt(r, "can_upload")))
            repos.add(ro)
        }
        obj.put("repos", repos)
        arr.add(obj)
    }
    respondJsonArray(ctx, 200, arr)
}

func adminAddGroup(ctx: HttpContext, ip: String): Unit {
    requireAdmin(ctx, ip)
    let body = readJsonBody(ctx.request)
    let name = jsonGetString(body, "name")
    let description = jsonGetString(body, "description")
    try {
        db().execParams("INSERT INTO groups (name, description) VALUES (?,?)",
            [DbText(name), DbText(description)])
    } catch (e: Exception) {
        throw HttpError(400, "组名已存在")
    }
    audit("group.add", ip, auditDetail([("name", name)]))
    respondOk(ctx)
}

func parseGid(raw: String): Int64 {
    return match (Int64.tryParse(raw.trimAscii())) {
        case Some(v) => v
        case None => throw HttpError(404, "group not found")
    }
}

func adminUpdateGroup(ctx: HttpContext, ip: String, raw: String): Unit {
    requireAdmin(ctx, ip)
    let gid = parseGid(raw)
    let body = readJsonBody(ctx.request)
    let name = jsonGetString(body, "name")
    let description = jsonGetString(body, "description")
    let row = db().queryOne("SELECT name FROM groups WHERE id=?", [DbInt(gid)])
    match (row) {
        case Some(r) =>
            if (vText(r, "name") == "default" && name != "default") {
                throw HttpError(400, "默认组不能改名")
            }
        case None => throw HttpError(404, "group not found")
    }
    db().execParams("UPDATE groups SET name=?, description=? WHERE id=?",
        [DbText(name), DbText(description), DbInt(gid)])
    respondOk(ctx)
}

func adminDeleteGroup(ctx: HttpContext, ip: String, raw: String): Unit {
    requireAdmin(ctx, ip)
    let gid = parseGid(raw)
    let row = db().queryOne("SELECT name FROM groups WHERE id=?", [DbInt(gid)])
    match (row) {
        case Some(r) =>
            if (vText(r, "name") == "default") {
                throw HttpError(400, "默认组不能删除")
            }
        case None => throw HttpError(404, "group not found")
    }
    db().execParams("DELETE FROM user_groups WHERE group_id=?", [DbInt(gid)])
    db().execParams("DELETE FROM group_repos WHERE group_id=?", [DbInt(gid)])
    db().execParams("DELETE FROM groups WHERE id=?", [DbInt(gid)])
    audit("group.delete", ip, auditDetail([("gid", gid.toString())]))
    respondOk(ctx)
}

func adminAddMember(ctx: HttpContext, ip: String, rawGid: String): Unit {
    requireAdmin(ctx, ip)
    let gid = parseGid(rawGid)
    let body = readJsonBody(ctx.request)
    let username = jsonGetString(body, "username")
    if (db().queryOne("SELECT 1 AS x FROM users WHERE username=?", [DbText(username)]).isNone()) {
        throw HttpError(400, "用户不存在")
    }
    if (db().queryOne("SELECT 1 AS x FROM groups WHERE id=?", [DbInt(gid)]).isNone()) {
        throw HttpError(404, "组不存在")
    }
    let affected = db().execParams(
        "INSERT OR IGNORE INTO user_groups (username, group_id) VALUES (?,?)",
        [DbText(username), DbInt(gid)])
    audit("group.member_add", ip, auditDetail([("gid", gid.toString()), ("user", username)]))
    let obj = jObj()
    obj.put("ok", jBool(affected > 0))
    respondJsonObject(ctx, 200, obj)
}

func adminDeleteMember(ctx: HttpContext, ip: String, rawGid: String, username: String): Unit {
    requireAdmin(ctx, ip)
    let gid = parseGid(rawGid)
    db().execParams("DELETE FROM user_groups WHERE group_id=? AND username=?",
        [DbInt(gid), DbText(username)])
    respondOk(ctx)
}

func adminGrantRepo(ctx: HttpContext, ip: String, rawGid: String, repo: String): Unit {
    requireAdmin(ctx, ip)
    let gid = parseGid(rawGid)
    let body = readJsonBody(ctx.request)
    let canDownload = jsonGetBool(body, "can_download", def: true)
    let canUpload = jsonGetBool(body, "can_upload", def: false)
    db().execParams(
        "INSERT INTO group_repos (group_id, repo, can_download, can_upload) VALUES (?,?,?,?) " +
        "ON CONFLICT(group_id, repo) DO UPDATE SET " +
        "can_download=excluded.can_download, can_upload=excluded.can_upload",
        [DbInt(gid), DbText(repo), DbInt(if (canDownload) { 1 } else { 0 }),
         DbInt(if (canUpload) { 1 } else { 0 })])
    audit("group.grant", ip, auditDetail([("gid", gid.toString()), ("repo", repo)]))
    respondOk(ctx)
}

func adminRevokeRepo(ctx: HttpContext, ip: String, rawGid: String, repo: String): Unit {
    requireAdmin(ctx, ip)
    let gid = parseGid(rawGid)
    db().execParams("DELETE FROM group_repos WHERE group_id=? AND repo=?", [DbInt(gid), DbText(repo)])
    audit("group.revoke", ip, auditDetail([("gid", gid.toString()), ("repo", repo)]))
    respondOk(ctx)
}

let REPO_TYPES = ["pypi", "npm", "raw", "go", "maven", "nuget", "rubygems",
    "crates", "conan", "pub", "hex", "hackage", "cran", "luarocks", "cocoapods"]

func validRepoType(value: String): Bool {
    for (item in REPO_TYPES) {
        if (item == value) {
            return true
        }
    }
    return false
}

func validateRepoName(name: String): Unit {
    let pattern = Regex("[A-Za-z0-9][A-Za-z0-9._-]{0,63}")
    if (!pattern.matches(name) || name.size > 64) {
        throw HttpError(400, "仓库名仅支持字母、数字、点、下划线和短横线, 以字母或数字开头, 最长 64 位")
    }
}

func normalizeUpstreams(body: JsonObject): ArrayList<String> {
    let raw = jsonStringList(body, "upstreams")
    if (raw.size == 0) {
        let single = jsonGetString(body, "upstream")
        if (!single.isEmpty()) {
            raw.add(single)
        }
    }
    let urls = ArrayList<String>()
    for (item in raw) {
        var u = item.trimAscii()
        while (u.endsWith("/")) {
            u = u[0..u.size - 1]
        }
        if (u.isEmpty()) {
            continue
        }
        if (!u.startsWith("https://")) {
            throw HttpError(400, "upstream must use https:// (防中间人投毒)")
        }
        var exists = false
        for (existing in urls) {
            if (existing == u) {
                exists = true
                break
            }
        }
        if (!exists) {
            urls.add(u)
        }
    }
    if (urls.size == 0) {
        throw HttpError(400, "at least one upstream is required")
    }
    return urls
}

func upstreamsJson(urls: ArrayList<String>): String {
    let arr = JsonArray()
    for (u in urls) {
        arr.add(jStr(u))
    }
    return compactJson(arr)
}

func adminListRepos(ctx: HttpContext, ip: String): Unit {
    let a = requireSession(ctx, ip)
    let arr = JsonArray()
    if (a.isAdmin) {
        for (row in db().query("SELECT * FROM repos ORDER BY name", Array<DbValue>())) {
            arr.add(rowToJson(row))
        }
    } else {
        // 普通用户可见: 自己所在组获得下载授权的仓库 + 允许匿名下载的仓库。
        let visible = db().query(
            "SELECT * FROM repos WHERE enabled=1 AND (anonymous=1 OR name IN (" +
            "SELECT gr.repo FROM group_repos gr JOIN user_groups ug ON ug.group_id = gr.group_id " +
            "WHERE ug.username=? AND gr.can_download=1)) ORDER BY name",
            [DbText(a.username())])
        for (row in visible) {
            arr.add(rowToJson(row))
        }
    }
    respondJsonArray(ctx, 200, arr)
}

func adminAddRepo(ctx: HttpContext, ip: String): Unit {
    requireAdmin(ctx, ip)
    let body = readJsonBody(ctx.request)
    let rtype = jsonGetString(body, "type")
    if (!validRepoType(rtype)) {
        throw HttpError(400, "type must be pypi/npm/raw/go/maven/nuget/rubygems/crates/conan/pub/hex/hackage/cran/luarocks/cocoapods")
    }
    let upstream = jsonGetString(body, "upstream")
    if (!upstream.startsWith("https://")) {
        throw HttpError(400, "upstream must use https:// (防中间人投毒)")
    }
    let name = jsonGetString(body, "name")
    validateRepoName(name)
    let urls = normalizeUpstreams(body)
    let quotaMb = jsonGetInt(body, "quota_mb")
    let enabled = jsonGetBool(body, "enabled", def: true)
    let anonymous = jsonGetBool(body, "anonymous", def: false)
    db().execParams(
        "INSERT INTO repos (name, type, upstream, upstreams, quota_mb, enabled, anonymous) " +
        "VALUES (?,?,?,?,?,?,?)",
        [DbText(name), DbText(rtype), DbText(urls[0]), DbText(upstreamsJson(urls)),
         DbInt(quotaMb), DbInt(if (enabled) { 1 } else { 0 }),
         DbInt(if (anonymous) { 1 } else { 0 })])
    audit("repo.add", ip, auditDetail([("name", name), ("upstream", upstream)]))
    respondOk(ctx)
}

func adminUpdateRepo(ctx: HttpContext, ip: String, name: String): Unit {
    requireAdmin(ctx, ip)
    let body = readJsonBody(ctx.request)
    let rtype = jsonGetString(body, "type")
    if (!validRepoType(rtype)) {
        throw HttpError(400, "invalid type")
    }
    let upstream = jsonGetString(body, "upstream")
    if (!upstream.startsWith("https://")) {
        throw HttpError(400, "upstream must use https:// (防中间人投毒)")
    }
    validateRepoName(jsonGetString(body, "name"))
    let urls = normalizeUpstreams(body)
    let quotaMb = jsonGetInt(body, "quota_mb")
    let enabled = jsonGetBool(body, "enabled", def: true)
    let anonymous = jsonGetBool(body, "anonymous", def: false)
    let affected = db().execParams(
        "UPDATE repos SET upstream=?, upstreams=?, quota_mb=?, enabled=?, type=?, anonymous=? " +
        "WHERE name=?",
        [DbText(urls[0]), DbText(upstreamsJson(urls)), DbInt(quotaMb),
         DbInt(if (enabled) { 1 } else { 0 }), DbText(rtype),
         DbInt(if (anonymous) { 1 } else { 0 }), DbText(name)])
    if (affected == 0) {
        throw HttpError(404, "not found")
    }
    audit("repo.update", ip, auditDetail([("name", name), ("upstream", upstream)]))
    respondOk(ctx)
}

func adminDeleteRepo(ctx: HttpContext, ip: String, name: String): Unit {
    requireAdmin(ctx, ip)
    let packages = db().query("SELECT filepath FROM private_packages WHERE repo=?", [DbText(name)])
    for (row in packages) {
        let path = vText(row, "filepath")
        try {
            if (fileExists(path)) {
                remove(path)
            }
        } catch (e: Exception) {
            (e)
        }
    }
    db().execParams("DELETE FROM private_packages WHERE repo=?", [DbText(name)])
    db().execParams("DELETE FROM group_repos WHERE repo=?", [DbText(name)])
    let affected = db().execParams("DELETE FROM repos WHERE name=?", [DbText(name)])
    try {
        removeIfExists(joinPath(PRIVATE_DIR, name), recursive: true)
    } catch (e: Exception) {
        (e)
    }
    if (affected == 0) {
        throw HttpError(404, "repo not found")
    }
    audit("repo.delete", ip, auditDetail([("name", name)]))
    respondOk(ctx)
}

func adminPing(ctx: HttpContext, ip: String): Unit {
    requireSession(ctx, ip)
    let details = jObj()
    let latency = jObj()
    let repos = db().query("SELECT name, upstream, upstreams FROM repos WHERE enabled=1", Array<DbValue>())
    for (row in repos) {
        let name = vText(row, "name")
        let urls = ArrayList<String>()
        let raw = vText(row, "upstreams")
        if (!raw.isEmpty()) {
            match (jsonParseValue(raw)) {
                case Some(value) =>
                    match (value.kind()) {
                        case JsonKind.JsArray =>
                            for (item in value.asArray().getItems()) {
                                match (item.kind()) {
                                    case JsonKind.JsString => urls.add(item.asString().getValue())
                                    case _ => ()
                                }
                            }
                        case _ => ()
                    }
                case None => ()
            }
        }
        if (urls.size == 0 && !vText(row, "upstream").isEmpty()) {
            urls.add(vText(row, "upstream"))
        }
        let items = JsonArray()
        var best: Int64 = -1
        for (u in urls) {
            var ms: Int64 = -1
            let start = unixSecondsFloat()
            try {
                let resp = upstreamGet(u.trimAscii(), head: true)
                if (resp.status < 500) {
                    ms = Int64((unixSecondsFloat() - start) * 1000.0)
                }
            } catch (e: Exception) {
                ms = -1
            }
            let entry = jObj()
            entry.put("upstream", jStr(u))
            entry.put("ms", jInt(ms))
            items.add(entry)
            if (ms >= 0 && (best < 0 || ms < best)) {
                best = ms
            }
        }
        details.put(name, items)
        latency.put(name, jInt(best))
    }
    let out = jObj()
    out.put("latency", latency)
    out.put("details", details)
    out.put("probed_at", jInt(unixSeconds()))
    respondJsonObject(ctx, 200, out)
}

func adminStats(ctx: HttpContext, ip: String): Unit {
    requireSession(ctx, ip)
    let perRepo = JsonArray()
    var totalFiles: Int64 = 0
    var totalHits: Int64 = 0
    for (row in db().query(
        "SELECT repo, count(*) n, sum(size) total, sum(hits) hits FROM cache_entries GROUP BY repo",
        Array<DbValue>())) {
        let obj = jObj()
        obj.put("repo", jStr(vText(row, "repo")))
        obj.put("n", jInt(vInt(row, "n")))
        obj.put("total", jInt(vInt(row, "total")))
        obj.put("hits", jInt(vInt(row, "hits")))
        perRepo.add(obj)
        totalFiles = totalFiles + vInt(row, "n")
        totalHits = totalHits + vInt(row, "hits")
    }
    let recent = JsonArray()
    for (row in db().query(
        "SELECT repo, path, size, hits, fetched_at FROM cache_entries ORDER BY last_hit_at DESC LIMIT 15",
        Array<DbValue>())) {
        recent.add(rowToJson(row))
    }
    let out = jObj()
    out.put("per_repo", perRepo)
    out.put("total_size", jInt(dirSize(CACHE_DIR)))
    out.put("total_files", jInt(totalFiles))
    out.put("total_hits", jInt(totalHits))
    out.put("recent", recent)
    respondJsonObject(ctx, 200, out)
}

func adminCleanup(ctx: HttpContext, ip: String): Unit {
    requireAdmin(ctx, ip)
    let days = queryInt(ctx.request, "days", def: 7)
    let freed = cleanupKeepLastN(days)
    audit("cache.cleanup", ip, auditDetail([("days", days.toString()), ("freed", freed.toString())]))
    let out = jObj()
    out.put("freed_bytes", jInt(freed))
    respondJsonObject(ctx, 200, out)
}

func adminListPackages(ctx: HttpContext, ip: String): Unit {
    let a = requireSession(ctx, ip)
    let arr = JsonArray()
    if (a.isAdmin) {
        for (row in db().query("SELECT * FROM private_packages ORDER BY repo, filename",
            Array<DbValue>())) {
            arr.add(rowToJson(row))
        }
    } else {
        let allowed = db().query(
            "SELECT DISTINCT gr.repo AS repo FROM group_repos gr " +
            "JOIN user_groups ug ON ug.group_id = gr.group_id " +
            "WHERE ug.username=? AND (gr.can_download=1 OR gr.can_upload=1)", [DbText(a.username())])
        for (item in allowed) {
            for (row in db().query(
                "SELECT * FROM private_packages WHERE repo=? ORDER BY repo, filename",
                [DbText(vText(item, "repo"))])) {
                arr.add(rowToJson(row))
            }
        }
    }
    respondJsonArray(ctx, 200, arr)
}

func adminUploadPackage(ctx: HttpContext, ip: String, repo: String): Unit {
    let a = authCtx(ctx.request)
    let actor = match (a) {
        case Some(v) => v
        case None => throw HttpError(401, "login required")
    }
    if (!(actor.isAdmin || canAccess(actor, repo, "can_upload"))) {
        throw HttpError(403, "no upload permission on repo " + repo)
    }
    if (repo.isEmpty() || repo.startsWith(".") || repo.contains("/") ||
        repo.contains("\\") || repo == "default") {
        throw HttpError(400, "请在「仓库路径名」输入具体的仓库名后再上传 (如 pypi、mypkg)")
    }
    let part = multipartFile(ctx.request, (MAX_UPLOAD_MB + 4) * 1024 * 1024)
    let uploader = if (actor.hasUser()) { actor.username() } else { "cli" }
    let result = saveUpload(part, repo, uploader)
    let detail = jObj()
    detail.put("repo", jStr(repo))
    detail.put("file", jStr(jsonGetString(result, "filename")))
    detail.put("sha256", jStr(jsonGetString(result, "sha256")))
    audit("package.upload", ip, detail)
    respondJsonObject(ctx, 200, result)
}

func adminDeletePackage(ctx: HttpContext, ip: String, repo: String, filename: String): Unit {
    requireAdmin(ctx, ip)
    let row = db().queryOne("SELECT * FROM private_packages WHERE repo=? AND filename=?",
        [DbText(repo), DbText(filename)])
    match (row) {
        case Some(r) =>
            let path = vText(r, "filepath")
            try {
                if (fileExists(path)) {
                    remove(path)
                }
            } catch (e: Exception) {
                (e)
            }
            db().execParams("DELETE FROM private_packages WHERE repo=? AND filename=?",
                [DbText(repo), DbText(filename)])
            audit("package.delete", ip, auditDetail([("repo", repo), ("file", filename)]))
            respondOk(ctx)
        case None => throw HttpError(404, "not found")
    }
}

func adminListAudit(ctx: HttpContext, ip: String): Unit {
    requireSession(ctx, ip)
    var limit = queryInt(ctx.request, "limit", def: 200)
    if (limit < 1) {
        limit = 1
    }
    if (limit > 1000) {
        limit = 1000
    }
    let arr = JsonArray()
    if (fileExists(AUDIT_LOG)) {
        let text = String.fromUtf8(readAllBytes(AUDIT_LOG))
        let lines = ArrayList<String>()
        for (line in text.split("\n")) {
            if (!line.isEmpty()) {
                lines.add(line)
            }
        }
        var start = 0
        if (Int64(lines.size) > limit) {
            start = Int64(lines.size) - limit
        }
        var i = start
        while (i < lines.size) {
            let line = lines[i]
            var payload = ""
            try {
                if (line.startsWith("sm|")) {
                    payload = decryptText(line[3..])
                } else if (line.startsWith("enc|")) {
                    payload = decryptText(line[4..])
                } else if (line.startsWith("plain|")) {
                    payload = line[6..]
                    if (payload.startsWith("enc:")) {
                        payload = decryptText(payload)
                    }
                } else {
                    payload = line
                }
                match (jsonParseValue(payload.trimAscii())) {
                    case Some(value) => arr.add(value)
                    case None => ()
                }
            } catch (e: Exception) {
                (e)
            }
            i = i + 1
        }
    }
    respondJsonArray(ctx, 200, arr)
}

func adminSecurityStatus(ctx: HttpContext, ip: String): Unit {
    requireAdmin(ctx, ip)
    let version = getSetting("crypto_version", def: "0")
    let resetFlag = getSetting("password_reset_needed", def: "0")
    let legacyTokensRow = db().queryOne(
        "SELECT count(*) c FROM api_tokens WHERE revoked=0 AND token_algo='sha256'", Array<DbValue>())
    let legacyTokens = match (legacyTokensRow) {
        case Some(r) => vInt(r, "c")
        case None => 0
    }
    let legacyPwRow = db().queryOne(
        "SELECT count(*) c FROM users WHERE password_hash NOT LIKE 'sm3$%'", Array<DbValue>())
    let legacyPw = match (legacyPwRow) {
        case Some(r) => vInt(r, "c")
        case None => 0
    }
    let out = jObj()
    out.put("crypto_version", jInt(match (Int64.tryParse(version)) {
        case Some(v) => v
        case None => 0
    }))
    out.put("password_reset_needed", jBool(resetFlag == "1" || legacyPw > 0))
    out.put("legacy_password_users", jInt(legacyPw))
    out.put("legacy_api_tokens", jInt(legacyTokens))
    respondJsonObject(ctx, 200, out)
}

func adminResetPasswords(ctx: HttpContext, ip: String): Unit {
    let a = requireAdmin(ctx, ip)
    let current = if (a.hasUser()) { a.username() } else { "" }
    let users = db().query("SELECT username FROM users WHERE username<>?", [DbText(current)])
    let generated = JsonArray()
    var count: Int64 = 0
    for (row in users) {
        let username = vText(row, "username")
        let password = generateSimplePassword(14)
        db().execParams("UPDATE users SET password_hash=?, password_algo='sm3' WHERE username=?",
            [DbText(hashPassword(password)), DbText(username)])
        let item = jObj()
        item.put("username", jStr(username))
        item.put("password", jStr(password))
        generated.add(item)
        count = count + 1
    }
    db().execParams("DELETE FROM sessions WHERE username<>?", [DbText(current)])
    setSetting("password_reset_needed", "0")
    audit("security.reset_all_passwords", ip,
        auditDetail([("count", count.toString()), ("operator", current)]))
    let out = jObj()
    out.put("count", jInt(count))
    out.put("users", generated)
    respondJsonObject(ctx, 200, out)
}

func adminGetSettings(ctx: HttpContext, ip: String): Unit {
    requireAdmin(ctx, ip)
    let out = jObj()
    out.put("mfa_enforced", jBool(getSetting("mfa_enforced", def: "0") == "1"))
    respondJsonObject(ctx, 200, out)
}

func parseBoolText(raw: String): Bool {
    let value = raw.trimAscii().toAsciiLower()
    return value == "1" || value == "true" || value == "yes" || value == "on"
}

func adminPutSettings(ctx: HttpContext, ip: String): Unit {
    requireAdmin(ctx, ip)
    let req = ctx.request
    let mfaRaw = queryValue(req, "mfa_enforced")
    if (!mfaRaw.isEmpty()) {
        let value = parseBoolText(mfaRaw)
        setSetting("mfa_enforced", if (value) { "1" } else { "0" })
        audit("settings.mfa_enforced", ip, auditDetail([("value", value.toString())]))
    }
    let cleanupRaw = queryValue(req, "cleanup_enabled")
    if (!cleanupRaw.isEmpty()) {
        setSetting("cleanup_enabled", if (parseBoolText(cleanupRaw)) { "1" } else { "0" })
    }
    let retentionRaw = queryValue(req, "cache_retention_days")
    if (!retentionRaw.isEmpty()) {
        match (Int64.tryParse(retentionRaw.trimAscii())) {
            case Some(v) =>
                var days = v
                if (days < 1) {
                    days = 1
                }
                if (days > 3650) {
                    days = 3650
                }
                setSetting("cache_retention_days", days.toString())
            case None => ()
        }
    }
    let retention = getSetting("cache_retention_days", def: "30")
    let out = jObj()
    out.put("mfa_enforced", jBool(getSetting("mfa_enforced", def: "0") == "1"))
    out.put("cleanup_enabled", jBool(getSetting("cleanup_enabled", def: "1") == "1"))
    out.put("cache_retention_days", jInt(match (Int64.tryParse(retention)) {
        case Some(v) => v
        case None => 30
    }))
    respondJsonObject(ctx, 200, out)
}
