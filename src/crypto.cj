package modernmirror

import std.collection.*
import std.convert.*
import std.fs.*
import std.random.*
import std.sync.*
import stdx.crypto.digest.*
import stdx.crypto.crypto.*

foreign {
    func CRYPT_EAL_Init(opts: Int32): Int32
    func CRYPT_EAL_Cleanup(opts: Int32): Unit
    func CRYPT_EAL_ProviderCipherNewCtx(libCtx: CPointer<Unit>, algId: Int32, attrName: CString): CPointer<Unit>
    func CRYPT_EAL_CipherFreeCtx(ctx: CPointer<Unit>): Unit
    func CRYPT_EAL_CipherInit(ctx: CPointer<Unit>, key: CPointer<UInt8>, keyLen: UInt32, iv: CPointer<UInt8>, ivLen: UInt32, enc: Bool): Int32
    func CRYPT_EAL_CipherSetPadding(ctx: CPointer<Unit>, paddingType: Int32): Int32
    func CRYPT_EAL_CipherUpdate(ctx: CPointer<Unit>, input: CPointer<UInt8>, inLen: UInt32, output: CPointer<UInt8>, outLen: CPointer<UInt32>): Int32
    func CRYPT_EAL_CipherFinal(ctx: CPointer<Unit>, output: CPointer<UInt8>, outLen: CPointer<UInt32>): Int32
    func CRYPT_EAL_ProviderMdNewCtx(libCtx: CPointer<Unit>, algId: Int32, attrName: CString): CPointer<Unit>
    func CRYPT_EAL_MdFreeCtx(ctx: CPointer<Unit>): Unit
    func CRYPT_EAL_MdInit(ctx: CPointer<Unit>): Int32
    func CRYPT_EAL_MdUpdate(ctx: CPointer<Unit>, data: CPointer<UInt8>, len: UInt32): Int32
    func CRYPT_EAL_MdFinal(ctx: CPointer<Unit>, out: CPointer<UInt8>, len: CPointer<UInt32>): Int32
    func CRYPT_EAL_ProviderMacNewCtx(libCtx: CPointer<Unit>, algId: Int32, attrName: CString): CPointer<Unit>
    func CRYPT_EAL_MacFreeCtx(ctx: CPointer<Unit>): Unit
    func CRYPT_EAL_MacInit(ctx: CPointer<Unit>, key: CPointer<UInt8>, len: UInt32): Int32
    func CRYPT_EAL_MacUpdate(ctx: CPointer<Unit>, data: CPointer<UInt8>, len: UInt32): Int32
    func CRYPT_EAL_MacFinal(ctx: CPointer<Unit>, out: CPointer<UInt8>, len: CPointer<UInt32>): Int32
    func CRYPT_EAL_Randbytes(out: CPointer<UInt8>, len: UInt32): Int32
    func chmod(path: CString, mode: UInt32): Int32
}

let HITLS_INIT_ALL: Int32 = 0x3F
let HITLS_SM4_CBC: Int32 = 344
let HITLS_AES128_CBC: Int32 = 19
let HITLS_HMAC_SM3: Int32 = 291
let HITLS_HMAC_SHA256: Int32 = 49
let HITLS_HMAC_SHA1: Int32 = 47
let HITLS_MD_SM3: Int32 = 290
let HITLS_MD_SHA256: Int32 = 43
let HITLS_MD_SHA1: Int32 = 41
let HITLS_MD_SHA512: Int32 = 45
let HITLS_MD_MD5: Int32 = 40
let HITLS_PAD_PKCS7: Int32 = 5

let SM_PREFIX = "enc:sm4:v1:"
let LEGACY_PREFIX = "enc:v1:"
let SM3_PASSWORD_ITER: Int64 = 200000
let LEGACY_PASSWORD_ITER: Int64 = 200000
let HMAC_ENC_LABEL = "modernmirror|sm4-enc"
let HMAC_MAC_LABEL = "modernmirror|sm4-mac"

var HITLS_READY = false

func cryptoInit(): Bool {
    unsafe {
        HITLS_READY = CRYPT_EAL_Init(HITLS_INIT_ALL) == 0
    }
    return HITLS_READY
}

func cryptoCleanup(): Unit {
    if (HITLS_READY) {
        unsafe {
            CRYPT_EAL_Cleanup(HITLS_INIT_ALL)
        }
        HITLS_READY = false
    }
}

