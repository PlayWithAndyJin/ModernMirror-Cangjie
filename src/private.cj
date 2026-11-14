package modernmirror

import std.collection.*
import std.fs.*
import std.regex.*
import stdx.net.http.*
import stdx.encoding.json.*

func guessName(filename: String): String {
    let dash = filename.indexOf("-")
    match (dash) {
        case Some(i) => return filename[0..i]
        case None => ()
    }
    let under = filename.indexOf("_")
    match (under) {
        case Some(i) => return filename[0..i]
        case None => ()
    }
    let dot = filename.lastIndexOf(".")
    match (dot) {
        case Some(i) => return filename[0..i]
        case None => return filename
    }
}

func guessVersion(filename: String): String {
    try {
        let pattern = Regex("-([0-9]+\\.[0-9]+[A-Za-z0-9_.]*)\\.")
        let found = pattern.find(filename, group: true)
        match (found) {
            case Some(m) => return m.matchString(1)
            case None => return ""
        }
    } catch (e: Exception) {
        return ""
    }
}

func saveUpload(part: MultipartPart, repo: String, uploader: String): JsonObject {
    var safeName = baseName(part.filename)
    if (safeName.isEmpty() || safeName.startsWith(".")) {
        throw HttpError(400, "invalid filename")
    }
    let repoDir = joinPath(PRIVATE_DIR, repo)
    ensureDir(repoDir)
    let dest = joinPath(repoDir, safeName)
    let tmp = dest + ".upload-" + randomHex(6)
    let maxBytes = MAX_UPLOAD_MB * 1024 * 1024
    if (Int64(part.data.size) > maxBytes) {
        throw HttpError(413, "文件超过上限 " + MAX_UPLOAD_MB.toString() + "MB")
    }
    try {
        writeAllBytes(tmp, part.data)
        moveFile(tmp, dest)
    } catch (e: Exception) {
        deleteFileIfExists(tmp)
        throw e
    }
    let digest = sha256Hex(part.data)
    db().execParams(
        "INSERT INTO private_packages (repo, name, version, filename, filepath, size, sha256, uploader) " +
        "VALUES (?,?,?,?,?,?,?,?) " +
        "ON CONFLICT(repo, filename) DO UPDATE SET " +
        "filepath=excluded.filepath, size=excluded.size, " +
        "sha256=excluded.sha256, uploader=excluded.uploader, " +
        "created_at=datetime('now', 'localtime')",
        [DbText(repo), DbText(guessName(safeName)), DbText(guessVersion(safeName)),
         DbText(safeName), DbText(dest), DbInt(Int64(part.data.size)),
         DbText(digest), DbText(uploader)])
    let out = jObj()
    out.put("filename", jStr(safeName))
    out.put("size", jInt(Int64(part.data.size)))
    out.put("sha256", jStr(digest))
    return out
}

func handlePackageDownload(ctx: HttpContext, ip: String, path: String): Unit {
    let parts = routeSegments(path)
    if (parts.size != 3) {
        throw HttpError(404, "not found")
    }
    let repo = parts[1]
    let filename = parts[2]
    requireRepoPermission(ctx, ip, repo, "can_download")
    let row = db().queryOne("SELECT * FROM private_packages WHERE repo=? AND filename=?",
        [DbText(repo), DbText(filename)])
    match (row) {
        case Some(r) =>
            let filePath = vText(r, "filepath")
            if (!fileExists(filePath)) {
                throw HttpError(404, "not found")
            }
            corsHeaders(ctx.responseBuilder.status(200)
                .header("content-type", "application/octet-stream")
                .header("content-length", vInt(r, "size").toString()))
            ctx.responseBuilder.body(FileBody(filePath))
        case None => throw HttpError(404, "not found")
    }
}

func handleSimpleIndex(ctx: HttpContext, ip: String, path: String): Unit {
    let parts = routeSegments(path)
    if (parts.size != 2) {
        throw HttpError(404, "not found")
    }
    let repo = parts[1]
    requireRepoPermission(ctx, ip, repo, "can_download")
    let rows = db().query(
        "SELECT filename FROM private_packages WHERE repo=? ORDER BY filename", [DbText(repo)])
    let links = StringBuilder()
    for (row in rows) {
        let name = htmlEscape(vText(row, "filename"))
        links.append("<a href=\"/pkg/" + htmlEscape(repo) + "/" + name + "\">" + name + "</a><br>\n")
    }
    let safeRepo = htmlEscape(repo)
    let body = "<html><head><title>" + safeRepo + "</title></head><body><h1>" + safeRepo + "</h1>" +
        links.toString() + "</body></html>"
    respondText(ctx, 200, body, contentType: "text/html; charset=utf-8")
}
