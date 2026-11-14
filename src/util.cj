package modernmirror

import std.collection.*
import std.convert.*
import std.env.*
import std.fs.*
import std.io.*
import std.time.*
import stdx.encoding.json.*

let HEX_DIGITS = "0123456789abcdef".toArray()

func byteStr(b: Byte): String {
    let one = Array<Byte>(1, repeat: b)
    return String.fromUtf8(one)
}

func envOr(name: String, def: String): String {
    match (getVariable(name)) {
        case Some(v) => if (v.isEmpty()) { return def } else { return v }
        case None => return def
    }
}

func envInt(name: String, def: Int64): Int64 {
    match (getVariable(name)) {
        case Some(v) =>
            match (Int64.tryParse(v.trimAscii())) {
                case Some(n) => return n
                case None => return def
            }
        case None => return def
    }
}

func hexEncode(data: Array<Byte>): String {
    let sb = StringBuilder()
    for (b in data) {
        sb.append(byteStr(HEX_DIGITS[Int64(b >> 4)]))
        sb.append(byteStr(HEX_DIGITS[Int64(b & 0x0F)]))
    }
    return sb.toString()
}

func hexEncodeLower(s: String): String {
    return hexEncode(s.toArray())
}

func hexVal(c: UInt8): Int64 {
    if (c >= 48 && c <= 57) {
        return Int64(c - 48)
    }
    if (c >= 97 && c <= 102) {
        return Int64(c - 87)
    }
    if (c >= 65 && c <= 70) {
        return Int64(c - 55)
    }
    return -1
}

func hexDecode(text: String): Array<Byte> {
    let src = text.toArray()
    var usable = src.size
    if (usable % 2 == 1) {
        usable = usable - 1
    }
    let out = Array<Byte>(usable / 2, repeat: 0)
    var i: Int64 = 0
    while (i < usable) {
        let hi = hexVal(src[i])
        let lo = hexVal(src[i + 1])
        if (hi < 0 || lo < 0) {
            throw Exception("invalid hex string")
        }
        out[i / 2] = UInt8(hi * 16 + lo)
        i = i + 2
    }
    return out
}

let B64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".toArray()
let B64_URL_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".toArray()

func b64EncodeBytes(data: Array<Byte>, alphabet: Array<Byte>, pad: Bool): String {
    let sb = StringBuilder()
    var i: Int64 = 0
    while (i + 3 <= data.size) {
        let n = Int64(data[i]) * 65536 + Int64(data[i + 1]) * 256 + Int64(data[i + 2])
        sb.append(byteStr(alphabet[(n >> 18) & 63]))
        sb.append(byteStr(alphabet[(n >> 12) & 63]))
        sb.append(byteStr(alphabet[(n >> 6) & 63]))
        sb.append(byteStr(alphabet[n & 63]))
        i = i + 3
    }
    let rest = data.size - i
    if (rest == 1) {
        let n = Int64(data[i]) * 65536
        sb.append(byteStr(alphabet[(n >> 18) & 63]))
        sb.append(byteStr(alphabet[(n >> 12) & 63]))
        if (pad) {
            sb.append("==")
        }
    } else if (rest == 2) {
        let n = Int64(data[i]) * 65536 + Int64(data[i + 1]) * 256
        sb.append(byteStr(alphabet[(n >> 18) & 63]))
        sb.append(byteStr(alphabet[(n >> 12) & 63]))
        sb.append(byteStr(alphabet[(n >> 6) & 63]))
        if (pad) {
            sb.append("=")
        }
    }
    return sb.toString()
}

func b64Encode(data: Array<Byte>): String {
    return b64EncodeBytes(data, B64_ALPHABET, true)
}

func b64UrlEncode(data: Array<Byte>): String {
    return b64EncodeBytes(data, B64_URL_ALPHABET, false)
}

func b64Value(c: UInt8): Int64 {
    if (c >= 65 && c <= 90) {
        return Int64(c - 65)
    }
    if (c >= 97 && c <= 122) {
        return Int64(c - 97 + 26)
    }
    if (c >= 48 && c <= 57) {
        return Int64(c - 48 + 52)
    }
    if (c == 43 || c == 45) {
        return 62
    }
    if (c == 47 || c == 95) {
        return 63
    }
    return -1
}

func b64Decode(text: String): Array<Byte> {
    let src = text.trimAscii().toArray()
    let acc = ArrayList<Byte>()
    var buf: Int64 = 0
    var bits: Int64 = 0
    for (c in src) {
        if (c == 61) {
            break
        }
        let v = b64Value(c)
        if (v < 0) {
            continue
        }
        buf = (buf << 6) | v
        bits = bits + 6
        if (bits >= 8) {
            bits = bits - 8
            acc.add(UInt8((buf >> bits) & 0xFF))
        }
    }
    return acc.toArray()
}