func randomBytes(n: Int64): Array<Byte> {
    let out = Array<Byte>(n, repeat: 0)
    if (HITLS_READY) {
        unsafe {
            let h = acquireArrayRawData(out)
            try {
                CRYPT_EAL_Randbytes(h.pointer, UInt32(n))
            } finally {
                releaseArrayRawData(h)
            }
        }
        return out
    }
    let rng = Random()
    for (i in 0..n) {
        out[i] = UInt8(rng.nextInt64(256))
    }
    return out
}

func randomHex(n: Int64): String {
    return hexEncode(randomBytes(n))
}

func tokenUrlSafe(n: Int64): String {
    return b64UrlEncode(randomBytes(n))
}

func hitlsDigest(alg: Int32, data: Array<Byte>): Array<Byte> {
    unsafe {
        let ctx = CRYPT_EAL_ProviderMdNewCtx(CPointer<Unit>(), alg, CString(CPointer<UInt8>()))
        if (ctx.isNull()) {
            throw Exception("digest context init failed")
        }
        let out = Array<Byte>(64, repeat: 0)
        let lenArr = Array<UInt32>(1, repeat: 64)
        let inH = acquireArrayRawData(data)
        let outH = acquireArrayRawData(out)
        let lenH = acquireArrayRawData(lenArr)
        try {
            let r1 = CRYPT_EAL_MdInit(ctx)
            let r2 = CRYPT_EAL_MdUpdate(ctx, inH.pointer, UInt32(data.size))
            let r3 = CRYPT_EAL_MdFinal(ctx, outH.pointer, lenH.pointer)
            if (r1 != 0 || r2 != 0 || r3 != 0) {
                throw Exception("digest failed")
            }
            return out[0..Int64(lenH.pointer.read(0))]
        } finally {
            releaseArrayRawData(inH)
            releaseArrayRawData(outH)
            releaseArrayRawData(lenH)
            CRYPT_EAL_MdFreeCtx(ctx)
        }
    }
}

func hitlsHmac(alg: Int32, key: Array<Byte>, data: Array<Byte>): Array<Byte> {
    unsafe {
        let ctx = CRYPT_EAL_ProviderMacNewCtx(CPointer<Unit>(), alg, CString(CPointer<UInt8>()))
        if (ctx.isNull()) {
            throw Exception("mac context init failed")
        }
        let out = Array<Byte>(64, repeat: 0)
        let lenArr = Array<UInt32>(1, repeat: 64)
        let keyH = acquireArrayRawData(key)
        let inH = acquireArrayRawData(data)
        let outH = acquireArrayRawData(out)
        let lenH = acquireArrayRawData(lenArr)
        try {
            let r1 = CRYPT_EAL_MacInit(ctx, keyH.pointer, UInt32(key.size))
            let r2 = CRYPT_EAL_MacUpdate(ctx, inH.pointer, UInt32(data.size))
            let r3 = CRYPT_EAL_MacFinal(ctx, outH.pointer, lenH.pointer)
            if (r1 != 0 || r2 != 0 || r3 != 0) {
                throw Exception("mac failed")
            }
            return out[0..Int64(lenH.pointer.read(0))]
        } finally {
            releaseArrayRawData(keyH)
            releaseArrayRawData(inH)
            releaseArrayRawData(outH)
            releaseArrayRawData(lenH)
            CRYPT_EAL_MacFreeCtx(ctx)
        }
    }
}

