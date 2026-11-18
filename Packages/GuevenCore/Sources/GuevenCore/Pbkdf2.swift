import Foundation
#if canImport(CommonCrypto)
import CommonCrypto
#endif

/// HMAC-SHA256 und PBKDF2 für die Profil-PIN. Auf Apple-Systemen rechnet CommonCrypto (schnell), sonst reines Swift
/// (gleiche Ergebnisse; unter Linux läuft damit der Test gegen Referenzwerte).
enum Pbkdf2 {
    static func hmacSHA256(key: [UInt8], message: [UInt8]) -> [UInt8] {
        var k = key.count > 64 ? SHA256Hash.digest(key) : key
        k += [UInt8](repeating: 0, count: 64 - k.count)
        let inner = SHA256Hash.digest(k.map { $0 ^ 0x36 } + message)
        return SHA256Hash.digest(k.map { $0 ^ 0x5c } + inner)
    }

    /// PBKDF2-HMAC-SHA256, 32 Byte Ausgabe.
    static func deriveKey(password: [UInt8], salt: [UInt8], iterations: Int, length: Int = 32) -> [UInt8] {
        #if canImport(CommonCrypto)
        var out = [UInt8](repeating: 0, count: length)
        let status = password.withUnsafeBufferPointer { pw in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), UnsafeRawPointer(pw.baseAddress ?? UnsafePointer(bitPattern: 1)!).assumingMemoryBound(to: Int8.self),
                                 password.count, salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations), &out, length)
        }
        if status == kCCSuccess { return out }
        #endif
        return pureSwift(password: password, salt: salt, iterations: iterations, length: length)
    }

    static func pureSwift(password: [UInt8], salt: [UInt8], iterations: Int, length: Int) -> [UInt8] {
        var result: [UInt8] = []
        var block: UInt32 = 1
        while result.count < length {
            var u = hmacSHA256(key: password, message: salt + [UInt8(block >> 24), UInt8((block >> 16) & 0xFF), UInt8((block >> 8) & 0xFF), UInt8(block & 0xFF)])
            var t = u
            if iterations > 1 {
                for _ in 1..<iterations {
                    u = hmacSHA256(key: password, message: u)
                    for i in 0..<t.count { t[i] ^= u[i] }
                }
            }
            result += t
            block += 1
        }
        return Array(result.prefix(length))
    }
}
