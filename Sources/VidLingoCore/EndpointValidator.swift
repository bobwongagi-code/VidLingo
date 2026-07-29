import Foundation

public struct ValidatedEndpoint: Sendable, Equatable {
    public let url: URL
    public let origin: String
}

public enum EndpointValidationError: LocalizedError, Sendable, Equatable {
    case invalidURL
    case hostRequired
    case credentialsNotAllowed
    case queryOrFragmentNotAllowed
    case httpsRequired
    case localHTTPNotAllowed

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Custom endpoint 不是有效 URL。"
        case .hostRequired:
            "Custom endpoint 必须包含主机名。"
        case .credentialsNotAllowed:
            "Custom endpoint 不能在 URL 中包含用户名或密码。"
        case .queryOrFragmentNotAllowed:
            "Custom endpoint 不能在 URL 中包含 query 或 fragment。请把认证信息放到 API key 字段。"
        case .httpsRequired:
            "Custom endpoint 必须使用 HTTPS。"
        case .localHTTPNotAllowed:
            "明文 HTTP 只允许在显式开发选项下访问本机地址。"
        }
    }
}

public enum EndpointValidator {
    public static func validate(
        _ text: String,
        allowLoopbackHTTP: Bool = false
    ) throws -> ValidatedEndpoint {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw EndpointValidationError.invalidURL
        }
        guard let host = components.host, !host.isEmpty else {
            throw EndpointValidationError.hostRequired
        }
        guard components.user == nil && components.password == nil else {
            throw EndpointValidationError.credentialsNotAllowed
        }
        guard components.query == nil && components.fragment == nil else {
            throw EndpointValidationError.queryOrFragmentNotAllowed
        }

        let scheme = (components.scheme ?? "").lowercased()
        if scheme == "https" {
            return ValidatedEndpoint(url: url, origin: origin(from: components))
        }

        guard scheme == "http" else {
            throw EndpointValidationError.httpsRequired
        }
        guard allowLoopbackHTTP, isLoopback(host) else {
            throw EndpointValidationError.localHTTPNotAllowed
        }
        return ValidatedEndpoint(url: url, origin: origin(from: components))
    }

    private static func isLoopback(_ host: String) -> Bool {
        let normalized = host.lowercased()
        return normalized == "localhost"
            || normalized == "127.0.0.1"
            || normalized == "::1"
            || normalized == "[::1]"
    }

    private static func origin(from components: URLComponents) -> String {
        let host = components.host ?? ""
        let displayHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        var origin = "\(components.scheme?.lowercased() ?? "")://\(displayHost)"
        if let port = components.port {
            origin += ":\(port)"
        }
        return origin
    }
}