func hitlsCipher(alg: Int32, key: Array<Byte>, iv: Array<Byte>, data: Array<Byte>, encrypt: Bool): Array<Byte> {
    unsafe {
        let ctx = CRYPT_EAL_ProviderCipherNewCtx(CPointer<Unit>(), alg, CString(CPointer<UInt8>()))
        if (ctx.isNull()) {
            throw Exception("cipher context init failed")
        }
        let out = Array<Byte>(data.size + 64, repeat: 0)
        let lenArr = Array<UInt32>(1, repeat: UInt32(out.size))
        let finalLenArr = Array<UInt32>(1, repeat: UInt32(out.size))
        let keyH = acquireArrayRawData(key)
        let ivH = acquireArrayRawData(iv)
        let inH = acquireArrayRawData(data)
        let outH = acquireArrayRawData(out)
        let lenH = acquireArrayRawData(lenArr)
        let finalLenH = acquireArrayRawData(finalLenArr)
        try {
            let r1 = CRYPT_EAL_CipherInit(ctx, keyH.pointer, UInt32(key.size), ivH.pointer, UInt32(iv.size), encrypt)
            let r2 = CRYPT_EAL_CipherSetPadding(ctx, HITLS_PAD_PKCS7)
            let r3 = CRYPT_EAL_CipherUpdate(ctx, inH.pointer, UInt32(data.size), outH.pointer, lenH.pointer)
            let updateLen = lenH.pointer.read(0)
            finalLenH.pointer.write(0, UInt32(out.size) - updateLen)
            let r4 = CRYPT_EAL_CipherFinal(ctx, outH.pointer + Int64(updateLen), finalLenH.pointer)
            if (r1 != 0 || r2 != 0 || r3 != 0 || r4 != 0) {
                throw Exception("cipher failed")
            }
            return out[0..Int64(updateLen + finalLenH.pointer.read(0))]
        } finally {
            releaseArrayRawData(keyH)
            releaseArrayRawData(ivH)
            releaseArrayRawData(inH)
            releaseArrayRawData(outH)
            releaseArrayRawData(lenH)
            releaseArrayRawData(finalLenH)
            CRYPT_EAL_CipherFreeCtx(ctx)
        }
    }
}

func sm3(data: Array<Byte>): Array<Byte> {
    if (HITLS_READY) {
        return hitlsDigest(HITLS_MD_SM3, data)
    }
    let h = SM3()
    h.write(data)
    return h.finish()
}

func sm3Hex(data: Array<Byte>): String {
    return hexEncode(sm3(data))
}

func sha256(data: Array<Byte>): Array<Byte> {
    if (HITLS_READY) {
        return hitlsDigest(HITLS_MD_SHA256, data)
    }
    let h = SHA256()
    h.write(data)
    return h.finish()
}

func sha256Hex(data: Array<Byte>): String {
    return hexEncode(sha256(data))
}

func sha1(data: Array<Byte>): Array<Byte> {
    if (HITLS_READY) {
        return hitlsDigest(HITLS_MD_SHA1, data)
    }
    let h = SHA1()
    h.write(data)
    return h.finish()
}

func sha512(data: Array<Byte>): Array<Byte> {
    if (HITLS_READY) {
        return hitlsDigest(HITLS_MD_SHA512, data)
    }
    let h = SHA512()
    h.write(data)
    return h.finish()
}

func md5(data: Array<Byte>): Array<Byte> {
    if (HITLS_READY) {
        return hitlsDigest(HITLS_MD_MD5, data)
    }
    let h = MD5()
    h.write(data)
    return h.finish()
}

func hmacSm3(key: Array<Byte>, data: Array<Byte>): Array<Byte> {
    if (HITLS_READY) {
        return hitlsHmac(HITLS_HMAC_SM3, key, data)
    }
    let m = HMAC(key, HashType.SM3)
    m.write(data)
    return m.finish()
}

func hmacSha256(key: Array<Byte>, data: Array<Byte>): Array<Byte> {
    if (HITLS_READY) {
        return hitlsHmac(HITLS_HMAC_SHA256, key, data)
    }
    let m = HMAC(key, HashType.SHA256)
    m.write(data)
    return m.finish()
}

func hmacSha1(key: Array<Byte>, data: Array<Byte>): Array<Byte> {
    if (HITLS_READY) {
        return hitlsHmac(HITLS_HMAC_SHA1, key, data)
    }
    let m = HMAC(key, HashType.SHA1)
    m.write(data)
    return m.finish()
}

func sm4CbcEncrypt(key: Array<Byte>, iv: Array<Byte>, data: Array<Byte>): Array<Byte> {
    if (HITLS_READY) {
        return hitlsCipher(HITLS_SM4_CBC, key, iv, data, true)
    }
    let c = SM4(OperationMode.CBC, key, iv: iv, paddingMode: PaddingMode.PKCS7Padding)
    return c.encrypt(data)
}

func sm4CbcDecrypt(key: Array<Byte>, iv: Array<Byte>, data: Array<Byte>): Array<Byte> {
    if (HITLS_READY) {
        return hitlsCipher(HITLS_SM4_CBC, key, iv, data, false)
    }
    let c = SM4(OperationMode.CBC, key, iv: iv, paddingMode: PaddingMode.PKCS7Padding)
    return c.decrypt(data)
}