func bytesConcat(a: Array<Byte>, b: Array<Byte>): Array<Byte> {
    let out = Array<Byte>(a.size + b.size, repeat: 0)
    if (a.size > 0) {
        a.copyTo(out, 0, 0, a.size)
    }
    if (b.size > 0) {
        b.copyTo(out, 0, a.size, b.size)
    }
    return out
}

func bytesConcat3(a: Array<Byte>, b: Array<Byte>, c: Array<Byte>): Array<Byte> {
    return bytesConcat(bytesConcat(a, b), c)
}

func constantTimeEq(a: Array<Byte>, b: Array<Byte>): Bool {
    if (a.size != b.size) {
        return false
    }
    var diff: UInt8 = 0
    for (i in 0..a.size) {
        diff = diff | (a[i] ^ b[i])
    }
    return diff == 0
}

func constantTimeEqStr(a: String, b: String): Bool {
    let ab = a.toArray()
    let bb = b.toArray()
    return constantTimeEq(ab, bb)
}

func repeatStr(text: String, times: Int64): String {
    let sb = StringBuilder()
    var i: Int64 = 0
    while (i < times) {
        sb.append(text)
        i = i + 1
    }
    return sb.toString()
}

func b32Encode(data: Array<Byte>): String {
    let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".toArray()
    let sb = StringBuilder()
    var buf: Int64 = 0
    var bits: Int64 = 0
    for (b in data) {
        buf = (buf << 8) | Int64(b)
        bits = bits + 8
        while (bits >= 5) {
            bits = bits - 5
            sb.append(byteStr(alphabet[(buf >> bits) & 31]))
        }
    }
    if (bits > 0) {
        sb.append(byteStr(alphabet[(buf << (5 - bits)) & 31]))
    }
    return sb.toString()
}

func b32Decode(text: String): Array<Byte> {
    let acc = ArrayList<Byte>()
    var buf: Int64 = 0
    var bits: Int64 = 0
    for (c in text.toAsciiUpper().toArray()) {
        var v: Int64 = -1
        if (c >= 65 && c <= 90) {
            v = Int64(c - 65)
        } else if (c >= 50 && c <= 55) {
            v = Int64(c - 50 + 26)
        }
        if (v < 0) {
            continue
        }
        buf = (buf << 5) | v
        bits = bits + 5
        if (bits >= 8) {
            bits = bits - 8
            acc.add(UInt8((buf >> bits) & 0xFF))
        }
    }
    return acc.toArray()
}

func joinPath(a: String, b: String): String {
    if (a.isEmpty()) {
        return b
    }
    if (a.endsWith("/")) {
        return a + b
    }
    return a + "/" + b
}

func ensureDir(path: String): Unit {
    if (path.isEmpty()) {
        return
    }
    if (!exists(path)) {
        Directory.create(path, recursive: true)
    }
}

func fileExists(path: String): Bool {
    if (path.isEmpty()) {
        return false
    }
    return exists(path)
}

func readAllBytes(path: String): Array<Byte> {
    return File.readFrom(path)
}

func writeAllBytes(path: String, data: Array<Byte>): Unit {
    let f = File.create(path)
    try {
        if (data.size > 0) {
            f.write(data)
        }
    } finally {
        f.close()
    }
}

func writeAllText(path: String, text: String): Unit {
    writeAllBytes(path, text.toArray())
}

func appendBytes(path: String, data: Array<Byte>): Unit {
    File.appendTo(path, data)
}

func appendText(path: String, text: String): Unit {
    File.appendTo(path, text.toArray())
}

func deleteFileIfExists(path: String): Unit {
    try {
        if (fileExists(path)) {
            remove(path)
        }
    } catch (e: Exception) {
        ()
    }
}

func moveFile(from: String, to: String): Unit {
    rename(Path(from), to: Path(to), overwrite: true)
}

func fileSize(path: String): Int64 {
    return FileInfo(path).size
}

func listEntries(path: String): Array<FileInfo> {
    if (!exists(path)) {
        return Array<FileInfo>()
    }
    return Directory.readFrom(path)
}

func dirSize(path: String): Int64 {
    var total: Int64 = 0
    if (!exists(path)) {
        return 0
    }
    let stack = ArrayList<String>()
    stack.add(path)
    while (stack.size > 0) {
        let cur = stack[stack.size - 1]
        stack.remove(at: stack.size - 1)
        for (info in listEntries(cur)) {
            if (info.isDirectory()) {
                stack.add(info.path.toString())
            } else {
                total = total + info.size
            }
        }
    }
    return total
}

