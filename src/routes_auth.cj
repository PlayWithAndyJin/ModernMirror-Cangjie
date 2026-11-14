package modernmirror

import std.collection.*
import stdx.encoding.json.*
import stdx.net.http.*

func publicUser(row: DbRow): JsonObject {
    let obj = jObj()
    obj.put("username", jStr(vText(row, "username")))
    obj.put("role", jStr(vText(row, "role")))
    obj.put("mfa", jBool(vText(row, "mfa_secret") != ""))
    return obj
}

func publicCtx(ctx: AuthCtx): JsonObject {
    match (ctx.user) {
        case Some(row) => return publicUser(row)
        case None =>
            let obj = jObj()
            obj.put("role", jStr("admin"))
            obj.put("username", jStr("cli"))
            obj.put("mfa", jBool(false))
            return obj
    }
}

func auditDetail(pairs: Array<(String, String)>): JsonObject {
    let obj = jObj()
    for (item in pairs) {
        obj.put(item[0], jStr(item[1]))
    }
    return obj
}

func handleAuthRoute(ctx: HttpContext, ip: String, path: String, method: String): Unit {
    let sub = path[6..]
    if (sub == "login" && method == "POST") {
        authLogin(ctx, ip)
        return
    }
    if (sub == "verify-totp" && method == "POST") {
        authVerifyTotp(ctx, ip)
        return
    }
    if (sub == "logout" && method == "POST") {
        authLogout(ctx)
        return
    }
    if (sub == "me" && method == "GET") {
        let a = requireSession(ctx, ip)
        respondJsonObject(ctx, 200, publicCtx(a))
        return
    }
    if (sub == "password" && method == "POST") {
        authChangePassword(ctx, ip)
        return
    }
    if (sub == "mfa/setup" && method == "POST") {
        authMfaSetup(ctx, ip)
        return
    }
    if (sub == "mfa/enable" && method == "POST") {
        authMfaEnable(ctx, ip)
        return
    }
    if (sub == "mfa/disable" && method == "POST") {
        authMfaDisable(ctx, ip)
        return
    }
    if (sub == "tokens" && method == "GET") {
        authListTokens(ctx, ip)
        return
    }
    if (sub == "tokens" && method == "POST") {
        authCreateToken(ctx, ip)
        return
    }
    if (sub == "tokens/revoke" && method == "POST") {
        authRevokeToken(ctx, ip)
        return
    }
    if (sub == "tokens/revoke-legacy" && method == "POST") {
        authRevokeLegacyTokens(ctx, ip)
        return
    }
    throw HttpError(404, "Not Found")
}

func authLogin(ctx: HttpContext, ip: String): Unit {
    let body = readJsonBody(ctx.request)
    let username = jsonGetString(body, "username")
    let password = jsonGetString(body, "password")
    let user = getUser(username)
    match (user) {
        case Some(row) =>
            if (!verifyPassword(password, vText(row, "password_hash"))) {
                audit("login.fail", ip, auditDetail([("user", username)]))
                throw HttpError(401, "用户名或密码错误")
            }
            if (!vNull(row, "enabled") && vInt(row, "enabled") == 0) {
                audit("login.disabled", ip, auditDetail([("user", username)]))
                throw HttpError(403, "该账号已被禁用, 请联系管理员")
            }
            var current = row
            if (passwordNeedsUpgrade(vText(current, "password_hash"))) {
                db().execParams(
                    "UPDATE users SET password_hash=?, password_algo='sm3' WHERE username=?",
                    [DbText(hashPassword(password)), DbText(username)])
                match (getUserByName(username)) {
                    case Some(fresh) => current = fresh
                    case None => ()
                }
            }
            if (vText(current, "mfa_secret") != "") {
                let nonce = createLoginNonce(username)
                let out = jObj()
                out.put("mfa_required", jBool(true))
                out.put("nonce", jStr(nonce))
                respondJsonObject(ctx, 200, out)
                return
            }
            let token = createSession(username, 2)
            let out = jObj()
            out.put("mfa_required", jBool(false))
            out.put("token", jStr(token))
            out.put("user", publicUser(current))
            respondJsonObject(ctx, 200, out)
        case None =>
            audit("login.fail", ip, auditDetail([("user", username)]))
            throw HttpError(401, "用户名或密码错误")
    }
}