func aes128CbcEncrypt(key: Array<Byte>, iv: Array<Byte>, data: Array<Byte>): Array<Byte> {
    if (!HITLS_READY) {
        throw Exception("aes requires openHiTLS backend")
    }
    return hitlsCipher(HITLS_AES128_CBC, key, iv, data, true)
}

func aes128CbcDecrypt(key: Array<Byte>, iv: Array<Byte>, data: Array<Byte>): Array<Byte> {
    if (!HITLS_READY) {
        throw Exception("aes requires openHiTLS backend")
    }
    return hitlsCipher(HITLS_AES128_CBC, key, iv, data, false)
}

func pbkdf2(prf: (Array<Byte>) -> Array<Byte>, password: Array<Byte>, salt: Array<Byte>, iterations: Int64, dkLen: Int64): Array<Byte> {
    let out = Array<Byte>(dkLen, repeat: 0)
    var block: Int64 = 1
    var offset: Int64 = 0
    while (offset < dkLen) {
        let msg = Array<Byte>(salt.size + 4, repeat: 0)
        if (salt.size > 0) {
            salt.copyTo(msg, 0, 0, salt.size)
        }
        msg[salt.size] = UInt8((block >> 24) & 0xFF)
        msg[salt.size + 1] = UInt8((block >> 16) & 0xFF)
        msg[salt.size + 2] = UInt8((block >> 8) & 0xFF)
        msg[salt.size + 3] = UInt8(block & 0xFF)
        var u = prf(msg)
        let t = u.clone()
        var i: Int64 = 1
        while (i < iterations) {
            u = prf(u)
            for (j in 0..t.size) {
                t[j] = t[j] ^ u[j]
            }
            i = i + 1
        }
        var n = t.size
        if (dkLen - offset < n) {
            n = dkLen - offset
        }
        for (j in 0..n) {
            out[offset + j] = t[j]
        }
        offset = offset + n
        block = block + 1
    }
    return out
}

func pbkdf2Sm3(password: Array<Byte>, salt: Array<Byte>, iterations: Int64, dkLen: Int64): Array<Byte> {
    return pbkdf2({data => hmacSm3(password, data)}, password, salt, iterations, dkLen)
}

func pbkdf2Sha256(password: Array<Byte>, salt: Array<Byte>, iterations: Int64, dkLen: Int64): Array<Byte> {
    return pbkdf2({data => hmacSha256(password, data)}, password, salt, iterations, dkLen)
}

var CACHED_MASTER = ""
var CACHED_ENC_KEY: Array<Byte> = Array<Byte>()
var CACHED_MAC_KEY: Array<Byte> = Array<Byte>()
let KEY_CACHE_LOCK = Mutex()

func deriveKeys(master: String): (Array<Byte>, Array<Byte>) {
    synchronized(KEY_CACHE_LOCK) {
        if (CACHED_MASTER == master && CACHED_ENC_KEY.size == 16) {
            return (CACHED_ENC_KEY, CACHED_MAC_KEY)
        }
        let enc = pbkdf2Sm3(master.toArray(), HMAC_ENC_LABEL.toArray(), 50000, 16)
        let mac = pbkdf2Sm3(master.toArray(), HMAC_MAC_LABEL.toArray(), 50000, 32)
        CACHED_MASTER = master
        CACHED_ENC_KEY = enc
        CACHED_MAC_KEY = mac
        return (enc, mac)
    }
}

func cryptoEnabled(): Bool {
    return !DB_MASTER_KEY.isEmpty()
}

func encryptText(plaintext: String): String {
    if (!cryptoEnabled()) {
        return plaintext
    }
    let (encKey, macKey) = deriveKeys(DB_MASTER_KEY)
    let iv = randomBytes(16)
    let ct = sm4CbcEncrypt(encKey, iv, plaintext.toArray())
    let mac = hmacSm3(macKey, bytesConcat(iv, ct))
    return SM_PREFIX + b64Encode(bytesConcat3(iv, ct, mac))
}

