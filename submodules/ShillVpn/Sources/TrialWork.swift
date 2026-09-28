/*
 * SHILLGRAM: SHILLVPN built into the app.
 *
 * The free trial's request pieces, as the desktop and Android clients build
 * them: a keyed hash of the device id (the site keeps only a hash of that)
 * and the proof of work the site asks for, so one script cannot take every
 * trial. Plain Foundation + CommonCrypto; runs off the main thread.
 */
import Foundation
import CommonCrypto

public enum TrialWork {
    /// hex(HMAC-SHA256(key = "SHILLGRAM app trial v1", id)).
    public static func deviceHash(_ id: Data) -> String {
        let key = Array("SHILLGRAM app trial v1".utf8)
        var mac = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        id.withUnsafeBytes { idBytes in
            CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256), key, key.count, idBytes.baseAddress, id.count, &mac)
        }
        return hex(mac)
    }

    /// "shillvpn/app-trial" \0 device \0 hour \0
    public static func prefix(device: String, hour: Int64) -> [UInt8] {
        var result = Array("shillvpn/app-trial".utf8)
        result.append(0)
        result.append(contentsOf: Array(device.utf8))
        result.append(0)
        result.append(contentsOf: Array(String(hour).utf8))
        result.append(0)
        return result
    }

    private final class Found {
        private let lock = NSLock()
        private var value: Int64 = 0

        func get() -> Int64 {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func offer(_ n: Int64) {
            lock.lock()
            if value == 0 {
                value = n
            }
            lock.unlock()
        }
    }

    /// Some n such that sha256(prefix + decimal(n)) starts with 24 zero
    /// bits: about 16 million tries spread over the cores.
    public static func solve(prefix: [UInt8]) -> String {
        let threads = max(1, min(8, ProcessInfo.processInfo.activeProcessorCount))
        let found = Found()
        var base = CC_SHA256_CTX()
        CC_SHA256_Init(&base)
        prefix.withUnsafeBufferPointer { buffer in
            _ = CC_SHA256_Update(&base, buffer.baseAddress, CC_LONG(buffer.count))
        }
        let start = base
        DispatchQueue.concurrentPerform(iterations: threads) { offset in
            var number = [UInt8](repeating: 0, count: 24)
            var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            var n = Int64(offset + 1)
            var checked = 0
            while true {
                if checked & 0xFFF == 0, found.get() != 0 {
                    return
                }
                checked += 1
                var position = number.count
                var value = n
                repeat {
                    position -= 1
                    number[position] = UInt8(ascii: "0") + UInt8(value % 10)
                    value /= 10
                } while value != 0
                var context = start
                number.withUnsafeBufferPointer { buffer in
                    _ = CC_SHA256_Update(&context, buffer.baseAddress! + position, CC_LONG(buffer.count - position))
                }
                _ = CC_SHA256_Final(&hash, &context)
                if hash[0] == 0 && hash[1] == 0 && hash[2] == 0 {
                    found.offer(n)
                    return
                }
                n += Int64(threads)
            }
        }
        return String(found.get())
    }

    static func hex(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(bytes.count * 2)
        for b in bytes {
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 0xF)])
        }
        return String(decoding: out, as: UTF8.self)
    }
}
