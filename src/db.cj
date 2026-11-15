package modernmirror

import std.collection.*
import stdx.encoding.json.*

var G_DB: ?Db = None

func db(): Db {
    match (G_DB) {
        case Some(d) => return d
        case None => throw Exception("database not initialized")
    }
}

func dbInit(): Unit {
    G_DB = Db(DB_PATH)
    let conn = db()
    conn.exec(
        """
        CREATE TABLE IF NOT EXISTS repos (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT UNIQUE NOT NULL,
            type TEXT NOT NULL,
            upstream TEXT NOT NULL,
            enabled INTEGER NOT NULL DEFAULT 1,
            anonymous INTEGER NOT NULL DEFAULT 0,
            created_at TEXT DEFAULT (datetime('now', 'localtime'))
        )
        """)
    conn.exec(
        """
        CREATE TABLE IF NOT EXISTS cache_entries (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            repo TEXT NOT NULL,
            path TEXT NOT NULL,
            upstream_url TEXT NOT NULL,
            file_path TEXT NOT NULL,
            size INTEGER NOT NULL,
            content_type TEXT,
            etag TEXT,
            fetched_at TEXT,
            last_hit_at TEXT,
            hits INTEGER NOT NULL DEFAULT 0,
            verified INTEGER NOT NULL DEFAULT 0,
            UNIQUE(repo, path)
        )
        """)
    conn.exec(
        """
        CREATE TABLE IF NOT EXISTS private_packages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            repo TEXT NOT NULL,
            name TEXT NOT NULL,
            version TEXT,
            filename TEXT NOT NULL,
            filepath TEXT NOT NULL,
            size INTEGER NOT NULL,
            sha256 TEXT,
            uploader TEXT,
            created_at TEXT DEFAULT (datetime('now', 'localtime')),
            verified INTEGER NOT NULL DEFAULT 0,
            UNIQUE(repo, filename)
        )
        """)
    conn.exec(
        """
        CREATE TABLE IF NOT EXISTS users (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            username TEXT UNIQUE NOT NULL,
            password_hash TEXT NOT NULL,
            role TEXT NOT NULL DEFAULT 'user',
            mfa_secret TEXT,
            enabled INTEGER NOT NULL DEFAULT 1,
            created_at TEXT DEFAULT (datetime('now', 'localtime')),
            password_algo TEXT NOT NULL DEFAULT 'sha256'
        )
        """)
    conn.exec(
        """
        CREATE TABLE IF NOT EXISTS sessions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            token TEXT UNIQUE NOT NULL,
            username TEXT NOT NULL,
            expires TEXT NOT NULL,
            mfa_state INTEGER NOT NULL DEFAULT 0
        )
        """)
    conn.exec(
        """
        CREATE TABLE IF NOT EXISTS groups (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT UNIQUE NOT NULL,
            description TEXT DEFAULT '',
            created_at TEXT DEFAULT (datetime('now', 'localtime'))
        )
        """)
    conn.exec(
        """
        CREATE TABLE IF NOT EXISTS user_groups (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            username TEXT NOT NULL,
            group_id INTEGER NOT NULL,
            UNIQUE(username, group_id)
        )
        """)
    conn.exec(
        """
        CREATE TABLE IF NOT EXISTS group_repos (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            group_id INTEGER NOT NULL,
            repo TEXT NOT NULL,
            can_download INTEGER NOT NULL DEFAULT 1,
            can_upload INTEGER NOT NULL DEFAULT 0,
            UNIQUE(group_id, repo)
        )
        """)
    conn.exec(
        """
        CREATE TABLE IF NOT EXISTS settings (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        )
        """)
    conn.exec(
        """
        CREATE TABLE IF NOT EXISTS api_tokens (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            username TEXT NOT NULL,
            name TEXT NOT NULL,
            token_hash TEXT UNIQUE NOT NULL,
            token_prefix TEXT NOT NULL,
            created_at TEXT DEFAULT (datetime('now', 'localtime')),
            last_used_at TEXT,
            revoked INTEGER NOT NULL DEFAULT 0,
            token_algo TEXT NOT NULL DEFAULT 'sha256'
        )
        """)
    dbRunAlter("ALTER TABLE cache_entries ADD COLUMN verified INTEGER NOT NULL DEFAULT 0")
    dbRunAlter("ALTER TABLE users ADD COLUMN password_algo TEXT NOT NULL DEFAULT 'sha256'")
    dbRunAlter("ALTER TABLE api_tokens ADD COLUMN token_algo TEXT NOT NULL DEFAULT 'sha256'")
    dbRunAlter("ALTER TABLE repos ADD COLUMN upstreams TEXT NOT NULL DEFAULT '[]'")
    dbRunAlter("ALTER TABLE repos ADD COLUMN quota_mb INTEGER NOT NULL DEFAULT 0")
    dbRunAlter("ALTER TABLE repos ADD COLUMN anonymous INTEGER NOT NULL DEFAULT 0")
}