func decryptText(stored: String): String {
    if (stored.isEmpty() || !cryptoEnabled()) {
        return stored
    }
    if (stored.startsWith(SM_PREFIX)) {
        let raw = b64Decode(stored[SM_PREFIX.size..])
        if (raw.size < 16 + 32) {
            throw Exception("ciphertext too short")
        }
        let iv = raw[0..16]
        let ct = raw[16..raw.size - 32]
        let mac = raw[raw.size - 32..]
        let (encKey, macKey) = deriveKeys(DB_MASTER_KEY)
        let expected = hmacSm3(macKey, bytesConcat(iv, ct))
        if (!constantTimeEq(expected, mac)) {
            throw Exception("SM4 ciphertext authentication failed")
        }
        return String.fromUtf8(sm4CbcDecrypt(encKey, iv, ct))
    }
    if (stored.startsWith(LEGACY_PREFIX)) {
        return legacyDecrypt(DB_MASTER_KEY, stored)
    }
    return stored
}

func isLegacyCipher(stored: String): Bool {
    return !stored.isEmpty() && stored.startsWith(LEGACY_PREFIX)
}

func isSmCipher(stored: String): Bool {
    return !stored.isEmpty() && stored.startsWith(SM_PREFIX)
}

func pkcs7Unpad(data: Array<Byte>): Array<Byte> {
    if (data.size == 0) {
        throw Exception("invalid padding")
    }
    let pad = Int64(data[data.size - 1])
    if (pad <= 0 || pad > 16 || pad > data.size) {
        throw Exception("invalid padding")
    }
    for (i in data.size - pad..data.size) {
        if (Int64(data[i]) != pad) {
            throw Exception("invalid padding")
        }
    }
    return data[0..data.size - pad]
}

func legacyKeyBytes(master: String): Array<Byte> {
    return sha256(master.toArray())
}

func legacyEncrypt(master: String, plaintext: String): String {
    let key = legacyKeyBytes(master)
    let signKey = key[0..16]
    let encKey = key[16..32]
    let iv = randomBytes(16)
    let ct = aes128CbcEncrypt(encKey, iv, plaintext.toArray())
    let versionByte = Array<Byte>(1, repeat: 0)
    versionByte[0] = 0x80
    let header = bytesConcat(versionByte, Array<Byte>(8, repeat: 0))
    let basic = bytesConcat3(header, iv, ct)
    let mac = hmacSha256(signKey, basic)
    return LEGACY_PREFIX + b64Encode(bytesConcat(basic, mac))
}

func legacyDecrypt(master: String, token: String): String {
    let raw = b64Decode(token[LEGACY_PREFIX.size..])
    if (raw.size < 1 + 8 + 16 + 32) {
        throw Exception("legacy ciphertext too short")
    }
    if (raw[0] != 0x80) {
        throw Exception("unsupported legacy version")
    }
    let key = legacyKeyBytes(master)
    let signKey = key[0..16]
    let encKey = key[16..32]
    let basic = raw[0..raw.size - 32]
    let mac = raw[raw.size - 32..]
    let expected = hmacSha256(signKey, basic)
    if (!constantTimeEq(expected, mac)) {
        throw Exception("legacy ciphertext authentication failed")
    }
    let iv = raw[9..25]
    let ct = raw[25..raw.size - 32]
    return String.fromUtf8(aes128CbcDecrypt(encKey, iv, ct))
}

func hashPassword(password: String): String {
    let salt = randomHex(16)
    let dk = pbkdf2Sm3(password.toArray(), salt.toArray(), SM3_PASSWORD_ITER, 32)
    return "sm3$" + SM3_PASSWORD_ITER.toString() + "$" + salt + "$" + hexEncode(dk)
}

func hashPasswordLegacy(password: String): String {
    let salt = randomHex(16)
    let dk = pbkdf2Sha256(password.toArray(), salt.toArray(), LEGACY_PASSWORD_ITER, 32)
    return salt + "$" + hexEncode(dk)
}

func verifyPassword(password: String, stored: String): Bool {
    if (stored.isEmpty()) {
        return false
    }
    if (stored.startsWith("sm3$")) {
        let parts = stored.split("$")
        if (parts.size != 4) {
            return false
        }
        let iterations = match (Int64.tryParse(parts[1])) {
            case Some(n) => n
            case None => return false
        }
        let dk = pbkdf2Sm3(password.toArray(), parts[2].toArray(), iterations, 32)
        return constantTimeEqStr(hexEncode(dk), parts[3])
    }
    let idx = stored.indexOf("$")
    match (idx) {
        case Some(i) =>
            let salt = stored[0..i]
            let expected = stored[i + 1..]
            let dk = pbkdf2Sha256(password.toArray(), salt.toArray(), LEGACY_PASSWORD_ITER, 32)
            return constantTimeEqStr(hexEncode(dk), expected)
        case None => return false
    }
}

