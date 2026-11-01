import Foundation
import Network

/// Step-by-step network probe shown in Settings → Servidor, to tell apart an iOS
/// block (cellular/Wi-Fi/local-network denied), DNS, TLS and server problems.
enum NetworkDiagnostics {
    static func run(settings: PriceBucketSettings) async -> String {
        var lines: [String] = []
        lines.append("Ruta de red: " + (await pathDescription()))
        let base = settings.baseURL
        lines.append("Servidor: \(base.absoluteString)")
        lines.append("Clave guardada: \(settings.apiKey == nil ? "no" : "sí")")
        lines.append(await probe("Apple (control)", URL(string: "https://www.apple.com/library/test/success.html")!))
        lines.append(await probe("Servidor /health", base.appendingPathComponent("health")))
        lines.append(await probe("Servidor /health (sin HTTP/3)", base.appendingPathComponent("health"), http3: false))
        lines.append(await probe("Servidor /health (sesión efímera)", base.appendingPathComponent("health"), ephemeral: true))
        if let key = settings.apiKey {
            lines.append(await probe("Servidor /api/v1/me", base.appendingPathComponent("api/v1/me"), key: key))
        }
        return lines.joined(separator: "\n")
    }

    private static func probe(_ label: String, _ url: URL, key: String? = nil, http3: Bool = true, ephemeral: Bool = false) async -> String {
        var request = URLRequest(url: url, timeoutInterval: 12)
        if let key { request.setValue(key, forHTTPHeaderField: "x-key") }
        request.assumesHTTP3Capable = http3
        let session = ephemeral ? URLSession(configuration: .ephemeral) : URLSession.shared
        let started = Date()
        func ms() -> Int { Int(Date().timeIntervalSince(started) * 1000) }
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            return "\(label): HTTP \(status), \(data.count) bytes, \(ms()) ms"
        } catch let error as URLError {
            return "\(label): URLError \(error.code.rawValue) (\(error.localizedDescription)), \(ms()) ms"
        } catch {
            return "\(label): \(error.localizedDescription), \(ms()) ms"
        }
    }

    private static func pathDescription() async -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "network-diagnostics")
            let lock = NSLock()
            nonisolated(unsafe) var finished = false
            monitor.pathUpdateHandler = { path in
                lock.lock(); defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                monitor.cancel()
                var parts = ["\(path.status)"]
                if path.status != .satisfied { parts.append("motivo: \(path.unsatisfiedReason)") }
                let interfaces = path.availableInterfaces.map { "\($0.type)" }.joined(separator: ",")
                parts.append("interfaces: \(interfaces)")
                parts.append("caro: \(path.isExpensive)")
                parts.append("restringido: \(path.isConstrained)")
                parts.append("IPv4: \(path.supportsIPv4) IPv6: \(path.supportsIPv6) DNS: \(path.supportsDNS)")
                continuation.resume(returning: parts.joined(separator: " · "))
            }
            monitor.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 3) {
                lock.lock(); defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                monitor.cancel()
                continuation.resume(returning: "sin respuesta del monitor de red")
            }
        }
    }
}
