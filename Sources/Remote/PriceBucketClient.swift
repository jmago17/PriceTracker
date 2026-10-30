import Foundation

struct PriceBucketConfiguration: Equatable, Sendable {
    var baseURL: URL
    var key: String
}

/// Thin client over the PriceBucket API v1. Credentials are read per request
/// from `configuration`, so changing them in Settings applies immediately and
/// the key is never held (or logged) by the client.
struct PriceBucketClient: Sendable {
    let transport: any PriceBucketTransport
    let configuration: @Sendable () throws -> PriceBucketConfiguration

    init(
        transport: any PriceBucketTransport = URLSessionTransport(),
        configuration: @escaping @Sendable () throws -> PriceBucketConfiguration
    ) {
        self.transport = transport
        self.configuration = configuration
    }

    // MARK: Routes

    func me() async throws -> MeResponse {
        try decode(MeResponse.self, from: try await send("GET", "me"))
    }

    func items(since: String? = nil) async throws -> ItemsResponse {
        let query = since.map { [URLQueryItem(name: "since", value: $0)] } ?? []
        return try decode(ItemsResponse.self, from: try await send("GET", "items", query: query))
    }

    /// `target` is passed through untouched; the app edits targets with PATCH
    /// `targetPriceCents` instead, whose unit is documented.
    func addItem(url: URL, target: Int? = nil, size: String? = nil, color: String? = nil) async throws -> Item {
        struct Body: Encodable { var url: String; var target: Int?; var size: String?; var color: String? }
        let body = Body(url: url.absoluteString, target: target, size: size, color: color)
        let data = try await send("POST", "items", body: try Self.encoder.encode(body))
        return try decode(ItemEnvelope.self, from: data).item
    }

    func item(id: UUID) async throws -> Item {
        try decode(ItemEnvelope.self, from: try await send("GET", "items/\(id.uuidString)")).item
    }

    func patchItem(id: UUID, patch: ItemPatch) async throws -> Item {
        let data = try await send("PATCH", "items/\(id.uuidString)", body: try Self.encoder.encode(patch))
        return try decode(ItemEnvelope.self, from: data).item
    }

    func deleteItem(id: UUID) async throws {
        _ = try await send("DELETE", "items/\(id.uuidString)")
    }

    func history(id: UUID) async throws -> [RemoteObservation] {
        try decode(HistoryResponse.self, from: try await send("GET", "items/\(id.uuidString)/history")).observations
    }

    func refreshItem(id: UUID) async throws -> RefreshResponse {
        try decode(RefreshResponse.self, from: try await send("POST", "items/\(id.uuidString)/refresh"))
    }

    // MARK: Plumbing

    private func send(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil) async throws -> Data {
        let config = try configuration()
        guard var components = URLComponents(url: config.baseURL, resolvingAgainstBaseURL: false) else {
            throw PriceBucketError.notConfigured
        }
        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = basePath + "/api/v1/" + path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw PriceBucketError.notConfigured }

        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue(config.key, forHTTPHeaderField: "x-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data, response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as PriceBucketError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch is URLError {
            throw PriceBucketError.offline
        }

        switch response.statusCode {
        case 200..<300: return data
        case 401: throw PriceBucketError.unauthorized
        case 404: throw PriceBucketError.notFound
        case 422:
            let text = (try? Self.decoder.decode(ServerErrorBody.self, from: data))?.error
            throw PriceBucketError.validation(text?.trimmedNonEmpty ?? "El servidor rechazó la petición.")
        case 502:
            throw PriceBucketError.storeUnreachable((try? Self.decoder.decode(ServerErrorBody.self, from: data))?.error)
        case 500..<600: throw PriceBucketError.server(response.statusCode)
        default: throw PriceBucketError.unexpectedStatus(response.statusCode)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try Self.decoder.decode(type, from: data) }
        catch { throw PriceBucketError.invalidResponse }
    }

    // The server writes `yyyy-MM-ddTHH:mm:ssZ`; fractions are tolerated just in case.
    nonisolated(unsafe) private static let plainDates = ISO8601DateFormatter()
    nonisolated(unsafe) private static let fractionalDates: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = plainDates.date(from: text) ?? fractionalDates.date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Fecha ISO 8601 no válida"))
        }
        return decoder
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
