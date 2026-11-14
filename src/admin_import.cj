package modernmirror

import std.collection.*
import stdx.encoding.json.*
import stdx.net.http.*

func splitCsvRecords(text: String): ArrayList<ArrayList<String>> {
    let records = ArrayList<ArrayList<String>>()
    var fields = ArrayList<String>()
    let field = StringBuilder()
    var inQuotes = false
    let runes = text.toRuneArray()
    var i: Int64 = 0
    while (i < runes.size) {
        let c = runes[i]
        if (inQuotes) {
            if (c == r'"') {
                if (i + 1 < runes.size && runes[i + 1] == r'"') {
                    field.append("\"")
                    i = i + 2
                    continue
                }
                inQuotes = false
                i = i + 1
                continue
            }
            field.append(c.toString())
            i = i + 1
            continue
        }
        if (c == r'"') {
            inQuotes = true
            i = i + 1
            continue
        }
        if (c == r',') {
            fields.add(field.toString().trimAscii())
            field.reset()
            i = i + 1
            continue
        }
        if (c == r'\n') {
            fields.add(field.toString().trimAscii())
            field.reset()
            records.add(fields)
            fields = ArrayList<String>()
            i = i + 1
            continue
        }
        if (c == r'\r') {
            i = i + 1
            continue
        }
        field.append(c.toString())
        i = i + 1
    }
    if (field.toString().size > 0 || fields.size > 0) {
        fields.add(field.toString().trimAscii())
        records.add(fields)
    }
    let out = ArrayList<ArrayList<String>>()
    for (record in records) {
        var empty = true
        for (value in record) {
            if (!value.isEmpty()) {
                empty = false
                break
            }
        }
        if (!empty) {
            out.add(record)
        }
    }
    return out
}

func parseGroupsText(value: String): ArrayList<String> {
    let out = ArrayList<String>()
    if (value.isEmpty()) {
        return out
    }
    var normalized = value.replace(";", ",").replace("|", ",")
    for (item in normalized.split(",")) {
        var name = item.trimAscii()
        if (name.startsWith("\"")) {
            name = name[1..]
        }
        if (name.endsWith("\"")) {
            name = name[0..name.size - 1]
        }
        if (name.startsWith("'")) {
            name = name[1..]
        }
        if (name.endsWith("'")) {
            name = name[0..name.size - 1]
        }
        name = name.trimAscii()
        if (!name.isEmpty()) {
            var duplicate = false
            for (existing in out) {
                if (existing == name) {
                    duplicate = true
                    break
                }
            }
            if (!duplicate) {
                out.add(name)
            }
        }
    }
    return out
}

func parseCsvMembers(text: String): ArrayList<MemberRow> {
    let out = ArrayList<MemberRow>()
    let records = splitCsvRecords(text)
    if (records.size == 0) {
        return out
    }
    let headers = ArrayList<String>()
    for (header in records[0]) {
        headers.add(header.toAsciiLower())
    }
    var r: Int64 = 1
    while (r < records.size) {
        let record = records[r]
        let map = HashMap<String, String>()
        var i: Int64 = 0
        while (i < record.size && i < headers.size) {
            map.add(headers[i], record[i])
            i = i + 1
        }
        let username = lookup(map, "username")
        if (!username.isEmpty()) {
            out.add(MemberRow(username, lookup(map, "password"), lookup(map, "role"),
                lookup(map, "groups"), !lookup(map, "role").isEmpty()))
        }
        r = r + 1
    }
    return out
}

func lookup(map: HashMap<String, String>, key: String): String {
    return match (map.get(key)) {
        case Some(v) => v
        case None => ""
    }
}

func jsonValueText(value: JsonValue): String {
    return match (value.kind()) {
        case JsonKind.JsString => value.asString().getValue()
        case JsonKind.JsInt => value.asInt().getValue().toString()
        case JsonKind.JsFloat => value.asFloat().getValue().toString()
        case JsonKind.JsBool => value.asBool().getValue().toString()
        case _ => ""
    }
}