func authVerifyTotp(ctx: HttpContext, ip: String): Unit {
    let body = readJsonBody(ctx.request)
    let nonce = jsonGetString(body, "nonce")
    let code = jsonGetString(body, "code")
    let sess = getSession(nonce)
    match (sess) {
        case Some(s) =>
            if (vInt(s, "mfa_state") != 1) {
                throw HttpError(401, "登录会话已失效,请重新登录")
            }
            let username = vText(s, "username")
            let user = getUserByName(username)
            var ok = false
            match (user) {
                case Some(u) =>
                    let secret = decryptText(vText(u, "mfa_secret"))
                    ok = verifyTotp(secret, code)
                case None => ()
            }
            if (!ok) {
                audit("login.mfa_fail", ip, auditDetail([("user", username)]))
                throw HttpError(401, "动态码不正确")
            }
            let token = completeSession(nonce)
            match (token) {
                case Some(t) =>
                    let out = jObj()
                    out.put("token", jStr(t))
                    respondJsonObject(ctx, 200, out)
                case None => throw HttpError(401, "登录会话已失效,请重新登录")
            }
        case None => throw HttpError(401, "登录会话已失效,请重新登录")
    }
}

func authLogout(ctx: HttpContext): Unit {
    let token = extractToken(ctx.request)
    if (!token.isEmpty()) {
        revokeSession(token)
    }
    respondOk(ctx)
}

func authChangePassword(ctx: HttpContext, ip: String): Unit {
    let a = requireSession(ctx, ip)
    if (!a.hasUser()) {
        throw HttpError(400, "CLI token 无用户,请勿登录")
    }
    let body = readJsonBody(ctx.request)
    let oldPassword = jsonGetString(body, "old_password")
    let newPassword = jsonGetString(body, "new_password")
    if (!verifyPassword(oldPassword, a.userValue("password_hash"))) {
        throw HttpError(403, "旧密码不正确")
    }
    if (newPassword.size < 8) {
        throw HttpError(400, "新密码至少 8 位")
    }
    db().execParams("UPDATE users SET password_hash=?, password_algo='sm3' WHERE username=?",
        [DbText(hashPassword(newPassword)), DbText(a.username())])
    audit("user.password_change", ip, auditDetail([("user", a.username())]))
    respondOk(ctx)
}

func authMfaSetup(ctx: HttpContext, ip: String): Unit {
    let a = requireSession(ctx, ip)
    if (!a.hasUser()) {
        throw HttpError(400, "CLI token 无用户")
    }
    if (a.userValue("mfa_secret") != "") {
        throw HttpError(400, "MFA 已开启, 如需更换请先关闭")
    }
    let username = a.username()
    let secret = genTotpSecret()
    setSetting("pending_mfa:" + username, encryptText(secret))
    let out = jObj()
    out.put("secret", jStr(secret))
    out.put("otpauth", jStr(otpauthUrl(username, secret)))
    out.put("hint", jStr("密钥先保存(未生效), 在认证 App 添加后输入当前动态码点【确认开启】即可生效"))
    respondJsonObject(ctx, 200, out)
}

func authMfaEnable(ctx: HttpContext, ip: String): Unit {
    let a = requireSession(ctx, ip)
    if (!a.hasUser()) {
        throw HttpError(400, "CLI token 无用户")
    }
    let username = a.username()
    let body = readJsonBody(ctx.request)
    let code = jsonGetString(body, "code")
    let pending = getSetting("pending_mfa:" + username)
    if (pending.isEmpty()) {
        throw HttpError(400, "请先点【生成密钥】")
    }
    let secret = decryptText(pending)
    if (!verifyTotp(secret, code)) {
        throw HttpError(401, "动态码不正确, MFA 未开启")
    }
    db().execParams("UPDATE users SET mfa_secret=? WHERE username=?",
        [DbText(encryptText(secret)), DbText(username)])
    setSetting("pending_mfa:" + username, "")
    audit("user.mfa_enable", ip, auditDetail([("user", username)]))
    respondOk(ctx)
}

