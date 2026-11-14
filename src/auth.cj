package modernmirror

import std.collection.*
import stdx.net.http.*
import stdx.encoding.json.*
import std.convert.*

class AuthCtx {
    let user: ?DbRow
    let isAdmin: Bool
    let webSession: Bool

    init(user: ?DbRow, isAdmin: Bool, webSession: Bool) {
        this.user = user
        this.isAdmin = isAdmin
        this.webSession = webSession
    }

    func username(): String {
        match (user) {
            case Some(row) => return vText(row, "username")
            case None => return "cli"
        }
    }

    func hasUser(): Bool {
        match (user) {
            case Some(_) => return true
            case None => return false
        }
    }

    func userValue(key: String): String {
        match (user) {
            case Some(row) => return vText(row, key)
            case None => return ""
        }
    }

    func userInt(key: String): Int64 {
        match (user) {
            case Some(row) => return vInt(row, key)
            case None => return 0
        }
    }

    func userBool(key: String, def!: Bool = true): Bool {
        match (user) {
            case Some(row) =>
                if (vNull(row, key)) {
                    return def
                }
                return vInt(row, key) != 0
            case None => return def
        }
    }
}

func getUser(username: String): ?DbRow {
    return db().queryOne("SELECT * FROM users WHERE username=?", [DbText(username)])
}

func getUserByName(username: String): ?DbRow {
    return getUser(username)
}

func getSetting(key: String, def!: String = ""): String {
    let row = db().queryOne("SELECT value FROM settings WHERE key=?", [DbText(key)])
    return match (row) {
        case Some(r) => vText(r, "value")
        case None => def
    }
}

func setSetting(key: String, value: String): Unit {
    db().execParams(
        "INSERT INTO settings (key, value) VALUES (?,?) " +
        "ON CONFLICT(key) DO UPDATE SET value=excluded.value", [DbText(key), DbText(value)])
}

func sessionHash(token: String): String {
    return tokenHash(token)
}

func createSessionMinutes(username: String, mfaState: Int64, ttlMinutes: Int64): String {
    let token = tokenUrlSafe(32)
    let offset = "+" + ttlMinutes.toString() + " minutes"
    db().execParams(
        "INSERT INTO sessions (token, username, expires, mfa_state) " +
        "VALUES (?,?,datetime('now', 'localtime', ?),?)",
        [DbText(sessionHash(token)), DbText(username), DbText(offset), DbInt(mfaState)])
    return token
}

func createSession(username: String, mfaState: Int64): String {
    return createSessionMinutes(username, mfaState, SESSION_HOURS * 60)
}

func createLoginNonce(username: String): String {
    let token = tokenUrlSafe(24)
    db().execParams(
        "INSERT INTO sessions (token, username, expires, mfa_state) " +
        "VALUES (?,?,datetime('now', 'localtime','+5 minutes'),1)",
        [DbText(sessionHash(token)), DbText(username)])
    return token
}

func slideSession(nonceToken: String): Unit {
    let offset = "+" + WEB_SESSION_MINUTES.toString() + " minutes"
    db().execParams(
        "UPDATE sessions SET expires=datetime('now', 'localtime', ?) " +
        "WHERE token=? AND mfa_state=2 AND expires > datetime('now', 'localtime')",
        [DbText(offset), DbText(sessionHash(nonceToken))])
}

func getSession(token: String): ?DbRow {
    if (token.isEmpty()) {
        return None
    }
    return db().queryOne(
        "SELECT * FROM sessions WHERE token=? AND expires > datetime('now', 'localtime')",
        [DbText(sessionHash(token))])
}

func completeSession(nonceToken: String): ?String {
    let nonceHash = sessionHash(nonceToken)
    let row = db().queryOne(
        "SELECT username FROM sessions WHERE token=? AND mfa_state=1 " +
        "AND expires > datetime('now', 'localtime')", [DbText(nonceHash)])
    match (row) {
        case Some(r) =>
            let newToken = tokenUrlSafe(32)
            let offset = "+" + WEB_SESSION_MINUTES.toString() + " minutes"
            db().execParams("DELETE FROM sessions WHERE token=?", [DbText(nonceHash)])
            db().execParams(
                "INSERT INTO sessions (token, username, expires, mfa_state) " +
                "VALUES (?,?,datetime('now', 'localtime', ?),2)",
                [DbText(sessionHash(newToken)), DbText(vText(r, "username")), DbText(offset)])
            purgeExpired()
            return Some(newToken)
        case None =>
            purgeExpired()
            return None
    }
}

func revokeSession(token: String): Unit {
    db().execParams("DELETE FROM sessions WHERE token=?", [DbText(sessionHash(token))])
}

func purgeExpired(): Unit {
    db().execParams("DELETE FROM sessions WHERE expires <= datetime('now', 'localtime')", Array<DbValue>())
}

func headerValue(req: HttpRequest, name: String): String {
    return match (req.headers.getFirst(name)) {
        case Some(v) => v
        case None => ""
    }
}

