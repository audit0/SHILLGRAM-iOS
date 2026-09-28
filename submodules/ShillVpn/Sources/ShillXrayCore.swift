/*
 * SHILLGRAM: SHILLVPN built into the app.
 *
 * The Xray core (XTLS/libXray, in-process: an iOS app cannot start
 * processes). One core at a time; every call goes through one serial queue.
 * The config carries the servers and the local login: it is never logged,
 * and the core's own error text is not passed on (it may name a server).
 */
import Foundation
import LibXrayBinding

public enum ShillXrayCore {
    private static let queue = DispatchQueue(label: "shillvpn.core")

    public enum StartError: Error {
        case failed
    }

    private static func invoke(_ method: String, payload: [String: Any] = [:]) -> [String: Any]? {
        let request: [String: Any] = [
            "apiVersion": 3,
            "method": method,
            "payload": payload
        ]
        guard let response = ShillXrayInvoke(XrayConfig.writeJson(request)) else {
            return nil
        }
        return XrayConfig.parseObject(response)
    }

    private static func succeeded(_ response: [String: Any]?) -> Bool {
        return (response?["success"] as? NSNumber)?.boolValue ?? false
    }

    /// Starts the core with this config (stops a running one first).
    /// Call from any thread; done(true) on the main queue once it runs.
    public static func start(configJson: String, done: @escaping (Bool) -> Void) {
        queue.async {
            _ = invoke("stopXray")
            let ok = succeeded(invoke("runXray", payload: ["xrayJson": configJson]))
            DispatchQueue.main.async {
                done(ok)
            }
        }
    }

    public static func stop(done: (() -> Void)? = nil) {
        queue.async {
            _ = invoke("stopXray")
            if let done = done {
                DispatchQueue.main.async(execute: done)
            }
        }
    }

    /// Synchronous: whether the core reports an instance running.
    public static var isRunning: Bool {
        return queue.sync {
            let response = invoke("getXrayState")
            guard succeeded(response), let data = response?["data"] as? [String: Any] else {
                return false
            }
            return (data["running"] as? NSNumber)?.boolValue ?? false
        }
    }

    public static var version: String {
        return queue.sync {
            let response = invoke("xrayVersion")
            return ((response?["data"] as? [String: Any])?["version"] as? String) ?? ""
        }
    }
}