func authMfaDisable(ctx: HttpContext, ip: String): Unit {
    let a = requireSession(ctx, ip)
    if (!a.hasUser()) {
        throw HttpError(400, "CLI token 无用户")
    }
    let body = readJsonBody(ctx.request)
    let password = jsonGetString(body, "password")
    let code = jsonGetString(body, "code")
    if (!verifyPassword(password, a.userValue("password_hash"))) {
        throw HttpError(403, "密码错误")
    }
    let secret = decryptText(a.userValue("mfa_secret"))
    if (!verifyTotp(secret, code)) {
        throw HttpError(401, "动态码不正确")
    }
    db().execParams("UPDATE users SET mfa_secret=NULL WHERE username=?", [DbText(a.username())])
    audit("user.mfa_disable", ip, auditDetail([("user", a.username())]))
    respondOk(ctx)
}

func authListTokens(ctx: HttpContext, ip: String): Unit {
    let a = requireSession(ctx, ip)
    if (!a.hasUser()) {
        throw HttpError(400, "CLI token 无用户")
    }
    let arr = JsonArray()
    for (row in listApiTokens(a.username())) {
        arr.add(rowToJson(row))
    }
    respondJsonArray(ctx, 200, arr)
}

func authCreateToken(ctx: HttpContext, ip: String): Unit {
    let a = requireSession(ctx, ip)
    if (!a.hasUser()) {
        throw HttpError(400, "CLI token 无用户")
    }
    let body = readJsonBody(ctx.request)
    var name = jsonGetString(body, "name").trimAscii()
    if (name.isEmpty()) {
        name = "未命名"
    }
    let token = createApiToken(a.username(), name)
    audit("token.create", ip, auditDetail([("user", a.username()), ("name", name)]))
    var prefix = token
    if (prefix.size > 8) {
        prefix = prefix[0..8]
    }
    let out = jObj()
    out.put("token", jStr(token))
    out.put("hint", jStr("此密钥仅显示一次, 请立即复制保存"))
    out.put("usage", jStr("pip install --index-url \"http://<host>:8800/proxy/pypi/simple/?token=" + prefix + "…\" <包名>"))
    respondJsonObject(ctx, 200, out)
}

func authRevokeToken(ctx: HttpContext, ip: String): Unit {
    let a = requireSession(ctx, ip)
    if (!a.hasUser()) {
        throw HttpError(400, "CLI token 无用户")
    }
    let body = readJsonBody(ctx.request)
    let id = jsonGetInt(body, "id")
    if (!revokeApiToken(a.username(), id)) {
        throw HttpError(404, "该密钥不存在或不属于你")
    }
    audit("token.revoke", ip, auditDetail([("user", a.username()), ("tid", id.toString())]))
    respondOk(ctx)
}

func authRevokeLegacyTokens(ctx: HttpContext, ip: String): Unit {
    let a = requireSession(ctx, ip)
    if (!a.hasUser()) {
        throw HttpError(400, "CLI token 无用户")
    }
    let affected = db().execParams(
        "UPDATE api_tokens SET revoked=1 WHERE username=? AND token_algo='sha256' AND revoked=0",
        [DbText(a.username())])
    audit("token.revoke_legacy", ip, auditDetail([("user", a.username()), ("count", affected.toString())]))
    let out = jObj()
    out.put("revoked", jInt(affected))
    respondJsonObject(ctx, 200, out)
}

func handleWhoami(ctx: HttpContext): Unit {
    let auth = authCtx(ctx.request)
    let out = jObj()
    match (auth) {
        case Some(a) =>
            let pub = publicCtx(a)
            let username = a.username()
            let role = if (a.hasUser()) { a.userValue("role") } else { "admin" }
            var legacyTokens: Int64 = 0
            let legacyRow = db().queryOne(
                "SELECT count(*) c FROM api_tokens WHERE username=? AND revoked=0 AND token_algo='sha256'",
                [DbText(username)])
            match (legacyRow) {
                case Some(r) => legacyTokens = vInt(r, "c")
                case None => ()
            }
            var resetNeeded = false
            if (role == "admin") {
                let flag = getSetting("password_reset_needed", def: "0")
                let legacyPwRow = db().queryOne(
                    "SELECT count(*) c FROM users WHERE password_hash NOT LIKE 'sm3$%'", Array<DbValue>())
                let legacyPw = match (legacyPwRow) {
                    case Some(r) => vInt(r, "c")
                    case None => 0
                }
                resetNeeded = flag == "1" || legacyPw > 0
            }
            pub.put("legacy_tokens", jInt(legacyTokens))
            pub.put("password_reset_needed", jBool(resetNeeded))
            out.put("user", pub)
        case None =>
            out.put("user", jNull())
    }
    respondJsonObject(ctx, 200, out)
}
