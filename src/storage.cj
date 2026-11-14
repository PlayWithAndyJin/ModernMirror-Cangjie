package modernmirror

import std.collection.*
import std.fs.*
import std.io.*
import std.sort.*
import std.sync.*
import std.time.*
import std.convert.*

class FileBody <: InputStream {
    let file: File
    var closed: Bool = false

    init(path: String, start!: Int64 = 0) {
        file = File(path, OpenMode.Read)
        if (start > 0) {
            file.seek(SeekPosition.Begin(start))
        }
    }

    public func read(buffer: Array<UInt8>): Int64 {
        if (closed) {
            return 0
        }
        return file.read(buffer)
    }

    public func close(): Unit {
        if (!closed) {
            closed = true
            file.close()
        }
    }
}

func safePath(repo: String, path: String): String {
    let digest = sha256Hex((repo + ":" + path).toArray())
    return joinPath(joinPath(joinPath(CACHE_DIR, repo), digest[0..2]), digest)
}

func tmpDir(): String {
    let d = joinPath(DATA_DIR, "tmp")
    ensureDir(d)
    return d
}

func saveCachedFile(tmpPath: String, repo: String, path: String): String {
    let target = safePath(repo, path)
    let parent = target[0..target.lastIndexOf("/").getOrThrow()]
    ensureDir(parent)
    moveFile(tmpPath, target)
    return target
}

func cleanupKeepLastN(days: Int64): Int64 {
    var rows: ArrayList<DbRow>
    if (days <= 0) {
        rows = db().query("SELECT id, file_path, size FROM cache_entries", Array<DbValue>())
    } else {
        let offset = "-" + days.toString() + " days"
        rows = db().query(
            "SELECT id, file_path, size FROM cache_entries " +
            "WHERE (last_hit_at IS NULL AND fetched_at < datetime('now', 'localtime', ?)) " +
            "OR last_hit_at < datetime('now', 'localtime', ?)",
            [DbText(offset), DbText(offset)])
    }
    var freed: Int64 = 0
    for (row in rows) {
        let filePath = vText(row, "file_path")
        try {
            if (fileExists(filePath)) {
                remove(filePath)
                freed = freed + vInt(row, "size")
            }
        } catch (e: Exception) {
            (e)
        }
        db().execParams("DELETE FROM cache_entries WHERE id=?", [DbInt(vInt(row, "id"))])
    }
    pruneDirs()
    return freed
}

func pruneDirs(): Unit {
    if (!exists(CACHE_DIR)) {
        return
    }
    let dirs = ArrayList<String>()
    walkDirs(CACHE_DIR, dirs)
    dirs.sortDescending()
    for (d in dirs) {
        if (d == CACHE_DIR) {
            continue
        }
        try {
            if (listEntries(d).size == 0) {
                removeIfExists(d, recursive: true)
            }
        } catch (e: Exception) {
            (e)
        }
    }
}

func walkDirs(path: String, out: ArrayList<String>): Unit {
    out.add(path)
    for (info in listEntries(path)) {
        if (info.isDirectory()) {
            walkDirs(info.path.toString(), out)
        }
    }
}

func repoUsage(repo: String): Int64 {
    let row = db().queryOne(
        "SELECT coalesce(sum(size),0) s FROM cache_entries WHERE repo=?", [DbText(repo)])
    return match (row) {
        case Some(r) => vInt(r, "s")
        case None => 0
    }
}

func enforceQuota(repo: String, quotaMb: Int64): Int64 {
    if (quotaMb <= 0) {
        return 0
    }
    let limit = quotaMb * 1024 * 1024
    var total = repoUsage(repo)
    if (total <= limit) {
        return 0
    }
    let target = Int64(Float64(limit) * 0.9)
    let rows = db().query(
        "SELECT id, file_path, size FROM cache_entries WHERE repo=? " +
        "ORDER BY coalesce(last_hit_at,'') ASC, hits ASC", [DbText(repo)])
    var freed: Int64 = 0
    for (row in rows) {
        if (total <= target) {
            break
        }
        let filePath = vText(row, "file_path")
        try {
            if (fileExists(filePath)) {
                remove(filePath)
            }
        } catch (e: Exception) {
            (e)
        }
        db().execParams("DELETE FROM cache_entries WHERE id=?", [DbInt(vInt(row, "id"))])
        total = total - vInt(row, "size")
        freed = freed + vInt(row, "size")
    }
    pruneDirs()
    return freed
}

func startCleanupScheduler(): Unit {
    spawn {
        while (true) {
            try {
                let now = DateTime.now()
                let today = now.format("yyyy-MM-dd")
                let hour = match (Int64.tryParse(now.format("HH"))) {
                    case Some(v) => v
                    case None => 0
                }
                let enabled = getSetting("cleanup_enabled", def: "1") == "1"
                let last = getSetting("last_cleanup_date", def: "")
                if (enabled && hour >= 3 && last != today) {
                    let raw = getSetting("cache_retention_days", def: "30")
                    let days = match (Int64.tryParse(raw)) {
                        case Some(v) => v
                        case None => 30
                    }
                    let freed = cleanupKeepLastN(days)
                    setSetting("last_cleanup_date", today)
                    if (freed > 0) {
                        let detail = jObj()
                        detail.put("days", jInt(days))
                        detail.put("freed", jInt(freed))
                        audit("cache.scheduled_cleanup", "scheduler", detail)
                    }
                }
            } catch (e: Exception) {
                (e)
            }
            sleep(Duration.minute * 30)
        }
    }
    return
}