func jsonValueGroups(value: JsonValue): String {
    return match (value.kind()) {
        case JsonKind.JsArray =>
            let parts = ArrayList<String>()
            for (item in value.asArray().getItems()) {
                let text = jsonValueText(item)
                if (!text.isEmpty()) {
                    parts.add(text)
                }
            }
            String.join(parts.toArray(), delimiter: ",")
        case _ => jsonValueText(value)
    }
}

func parseJsonMembers(text: String): ArrayList<MemberRow> {
    let out = ArrayList<MemberRow>()
    let value = JsonValue.fromStr(text)
    match (value.kind()) {
        case JsonKind.JsArray =>
            for (item in value.asArray().getItems()) {
                match (item.kind()) {
                    case JsonKind.JsString =>
                        let username = item.asString().getValue().trimAscii()
                        if (!username.isEmpty()) {
                            out.add(MemberRow(username, "", "", "", false))
                        }
                    case JsonKind.JsObject =>
                        let obj = item.asObject()
                        let username = jsonGetString(obj, "username").trimAscii()
                        if (!username.isEmpty()) {
                            let hasRole = obj.containsKey("role") &&
                                !jsonGetString(obj, "role").trimAscii().isEmpty()
                            let groups = match (obj.get("groups")) {
                                case Some(v) => jsonValueGroups(v)
                                case None => ""
                            }
                            out.add(MemberRow(username, jsonGetString(obj, "password"),
                                jsonGetString(obj, "role"), groups, hasRole))
                        }
                    case _ => ()
                }
            }
        case _ => throw Exception("JSON must be an array")
    }
    return out
}

func unquoteToml(raw: String): String {
    var value = raw.trimAscii()
    if (value.startsWith("\"")) {
        value = value[1..]
        let end = value.indexOf("\"")
        match (end) {
            case Some(i) => value = value[0..i]
            case None => ()
        }
        return value
    }
    if (value.startsWith("'")) {
        value = value[1..]
        let end = value.indexOf("'")
        match (end) {
            case Some(i) => value = value[0..i]
            case None => ()
        }
        return value
    }
    return value
}

func tomlArrayValues(raw: String): String {
    var value = raw.trimAscii()
    if (!value.startsWith("[")) {
        return unquoteToml(value)
    }
    value = value[1..]
    let end = value.lastIndexOf("]")
    match (end) {
        case Some(i) => value = value[0..i]
        case None => ()
    }
    let parts = ArrayList<String>()
    for (item in value.split(",")) {
        let text = unquoteToml(item)
        if (!text.isEmpty()) {
            parts.add(text)
        }
    }
    return String.join(parts.toArray(), delimiter: ",")
}

func parseTomlMembers(text: String): ArrayList<MemberRow> {
    let out = ArrayList<MemberRow>()
    var inSection = false
    let map = HashMap<String, String>()
    var hasData = false
    for (line in text.split("\n")) {
        let trimmed = line.trimAscii()
        if (trimmed.isEmpty() || trimmed.startsWith("#")) {
            continue
        }
        if (trimmed.startsWith("[[")) {
            if (hasData) {
                flushTomlMember(out, map, hasData)
            }
            hasData = false
            map.clear()
            inSection = trimmed == "[[members]]" || trimmed == "[[users]]"
            continue
        }
        if (trimmed.startsWith("[")) {
            if (hasData) {
                flushTomlMember(out, map, hasData)
            }
            hasData = false
            map.clear()
            inSection = false
            continue
        }
        if (!inSection) {
            continue
        }
        let eq = trimmed.indexOf("=")
        match (eq) {
            case Some(i) =>
                let key = trimmed[0..i].trimAscii().toAsciiLower()
                let rawValue = trimmed[i + 1..].trimAscii()
                map.add(key, tomlArrayValues(rawValue))
                hasData = true
            case None => ()
        }
    }
    if (hasData) {
        flushTomlMember(out, map, hasData)
    }
    return out
}