func extractToken(req: HttpRequest): String {
    let authHeader = headerValue(req, "Authorization")
    if (authHeader.toAsciiLower().startsWith("basic ")) {
        try {
            let raw = String.fromUtf8(b64Decode(authHeader[6..].trimAscii()))
            let idx = raw.indexOf(":")
            match (idx) {
                case Some(i) => return raw[i + 1..]
                case None => ()
            }
        } catch (e: Exception) {
            (e)
        }
    }
    let sessionToken = headerValue(req, "Session-Token")
    if (!sessionToken.isEmpty()) {
        return sessionToken
    }
    let xAuth = headerValue(req, "X-Auth-Token")
    if (!xAuth.isEmpty()) {
        return xAuth
    }
    if (!authHeader.isEmpty()) {
        return authHeader.replace("Bearer ", "")
    }
    let queryToken = match (req.url.queryForm.get("token")) {
        case Some(v) => v
        case None => ""
    }
    return queryToken
}

func createApiToken(username: String, name: String): String {
    let token = "mm_" + tokenUrlSafe(30)
    var prefix = token
    if (prefix.size > 8) {
        prefix = prefix[0..8]
    }
    db().execParams(
        "INSERT INTO api_tokens (username, name, token_hash, token_prefix, token_algo) " +
        "VALUES (?,?,?,?,'sm3')",
        [DbText(username), DbText(name), DbText(tokenHash(token)), DbText(prefix)])
    return token
}

func listApiTokens(username: String): ArrayList<DbRow> {
    return db().query(
        "SELECT id, name, token_prefix, created_at, last_used_at, revoked, token_algo " +
        "FROM api_tokens WHERE username=? ORDER BY id DESC", [DbText(username)])
}

func revokeApiToken(username: String, tokenId: Int64): Bool {
    let affected = db().execParams(
        "UPDATE api_tokens SET revoked=1 WHERE id=? AND username=?",
        [DbInt(tokenId), DbText(username)])
    return affected > 0
}

func apiTokenUser(token: String): ?DbRow {
    if (token.isEmpty()) {
        return None
    }
    var row = db().queryOne("SELECT * FROM api_tokens WHERE token_hash=? AND revoked=0",
        [DbText(tokenHash(token))])
    if (row.isNone()) {
        let legacy = tokenHashLegacy(token)
        row = db().queryOne("SELECT * FROM api_tokens WHERE token_hash=? AND revoked=0",
            [DbText(legacy)])
        match (row) {
            case Some(r) =>
                db().execParams("UPDATE api_tokens SET token_hash=?, token_algo='sm3' WHERE id=?",
                    [DbText(tokenHash(token)), DbInt(vInt(r, "id"))])
            case None => ()
        }
    }
    match (row) {
        case Some(r) =>
            db().execParams("UPDATE api_tokens SET last_used_at=datetime('now', 'localtime') WHERE id=?",
                [DbInt(vInt(r, "id"))])
            return getUserByName(vText(r, "username"))
        case None => return None
    }
}

func authCtxFromToken(token: String): ?AuthCtx {
    if (token == ADMIN_TOKEN && ADMIN_TOKEN != "admin-token") {
        return AuthCtx(None, true, false)
    }
    var user: ?DbRow = None
    var isWeb = false
    let sess = getSession(token)
    match (sess) {
        case Some(s) =>
            if (vInt(s, "mfa_state") == 2) {
                let found = getUserByName(vText(s, "username"))
                match (found) {
                    case Some(u) =>
                        if (vNull(u, "enabled") || vInt(u, "enabled") != 0) {
                            slideSession(token)
                            user = Some(u)
                            isWeb = true
                        }
                    case None => ()
                }
            }
        case None => ()
    }
    if (user.isNone()) {
        user = apiTokenUser(token)
    }
    match (user) {
        case Some(u) =>
            if (!vNull(u, "enabled") && vInt(u, "enabled") == 0) {
                return None
            }
            return AuthCtx(Some(u), vText(u, "role") == "admin", isWeb)
        case None => return None
    }
}

func authCtx(req: HttpRequest): ?AuthCtx {
    return authCtxFromToken(extractToken(req))
}

func mfaEnforcedOk(ctx: AuthCtx): Bool {
    match (ctx.user) {
        case Some(u) =>
            if (vText(u, "role") == "admin") {
                return true
            }
        case None => return true
    }
    if (getSetting("mfa_enforced", def: "0") != "1") {
        return true
    }
    return ctx.userValue("mfa_secret") != ""
}

func canAccess(ctx: AuthCtx, repo: String, perm: String): Bool {
    if (!ctx.hasUser()) {
        return false
    }
    let username = ctx.username()
    let groups = db().query(
        "SELECT g.id FROM groups g JOIN user_groups ug ON ug.group_id=g.id WHERE ug.username=?",
        [DbText(username)])
    if (groups.size == 0) {
        return false
    }
    var marks = ""
    let params = ArrayList<DbValue>()
    for (i in 0..groups.size) {
        if (i > 0) {
            marks = marks + ","
        }
        marks = marks + "?"
        params.add(DbInt(vInt(groups[i], "id")))
    }
    params.add(DbText(repo))
    let column = if (perm == "can_upload") { "can_upload" } else { "can_download" }
    let row = db().queryOne(
        "SELECT 1 AS ok FROM group_repos WHERE group_id IN (" + marks + ") AND repo=? AND " + column + "=1",
        params.toArray())
    return row.isSome()
}

func auditFail(ip: String): Unit {
    let detail = JsonObject()
    detail.put("detail", JsonString("invalid session"))
    audit("auth.fail", ip, detail)
}

func clientIp(req: HttpRequest): String {
    let addr = req.remoteAddr
    if (addr.isEmpty()) {
        return "local"
    }
    let idx = addr.lastIndexOf(":")
    match (idx) {
        case Some(i) => return addr[0..i]
        case None => return addr
    }
}
