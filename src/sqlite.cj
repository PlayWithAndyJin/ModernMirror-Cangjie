package modernmirror

import std.collection.*
import std.sync.*
import std.convert.*
import stdx.encoding.json.*

foreign {
    func sqlite3_open(filename: CString, ppDb: CPointer<CPointer<Unit>>): Int32
    func sqlite3_close_v2(db: CPointer<Unit>): Int32
    func sqlite3_errmsg(db: CPointer<Unit>): CString
    func sqlite3_exec(db: CPointer<Unit>, sql: CString, callback: CPointer<Unit>, arg: CPointer<Unit>, errmsg: CPointer<CString>): Int32
    func sqlite3_free(p: CPointer<Unit>): Unit
    func sqlite3_prepare_v2(db: CPointer<Unit>, sql: CString, nByte: Int32, stmt: CPointer<CPointer<Unit>>, tail: CPointer<CString>): Int32
    func sqlite3_step(stmt: CPointer<Unit>): Int32
    func sqlite3_finalize(stmt: CPointer<Unit>): Int32
    func sqlite3_bind_int64(stmt: CPointer<Unit>, idx: Int32, value: Int64): Int32
    func sqlite3_bind_double(stmt: CPointer<Unit>, idx: Int32, value: Float64): Int32
    func sqlite3_bind_text(stmt: CPointer<Unit>, idx: Int32, text: CString, n: Int32, destructor: CPointer<Unit>): Int32
    func sqlite3_bind_blob(stmt: CPointer<Unit>, idx: Int32, data: CPointer<Unit>, n: Int32, destructor: CPointer<Unit>): Int32
    func sqlite3_bind_null(stmt: CPointer<Unit>, idx: Int32): Int32
    func sqlite3_column_count(stmt: CPointer<Unit>): Int32
    func sqlite3_column_name(stmt: CPointer<Unit>, i: Int32): CPointer<UInt8>
    func sqlite3_column_text(stmt: CPointer<Unit>, i: Int32): CPointer<UInt8>
    func sqlite3_column_blob(stmt: CPointer<Unit>, i: Int32): CPointer<UInt8>
    func sqlite3_column_bytes(stmt: CPointer<Unit>, i: Int32): Int32
    func sqlite3_column_type(stmt: CPointer<Unit>, i: Int32): Int32
    func sqlite3_column_int64(stmt: CPointer<Unit>, i: Int32): Int64
    func sqlite3_column_double(stmt: CPointer<Unit>, i: Int32): Float64
    func sqlite3_last_insert_rowid(db: CPointer<Unit>): Int64
    func sqlite3_changes(db: CPointer<Unit>): Int32
}

let SQLITE_ROW: Int32 = 100
let SQLITE_DONE: Int32 = 101

enum DbValue {
    | DbNull
    | DbInt(Int64)
    | DbReal(Float64)
    | DbText(String)
    | DbBlob(Array<Byte>)
}

type DbRow = HashMap<String, DbValue>

class Db {
    let handle: CPointer<Unit>
    let lock: Mutex = Mutex()

    init(path: String) {
        var h: CPointer<Unit> = CPointer<Unit>()
        unsafe {
            let cs = LibC.mallocCString(path)
            let rc = sqlite3_open(cs, inout h)
            LibC.free(cs)
            if (rc != 0) {
                throw Exception("cannot open database " + path)
            }
        }
        handle = h
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA busy_timeout=30000")
    }

    func errorText(): String {
        unsafe {
            return sqlite3_errmsg(handle).toString()
        }
    }

    func exec(sql: String): Unit {
        synchronized(lock) {
            unsafe {
                let cs = LibC.mallocCString(sql)
                let rc = sqlite3_exec(handle, cs, CPointer<Unit>(), CPointer<Unit>(), CPointer<CString>())
                LibC.free(cs)
                if (rc != 0) {
                    throw Exception("sqlite error: " + errorText())
                }
            }
        }
    }

    func prepare(sql: String, params: Array<DbValue>): (CPointer<Unit>, ArrayList<CString>, ArrayList<Array<Byte>>) {
        var stmt: CPointer<Unit> = CPointer<Unit>()
        let keepText = ArrayList<CString>()
        let keepBlob = ArrayList<Array<Byte>>()
        unsafe {
            let cs = LibC.mallocCString(sql)
            let rc = sqlite3_prepare_v2(handle, cs, -1, inout stmt, CPointer<CString>())
            LibC.free(cs)
            if (rc != 0) {
                throw Exception("sqlite prepare error: " + errorText())
            }
            for (i in 0..params.size) {
                let idx = Int32(i + 1)
                match (params[i]) {
                    case DbNull => sqlite3_bind_null(stmt, idx)
                    case DbInt(v) => sqlite3_bind_int64(stmt, idx, v)
                    case DbReal(v) => sqlite3_bind_double(stmt, idx, v)
                    case DbText(v) =>
                        let cs2 = LibC.mallocCString(v)
                        keepText.add(cs2)
                        sqlite3_bind_text(stmt, idx, cs2, -1, CPointer<Unit>())
                    case DbBlob(v) =>
                        keepBlob.add(v)
                        let h = acquireArrayRawData(v)
                        try {
                            sqlite3_bind_blob(stmt, idx, CPointer<Unit>(h.pointer), Int32(v.size), CPointer<Unit>())
                        } finally {
                            releaseArrayRawData(h)
                        }
                }
            }
        }
        return (stmt, keepText, keepBlob)
    }