func dbRunAlter(sql: String): Unit {
    try {
        db().exec(sql)
    } catch (e: Exception) {
        ()
    }
}

func backfillRepos(): Unit {
    let rows = db().query("SELECT name, upstream, upstreams FROM repos", Array<DbValue>())
    for (row in rows) {
        let raw = vText(row, "upstreams")
        var empty = true
        if (!raw.isEmpty() && raw != "[]") {
            empty = false
        }
        if (empty && !vText(row, "upstream").isEmpty()) {
            let arr = JsonArray()
            arr.add(JsonString(vText(row, "upstream")))
            db().execParams("UPDATE repos SET upstreams=? WHERE name=?",
                [DbText(compactJson(arr)), DbText(vText(row, "name"))])
        }
    }
}

func seedAdmin(): Unit {
    db().execParams("INSERT OR IGNORE INTO groups (name, description) VALUES (?, ?)",
        [DbText("default"), DbText("默认组,新增用户自动加入")])
    let wizardUser = envOr("MODERNMIRROR_ADMIN_USER", "admin").trimAscii()
    let wizardPass = envOr("MODERNMIRROR_ADMIN_PASSWORD", "admin123")
    let countRow = db().queryOne("SELECT count(*) AS c FROM users", Array<DbValue>())
    let isFirstInstall = match (countRow) {
        case Some(r) => vInt(r, "c") == 0
        case None => true
    }
    if (isFirstInstall) {
        db().execParams(
            "INSERT INTO users (username, password_hash, role, password_algo) VALUES (?, ?, 'admin', 'sm3')",
            [DbText(wizardUser), DbText(hashPassword(wizardPass))])
        db().execParams(
            "INSERT OR IGNORE INTO user_groups (username, group_id) SELECT ?, id FROM groups WHERE name='default'",
            [DbText(wizardUser)])
    } else if (!wizardPass.isEmpty() && wizardPass != "admin123") {
        let status = envOr("TRIM_APP_STATUS", "")
        db().execParams("INSERT OR IGNORE INTO settings (key, value) VALUES ('admin_provisioned', '0')", Array<DbValue>())
        let statedRow = db().queryOne("SELECT value FROM settings WHERE key='admin_provisioned'", Array<DbValue>())
        let stated = match (statedRow) {
            case Some(r) => vText(r, "value")
            case None => ""
        }
        if (stated.isEmpty() || stated == "0" || status == "CONFIG") {
            let existing = db().queryOne("SELECT username FROM users WHERE username=? AND role='admin'",
                [DbText(wizardUser)])
            match (existing) {
                case Some(_) =>
                    db().execParams("UPDATE users SET password_hash=?, password_algo='sm3' WHERE username=?",
                        [DbText(hashPassword(wizardPass)), DbText(wizardUser)])
                case None =>
                    let base = db().queryOne("SELECT username FROM users WHERE role='admin' LIMIT 1", Array<DbValue>())
                    match (base) {
                        case Some(b) =>
                            if (vText(b, "username") == "admin") {
                                db().execParams("UPDATE users SET username=?, password_hash=?, password_algo='sm3' WHERE username='admin'",
                                    [DbText(wizardUser), DbText(hashPassword(wizardPass))])
                            }
                        case None => ()
                    }
            }
            db().execParams("UPDATE users SET mfa_secret=NULL WHERE username=? AND role='admin'", [DbText(wizardUser)])
            db().execParams("DELETE FROM sessions WHERE username=?", [DbText(wizardUser)])
            db().execParams(
                "INSERT OR IGNORE INTO user_groups (username, group_id) SELECT ?, id FROM groups WHERE name='default'",
                [DbText(wizardUser)])
            db().execParams("UPDATE settings SET value='1' WHERE key='admin_provisioned'", Array<DbValue>())
        }
    } else {
        db().execParams("INSERT OR IGNORE INTO settings (key, value) VALUES ('admin_provisioned', '1')", Array<DbValue>())
    }
}