func nowIsoLocal(): String {
    let t = DateTime.now().format("yyyy-MM-dd HH:mm:ss")
    return t.replace(" ", "T")
}

func unixSeconds(): Int64 {
    return DateTime.now().toUnixTimeStamp().toSeconds()
}

func unixSecondsFloat(): Float64 {
    let dur = DateTime.now().toUnixTimeStamp()
    let sec = dur.toSeconds()
    let nanos = (dur - Duration.second * sec).toNanoseconds()
    return Float64(sec) + Float64(nanos) / 1000000000.0
}

func sleepMillis(ms: Int64): Unit {
    sleep(Duration.millisecond * ms)
}

func htmlEscape(text: String): String {
    var out = text.replace("&", "&amp;")
    out = out.replace("<", "&lt;")
    out = out.replace(">", "&gt;")
    out = out.replace("\"", "&quot;")
    out = out.replace("'", "&#39;")
    return out
}

func baseName(path: String): String {
    let idx = path.lastIndexOf("/")
    match (idx) {
        case Some(i) => return path[i + 1..]
        case None => return path
    }
}

func extName(path: String): String {
    let name = baseName(path)
    let idx = name.lastIndexOf(".")
    match (idx) {
        case Some(i) => return name[i + 1..].toAsciiLower()
        case None => return ""
    }
}

func jsonGetString(o: JsonObject, key: String, def!: String = ""): String {
    match (o.get(key)) {
        case Some(v) =>
            match (v.kind()) {
                case JsonKind.JsString => return v.asString().getValue()
                case JsonKind.JsInt => return v.asInt().getValue().toString()
                case JsonKind.JsFloat => return v.asFloat().getValue().toString()
                case JsonKind.JsBool => return v.asBool().getValue().toString()
                case _ => return def
            }
        case None => return def
    }
}

func jsonGetInt(o: JsonObject, key: String, def!: Int64 = 0): Int64 {
    match (o.get(key)) {
        case Some(v) =>
            match (v.kind()) {
                case JsonKind.JsInt => return v.asInt().getValue()
                case JsonKind.JsFloat => return Int64(v.asFloat().getValue())
                case JsonKind.JsString =>
                    match (Int64.tryParse(v.asString().getValue().trimAscii())) {
                        case Some(n) => return n
                        case None => return def
                    }
                case _ => return def
            }
        case None => return def
    }
}

func jsonGetBool(o: JsonObject, key: String, def!: Bool = false): Bool {
    match (o.get(key)) {
        case Some(v) =>
            match (v.kind()) {
                case JsonKind.JsBool => return v.asBool().getValue()
                case JsonKind.JsInt => return v.asInt().getValue() != 0
                case JsonKind.JsString =>
                    let s = v.asString().getValue().toAsciiLower()
                    return s == "1" || s == "true" || s == "yes" || s == "on"
                case _ => return def
            }
        case None => return def
    }
}

func jsonParseObject(text: String): Option<JsonObject> {
    try {
        let v = JsonValue.fromStr(text)
        match (v.kind()) {
            case JsonKind.JsObject => return Some(v.asObject())
            case _ => return None
        }
    } catch (e: Exception) {
        return None
    }
}

func jsonStringArray(items: Array<String>): JsonArray {
    let arr = JsonArray()
    for (item in items) {
        arr.add(JsonString(item))
    }
    return arr
}

class HttpError <: Exception {
    let status: UInt16
    let detail: String

    init(status: UInt16, detail: String) {
        super(detail)
        this.status = status
        this.detail = detail
    }
}

class LimitedInputStream <: InputStream {
    var inner: InputStream
    var remaining: Int64

    init(inner: InputStream, limit: Int64) {
        this.inner = inner
        this.remaining = limit
    }

    public func read(buffer: Array<UInt8>): Int64 {
        if (remaining <= 0) {
            return 0
        }
        if (Int64(buffer.size) <= remaining) {
            let got = inner.read(buffer)
            if (got > 0) {
                remaining = remaining - got
            }
            return got
        }
        let tmp = Array<UInt8>(remaining, repeat: 0)
        let got = inner.read(tmp)
        if (got > 0) {
            tmp.copyTo(buffer, 0, 0, got)
            remaining = remaining - got
        }
        return got
    }
}