    func releasePrepared(stmt: CPointer<Unit>, keepText: ArrayList<CString>): Unit {
        unsafe {
            sqlite3_finalize(stmt)
            for (cs in keepText) {
                LibC.free(cs)
            }
        }
    }

    func execParams(sql: String, params: Array<DbValue>): Int64 {
        var affected: Int64 = 0
        synchronized(lock) {
            let (stmt, keepText, _) = prepare(sql, params)
            try {
                unsafe {
                    let rc = sqlite3_step(stmt)
                    if (rc != SQLITE_DONE && rc != SQLITE_ROW) {
                        throw Exception("sqlite step error: " + errorText())
                    }
                    affected = Int64(sqlite3_changes(handle))
                }
            } finally {
                releasePrepared(stmt, keepText)
            }
        }
        return affected
    }

    func query(sql: String, params: Array<DbValue>): ArrayList<DbRow> {
        let rows = ArrayList<DbRow>()
        synchronized(lock) {
            let (stmt, keepText, _) = prepare(sql, params)
            try {
                unsafe {
                    while (true) {
                        let rc = sqlite3_step(stmt)
                        if (rc == SQLITE_DONE) {
                            break
                        }
                        if (rc != SQLITE_ROW) {
                            throw Exception("sqlite step error: " + errorText())
                        }
                        let row = DbRow()
                        let count = sqlite3_column_count(stmt)
                        for (i in 0..count) {
                            let name = CString(sqlite3_column_name(stmt, Int32(i))).toString()
                            let kind = sqlite3_column_type(stmt, Int32(i))
                            if (kind == 5) {
                                row.add(name, DbNull)
                            } else if (kind == 1) {
                                row.add(name, DbInt(sqlite3_column_int64(stmt, Int32(i))))
                            } else if (kind == 2) {
                                row.add(name, DbReal(sqlite3_column_double(stmt, Int32(i))))
                            } else if (kind == 4) {
                                let n = sqlite3_column_bytes(stmt, Int32(i))
                                let p = sqlite3_column_blob(stmt, Int32(i))
                                let data = Array<Byte>(Int64(n), repeat: 0)
                                for (j in 0..Int64(n)) {
                                    data[j] = p.read(j)
                                }
                                row.add(name, DbBlob(data))
                            } else {
                                let n = sqlite3_column_bytes(stmt, Int32(i))
                                let p = sqlite3_column_text(stmt, Int32(i))
                                let data = Array<Byte>(Int64(n), repeat: 0)
                                for (j in 0..Int64(n)) {
                                    data[j] = p.read(j)
                                }
                                row.add(name, DbText(String.fromUtf8(data)))
                            }
                        }
                        rows.add(row)
                    }
                }
            } finally {
                releasePrepared(stmt, keepText)
            }
        }
        return rows
    }

    func queryOne(sql: String, params: Array<DbValue>): ?DbRow {
        let rows = query(sql, params)
        if (rows.size == 0) {
            return None
        }
        return Some(rows[0])
    }

    func lastInsertId(): Int64 {
        var v: Int64 = 0
        synchronized(lock) {
            unsafe {
                v = sqlite3_last_insert_rowid(handle)
            }
        }
        return v
    }

    func close(): Unit {
        synchronized(lock) {
            unsafe {
                sqlite3_close_v2(handle)
            }
        }
    }
}

func vText(row: DbRow, key: String): String {
    match (row.get(key)) {
        case Some(v) =>
            match (v) {
                case DbText(s) => return s
                case DbInt(n) => return n.toString()
                case DbReal(f) => return f.toString()
                case DbBlob(b) => return String.fromUtf8(b)
                case DbNull => return ""
            }
        case None => return ""
    }
}

func vInt(row: DbRow, key: String): Int64 {
    match (row.get(key)) {
        case Some(v) =>
            match (v) {
                case DbInt(n) => return n
                case DbReal(f) => return Int64(f)
                case DbText(s) =>
                    match (Int64.tryParse(s.trimAscii())) {
                        case Some(n) => return n
                        case None => return 0
                    }
                case _ => return 0
            }
        case None => return 0
    }
}

func vBool(row: DbRow, key: String): Bool {
    return vInt(row, key) != 0
}

func vNull(row: DbRow, key: String): Bool {
    match (row.get(key)) {
        case Some(v) =>
            match (v) {
                case DbNull => return true
                case DbText(s) => return s.isEmpty()
                case _ => return false
            }
        case None => return true
    }
}

func dbValueToJson(v: DbValue): JsonValue {
    match (v) {
        case DbNull => return JsonNull()
        case DbInt(n) => return JsonInt(n)
        case DbReal(f) => return JsonFloat(f)
        case DbText(s) => return JsonString(s)
        case DbBlob(b) => return JsonString(b64Encode(b))
    }
}

func rowToJson(row: DbRow): JsonObject {
    let obj = JsonObject()
    for ((key, value) in row) {
        obj.put(key, dbValueToJson(value))
    }
    return obj
}