func dbSeed(): Unit {
    backfillRepos()
    let defaults = [
        ("pypi", "pypi", "https://pypi.org"),
        ("npm", "npm", "https://registry.npmjs.org"),
        ("debian", "raw", "https://deb.debian.org"),
        ("alpine", "raw", "https://dl-cdn.alpinelinux.org")
    ]
    for (item in defaults) {
        let arr = JsonArray()
        arr.add(JsonString(item[2]))
        db().execParams("INSERT OR IGNORE INTO repos (name, type, upstream, upstreams) VALUES (?, ?, ?, ?)",
            [DbText(item[0]), DbText(item[1]), DbText(item[2]), DbText(compactJson(arr))])
    }
    dbRunAlter("ALTER TABLE cache_entries ADD COLUMN verified INTEGER NOT NULL DEFAULT 0")
    dbRunAlter("ALTER TABLE private_packages ADD COLUMN verified INTEGER NOT NULL DEFAULT 0")
}

func migrateCryptoData(): Unit {
    db().execParams("INSERT OR IGNORE INTO settings (key, value) VALUES ('crypto_version', '0')", Array<DbValue>())
    db().execParams("INSERT OR IGNORE INTO settings (key, value) VALUES ('password_reset_needed', '0')", Array<DbValue>())
    let versionRow = db().queryOne("SELECT value FROM settings WHERE key='crypto_version'", Array<DbValue>())
    let version = match (versionRow) {
        case Some(r) => vInt(r, "value")
        case None => 0
    }
    if (version >= 2 || DB_MASTER_KEY.isEmpty()) {
        return
    }
    let rows = db().query("SELECT username, mfa_secret FROM users WHERE mfa_secret IS NOT NULL", Array<DbValue>())
    for (row in rows) {
        let secret = vText(row, "mfa_secret")
        if (isLegacyCipher(secret)) {
            let plain = decryptText(secret)
            db().execParams("UPDATE users SET mfa_secret=? WHERE username=?",
                [DbText(encryptText(plain)), DbText(vText(row, "username"))])
        }
    }
    let pending = db().query("SELECT key, value FROM settings WHERE key LIKE 'pending_mfa:%'", Array<DbValue>())
    for (row in pending) {
        let value = vText(row, "value")
        if (!value.isEmpty() && isLegacyCipher(value)) {
            let plain = decryptText(value)
            db().execParams("UPDATE settings SET value=? WHERE key=?",
                [DbText(encryptText(plain)), DbText(vText(row, "key"))])
        }
    }
    if (fileExists(AUDIT_LOG)) {
        let text = String.fromUtf8(readAllBytes(AUDIT_LOG))
        let lines = ArrayList<String>()
        var changed = false
        for (line in text.split("\n")) {
            if (line.startsWith("enc|") && line.contains("enc:v1:")) {
                try {
                    let plain = decryptText(line[4..])
                    lines.add("sm|" + encryptText(plain))
                    changed = true
                    continue
                } catch (e: Exception) {
                    ()
                }
            }
            lines.add(line)
        }
        if (changed) {
            writeAllBytes(AUDIT_LOG + ".legacy.bak", readAllBytes(AUDIT_LOG))
            writeAllText(AUDIT_LOG, String.join(lines.toArray(), delimiter: "\n") + "\n")
        }
    }
    db().execParams("DELETE FROM sessions", Array<DbValue>())
    let legacyRow = db().queryOne("SELECT count(*) AS c FROM users WHERE password_hash NOT LIKE 'sm3$%'", Array<DbValue>())
    let legacyPw = match (legacyRow) {
        case Some(r) => vInt(r, "c")
        case None => 0
    }
    db().execParams("UPDATE settings SET value=? WHERE key='password_reset_needed'",
        [DbText(if (legacyPw > 0) { "1" } else { "0" })])
    db().execParams("UPDATE settings SET value='2' WHERE key='crypto_version'", Array<DbValue>())
}