func flushTomlMember(out: ArrayList<MemberRow>, map: HashMap<String, String>, hasData: Bool): Unit {
    let username = lookup(map, "username").trimAscii()
    if (!username.isEmpty()) {
        out.add(MemberRow(username, lookup(map, "password"), lookup(map, "role"),
            lookup(map, "groups"), !lookup(map, "role").trimAscii().isEmpty()))
    }
}

func parseTxtMembers(text: String): ArrayList<MemberRow> {
    let out = ArrayList<MemberRow>()
    for (line in text.split("\n")) {
        let trimmed = line.trimAscii()
        if (trimmed.isEmpty() || trimmed.startsWith("#")) {
            continue
        }
        let records = splitCsvRecords(trimmed)
        if (records.size == 0) {
            continue
        }
        let fields = records[0]
        if (fields.size == 0) {
            continue
        }
        let username = fields[0].trimAscii()
        if (username.isEmpty()) {
            continue
        }
        let password = if (fields.size > 1) { fields[1].trimAscii() } else { "" }
        let role = if (fields.size > 2) { fields[2].trimAscii() } else { "" }
        let groups = if (fields.size > 3) { fields[3].trimAscii() } else { "" }
        out.add(MemberRow(username, password, role, groups, !role.isEmpty()))
    }
    return out
}

func parseMemberFile(filename: String, raw: Array<Byte>): ArrayList<MemberRow> {
    var text = String.fromUtf8(raw)
    if (text.startsWith("\u{FEFF}")) {
        text = text[1..]
    }
    let suffix = extName(filename)
    if (suffix == "csv") {
        return parseCsvMembers(text)
    }
    if (suffix == "json") {
        return parseJsonMembers(text)
    }
    if (suffix == "toml") {
        return parseTomlMembers(text)
    }
    if (suffix == "txt") {
        return parseTxtMembers(text)
    }
    throw Exception("unsupported file type, use csv/json/toml/txt")
}

func importError(username: String, reason: String): JsonObject {
    let obj = jObj()
    obj.put("username", jStr(username))
    obj.put("reason", jStr(reason))
    return obj
}