func readAllStreaming(input: InputStream, limit: Int64): Array<Byte> {
    let acc = ArrayList<Byte>()
    let buf = Array<Byte>(65536, repeat: 0)
    while (true) {
        let n = input.read(buf)
        if (n <= 0) {
            break
        }
        if (acc.size + n > limit) {
            throw HttpError(413, "请求内容超过上限")
        }
        for (i in 0..n) {
            acc.add(buf[i])
        }
    }
    return acc.toArray()
}

func jStr(value: String): JsonValue {
    return JsonString(value)
}

func jInt(value: Int64): JsonValue {
    return JsonInt(value)
}

func jBool(value: Bool): JsonValue {
    return JsonBool(value)
}

func jNull(): JsonValue {
    return JsonNull()
}

func jArrOfStrings(items: Array<String>): JsonArray {
    return jsonStringArray(items)
}

func jArrOfObjects(items: Array<JsonObject>): JsonArray {
    let arr = JsonArray()
    for (item in items) {
        arr.add(item)
    }
    return arr
}

func jObj(): JsonObject {
    return JsonObject()
}

func jsonOptString(obj: JsonObject, key: String, def!: String = ""): String {
    return jsonGetString(obj, key, def: def)
}

func jsonStringList(obj: JsonObject, key: String): ArrayList<String> {
    let out = ArrayList<String>()
    match (obj.get(key)) {
        case Some(v) =>
            match (v.kind()) {
                case JsonKind.JsArray =>
                    for (item in v.asArray().getItems()) {
                        match (item.kind()) {
                            case JsonKind.JsString => out.add(item.asString().getValue().trimAscii())
                            case JsonKind.JsInt => out.add(item.asInt().getValue().toString())
                            case JsonKind.JsFloat => out.add(item.asFloat().getValue().toString())
                            case _ => ()
                        }
                    }
                case JsonKind.JsString => out.add(v.asString().getValue().trimAscii())
                case _ => ()
            }
        case None => ()
    }
    return out
}

func jsonParseValue(text: String): Option<JsonValue> {
    try {
        return Some(JsonValue.fromStr(text))
    } catch (e: Exception) {
        return None
    }
}

func jsonHasKey(obj: JsonObject, key: String): Bool {
    return obj.containsKey(key)
}

func isBlankChar(c: Byte): Bool {
    return c == 32 || c == 9 || c == 10 || c == 13
}

func containsWhitespace(text: String): Bool {
    for (c in text.toArray()) {
        if (isBlankChar(c)) {
            return true
        }
    }
    return false
}

func jsonEscapeText(text: String): String {
    let sb = StringBuilder()
    let plain = ArrayList<Byte>()
    func flushPlain(): Unit {
        if (plain.size > 0) {
            sb.append(String.fromUtf8(plain.toArray()))
            plain.clear()
        }
    }
    sb.append("\"")
    for (b in text.toArray()) {
        if (b == 34) {
            flushPlain()
            sb.append("\\\"")
        } else if (b == 92) {
            flushPlain()
            sb.append("\\\\")
        } else if (b == 10) {
            flushPlain()
            sb.append("\\n")
        } else if (b == 13) {
            flushPlain()
            sb.append("\\r")
        } else if (b == 9) {
            flushPlain()
            sb.append("\\t")
        } else if (b < 32) {
            flushPlain()
            sb.append("\\u00")
            sb.append(byteStr(HEX_DIGITS[Int64(b >> 4)]))
            sb.append(byteStr(HEX_DIGITS[Int64(b & 15)]))
        } else {
            plain.add(b)
        }
    }
    flushPlain()
    sb.append("\"")
    return sb.toString()
}

func compactJson(value: JsonValue): String {
    return match (value.kind()) {
        case JsonKind.JsNull => "null"
        case JsonKind.JsBool => if (value.asBool().getValue()) { "true" } else { "false" }
        case JsonKind.JsInt => value.asInt().getValue().toString()
        case JsonKind.JsFloat => value.asFloat().getValue().toString()
        case JsonKind.JsString => jsonEscapeText(value.asString().getValue())
        case JsonKind.JsArray =>
            let sb = StringBuilder()
            sb.append("[")
            var first = true
            for (item in value.asArray().getItems()) {
                if (!first) {
                    sb.append(",")
                }
                first = false
                sb.append(compactJson(item))
            }
            sb.append("]")
            sb.toString()
        case JsonKind.JsObject =>
            let sb = StringBuilder()
            sb.append("{")
            var first = true
            for ((key, item) in value.asObject().getFields()) {
                if (!first) {
                    sb.append(",")
                }
                first = false
                sb.append(jsonEscapeText(key))
                sb.append(":")
                sb.append(compactJson(item))
            }
            sb.append("}")
            sb.toString()
    }
}
