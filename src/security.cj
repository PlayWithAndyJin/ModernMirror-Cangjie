package modernmirror

import std.collection.*
import std.sync.*
import stdx.encoding.json.*

let RATE_BUCKETS = HashMap<String, ArrayList<Float64>>()
let RATE_LOCK = Mutex()
var RATE_LAST_CLEANUP = 0.0

func audit(event: String, clientIp: String, detail: JsonObject): Unit {
    let obj = JsonObject()
    obj.put("ts", JsonString(nowIsoLocal()))
    obj.put("event", JsonString(event))
    obj.put("ip", JsonString(clientIp))
    for ((key, value) in detail.getFields()) {
        obj.put(key, value)
    }
    let line = compactJson(obj)
    let encrypted = encryptText(line)
    var mode = "plain"
    if (encrypted.startsWith(SM_PREFIX)) {
        mode = "sm"
    } else if (encrypted.startsWith(LEGACY_PREFIX)) {
        mode = "enc"
    }
    ensureDir(DATA_DIR)
    appendText(AUDIT_LOG, mode + "|" + encrypted + "\n")
}

func auditEvent(event: String, clientIp: String): Unit {
    audit(event, clientIp, JsonObject())
}

func rateLimitCheck(key: String): Bool {
    let now = unixSecondsFloat()
    synchronized(RATE_LOCK) {
        if (now - RATE_LAST_CLEANUP > 120.0) {
            let stale = ArrayList<String>()
            for ((k, list) in RATE_BUCKETS) {
                if (list.size == 0 || now - list[0] >= Float64(RATE_WINDOW) * 4.0) {
                    stale.add(k)
                }
            }
            for (k in stale) {
                RATE_BUCKETS.remove(k)
            }
            RATE_LAST_CLEANUP = now
        }
        let list = match (RATE_BUCKETS.get(key)) {
            case Some(v) => v
            case None =>
                let fresh = ArrayList<Float64>()
                RATE_BUCKETS.add(key, fresh)
                fresh
        }
        while (list.size > 0 && now - list[0] > Float64(RATE_WINDOW)) {
            list.remove(at: 0)
        }
        list.add(now)
        return list.size <= RATE_LIMIT
    }
}

func resetRateBuckets(): Unit {
    synchronized(RATE_LOCK) {
        RATE_BUCKETS.clear()
    }
}