func passwordNeedsUpgrade(stored: String): Bool {
    return !stored.isEmpty() && !stored.startsWith("sm3$")
}

func tokenHash(token: String): String {
    return sm3Hex(token.toArray())
}

func tokenHashLegacy(token: String): String {
    return sha256Hex(token.toArray())
}

func masterFingerprint(): String {
    if (!cryptoEnabled()) {
        return ""
    }
    let full = sm3Hex(DB_MASTER_KEY.toArray())
    if (full.size < 8) {
        return full
    }
    return full[0..8]
}

func generatePassword(n: Int64): String {
    let alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#$%"
    let chars = alphabet.toArray()
    let sb = StringBuilder()
    let rb = randomBytes(n)
    for (i in 0..n) {
        sb.append(byteStr(chars[Int64(rb[i]) % Int64(chars.size)]))
    }
    return sb.toString()
}

func generateSimplePassword(n: Int64): String {
    let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    let chars = alphabet.toArray()
    let sb = StringBuilder()
    let rb = randomBytes(n)
    for (i in 0..n) {
        sb.append(byteStr(chars[Int64(rb[i]) % Int64(chars.size)]))
    }
    return sb.toString()
}

func genTotpSecret(): String {
    return b32Encode(randomBytes(20))
}

func totpAt(secret: String, at: Int64, step: Int64): String {
    let keyBytes = b32Decode(secret)
    let counter = at / step
    let msg = Array<Byte>(8, repeat: 0)
    for (i in 0..8) {
        msg[7 - i] = UInt8((counter >> (i * 8)) & 0xFF)
    }
    let digest = hmacSha1(keyBytes, msg)
    let offset = Int64(digest[digest.size - 1] & 0x0F)
    let code = ((Int64(digest[offset]) & 0x7F) << 24) |
        ((Int64(digest[offset + 1]) & 0xFF) << 16) |
        ((Int64(digest[offset + 2]) & 0xFF) << 8) |
        (Int64(digest[offset + 3]) & 0xFF)
    let value = code % 1000000
    let text = value.toString()
    if (text.size >= 6) {
        return text
    }
    return repeatStr("0", 6 - text.size) + text
}

func verifyTotp(secret: String, code: String, window!: Int64 = 1): Bool {
    if (secret.isEmpty() || code.size != 6) {
        return false
    }
    for (c in code.toArray()) {
        if (c < 48 || c > 57) {
            return false
        }
    }
    let now = unixSeconds()
    var i = -window
    while (i <= window) {
        if (constantTimeEqStr(totpAt(secret, now + i * 30, 30), code)) {
            return true
        }
        i = i + 1
    }
    return false
}

func otpauthUrl(username: String, secret: String): String {
    return "otpauth://totp/ModernMirror:" + username + "?secret=" + secret + "&issuer=ModernMirror&period=30&digits=6"
}

func fileSha256(path: String): String {
    let f = File(path, OpenMode.Read)
    let sha = SHA256()
    let buf = Array<Byte>(1048576, repeat: 0)
    try {
        while (true) {
            let n = f.read(buf)
            if (n <= 0) {
                break
            }
            sha.write(buf[0..n])
        }
    } finally {
        f.close()
    }
    return hexEncode(sha.finish())
}

func fileMd5(path: String): String {
    let f = File(path, OpenMode.Read)
    let md = MD5()
    let buf = Array<Byte>(1048576, repeat: 0)
    try {
        while (true) {
            let n = f.read(buf)
            if (n <= 0) {
                break
            }
            md.write(buf[0..n])
        }
    } finally {
        f.close()
    }
    return hexEncode(md.finish())
}

func fileSha512B64(path: String): String {
    let f = File(path, OpenMode.Read)
    let sha = SHA512()
    let buf = Array<Byte>(1048576, repeat: 0)
    try {
        while (true) {
            let n = f.read(buf)
            if (n <= 0) {
                break
            }
            sha.write(buf[0..n])
        }
    } finally {
        f.close()
    }
    return b64Encode(sha.finish())
}