func adminImportMembers(ctx: HttpContext, ip: String, rawGid: String): Unit {
    requireAdmin(ctx, ip)
    let gid = parseGid(rawGid)
    let part = multipartFile(ctx.request, 8 * 1024 * 1024)
    let lower = part.filename.toAsciiLower()
    if (!(lower.endsWith(".csv") || lower.endsWith(".json") ||
        lower.endsWith(".toml") || lower.endsWith(".txt"))) {
        throw HttpError(400, "仅支持 CSV / JSON / TOML / TXT 文件")
    }
    if (Int64(part.data.size) > 2 * 1024 * 1024) {
        throw HttpError(400, "文件超过 2MB")
    }
    var entries: ArrayList<MemberRow>
    try {
        entries = parseMemberFile(part.filename, part.data)
    } catch (e: Exception) {
        throw HttpError(400, "文件内容格式不正确，请参照模板检查后重试")
    }
    if (entries.size == 0) {
        throw HttpError(400, "文件中没有可导入的成员")
    }
    let groupRow = db().queryOne("SELECT name FROM groups WHERE id=?", [DbInt(gid)])
    if (groupRow.isNone()) {
        throw HttpError(404, "组不存在")
    }
    let groupName = match (groupRow) {
        case Some(r) => vText(r, "name")
        case None => ""
    }
    let created = JsonArray()
    let added = JsonArray()
    let existsList = JsonArray()
    let errors = JsonArray()
    let groupCreated = JsonArray()
    let seen = HashSet<String>()
    for (row in entries) {
        var username = row.username.trimAscii()
        var password = row.password.trimAscii()
        var role = row.role.trimAscii().toAsciiLower()
        if (role.isEmpty()) {
            role = "user"
        }
        var groups = parseGroupsText(row.groups)
        if (groups.size == 0) {
            groups.add(groupName)
        }
        if (username.isEmpty()) {
            errors.add(importError("", "用户名为空"))
            continue
        }
        if (!usernameError(username).isEmpty()) {
            errors.add(importError(username, "用户名不能为空、不能包含空白字符且最长 64 位"))
            continue
        }
        if (role != "admin" && role != "user") {
            errors.add(importError(username, "角色不正确，仅支持 user 或 admin"))
            continue
        }
        if (seen.contains(username)) {
            errors.add(importError(username, "用户 " + username + " 在文件中重复出现，已跳过"))
            continue
        }
        seen.add(username)
        let userRow = db().queryOne("SELECT username, role FROM users WHERE username=?",
            [DbText(username)])
        match (userRow) {
            case None =>
                if (!password.isEmpty() && password.size < 8) {
                    errors.add(importError(username, "初始密码长度不足 8 位"))
                    continue
                }
                let generated = if (password.isEmpty()) { generateSimplePassword(12) } else { "" }
                let actual = if (password.isEmpty()) { generated } else { password }
                db().execParams(
                    "INSERT INTO users (username, password_hash, role, password_algo) VALUES (?,?,?,'sm3')",
                    [DbText(username), DbText(hashPassword(actual)), DbText(role)])
                let item = jObj()
                item.put("username", jStr(username))
                item.put("role", jStr(role))
                item.put("password", jStr(actual))
                item.put("generated", jBool(!generated.isEmpty()))
                let groupArr = JsonArray()
                for (g in groups) {
                    groupArr.add(jStr(g))
                }
                item.put("groups", groupArr)
                created.add(item)
            case Some(existing) =>
                if (row.hasRole && role != vText(existing, "role")) {
                    errors.add(importError(username,
                        "用户已存在，当前角色为 " + vText(existing, "role") + "，未变更角色"))
                }
        }
        for (gname in groups) {
            var gidValue: Int64 = 0
            let found = db().queryOne("SELECT id FROM groups WHERE name=?", [DbText(gname)])
            match (found) {
                case Some(g) => gidValue = vInt(g, "id")
                case None =>
                    db().execParams("INSERT INTO groups (name, description) VALUES (?, '')", [DbText(gname)])
                    let fresh = db().queryOne("SELECT id FROM groups WHERE name=?", [DbText(gname)])
                    match (fresh) {
                        case Some(f) => gidValue = vInt(f, "id")
                        case None => ()
                    }
                    groupCreated.add(jStr(gname))
            }
            let affected = db().execParams(
                "INSERT OR IGNORE INTO user_groups (username, group_id) VALUES (?,?)",
                [DbText(username), DbInt(gidValue)])
            if (affected > 0 && gname == groupName) {
                added.add(jStr(username))
            } else if (affected == 0 && gname == groupName) {
                existsList.add(jStr(username))
            }
        }
    }
    let detail = jObj()
    detail.put("gid", jStr(gid.toString()))
    detail.put("group", jStr(groupName))
    detail.put("count", jStr(seen.size.toString()))
    detail.put("created", jStr(created.size().toString()))
    detail.put("groups_created", groupCreated)
    audit("group.member_import", ip, detail)
    let out = jObj()
    out.put("total", jInt(seen.size))
    out.put("created", created)
    out.put("added_to_group", added)
    out.put("already_in_group", existsList)
    out.put("groups_created", groupCreated)
    out.put("errors", errors)
    respondJsonObject(ctx, 200, out)
}

func handleTemplate(ctx: HttpContext, path: String): Unit {
    let auth = authCtx(ctx.request)
    match (auth) {
        case Some(_) => ()
        case None => throw HttpError(401, "login required")
    }
    let name = baseName(path)
    let files = HashMap<String, (String, String)>()
    files.add("members.csv", ("members.csv", "text/csv"))
    files.add("members.json", ("members.json", "application/json"))
    files.add("members.toml", ("members.toml", "application/toml"))
    files.add("members.txt", ("members.txt", "text/plain"))
    match (files.get(name)) {
        case Some(pair) =>
            let filePath = joinPath("templates", pair[0])
            if (!fileExists(filePath)) {
                throw HttpError(404, "template file missing")
            }
            serveFile(ctx, filePath, downloadName: pair[0])
        case None => throw HttpError(404, "template not found")
    }
}
