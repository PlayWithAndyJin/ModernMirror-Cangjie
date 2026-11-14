package modernmirror

import std.collection.*
import std.fs.*

let APP_NAME = "ModernMirror"
let APP_VERSION = "1.1.23"
let DATA_DIR = envOr("MODERNMIRROR_DATA", "data")
let DB_PATH = joinPath(DATA_DIR, "modernmirror.db")
let CACHE_DIR = joinPath(DATA_DIR, "cache")
let PRIVATE_DIR = joinPath(DATA_DIR, "private")
let ADMIN_TOKEN = envOr("MODERNMIRROR_TOKEN", "admin-token")
let HOST = envOr("MODERNMIRROR_HOST", "0.0.0.0")
let PORT = UInt16(envInt("MODERNMIRROR_PORT", 8800))
let MAX_UPSTREAM_MB = envInt("MODERNMIRROR_MAX_MB", 2048)
let MAX_UPLOAD_MB = envInt("MODERNMIRROR_MAX_UPLOAD_MB", 2048)
let RATE_LIMIT = envInt("MODERNMIRROR_RATE_LIMIT", 600)
let RATE_WINDOW: Int64 = 60
let AUDIT_LOG = joinPath(DATA_DIR, "audit.log")
let MASTER_KEY_PATH = joinPath(DATA_DIR, "master.key")
let SESSION_HOURS = envInt("MODERNMIRROR_SESSION_HOURS", 24)
let WEB_SESSION_MINUTES = envInt("MODERNMIRROR_WEB_SESSION_MINUTES", 30)

var DB_MASTER_KEY = ""
var MASTER_KEY_SOURCE = ""

func initConfig(): Unit {
    ensureDir(DATA_DIR)
    ensureDir(CACHE_DIR)
    ensureDir(PRIVATE_DIR)
    ensureDir(joinPath(DATA_DIR, "tmp"))

    let fromEnv = envOr("MODERNMIRROR_DB_MASTER_KEY", "").trimAscii()
    if (!fromEnv.isEmpty()) {
        DB_MASTER_KEY = fromEnv
        MASTER_KEY_SOURCE = "env"
        return
    }
    if (fileExists(MASTER_KEY_PATH)) {
        let content = String.fromUtf8(readAllBytes(MASTER_KEY_PATH)).trimAscii()
        if (!content.isEmpty()) {
            DB_MASTER_KEY = content
            MASTER_KEY_SOURCE = "file"
            return
        }
    }
    let key = randomHex(32)
    writeAllText(MASTER_KEY_PATH, key + "\n")
    unsafe {
        let cs = LibC.mallocCString(MASTER_KEY_PATH)
        chmod(cs, 0x180)
        LibC.free(cs)
    }
    DB_MASTER_KEY = key
    MASTER_KEY_SOURCE = "generated"
}
