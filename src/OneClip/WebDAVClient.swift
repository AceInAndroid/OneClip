import Foundation

struct WebDAVResource: Equatable {
    let url: URL
    let isCollection: Bool
    let etag: String?
    let contentLength: Int64?
    let lastModified: Date?
}

struct WebDAVResponse: Equatable {
    let statusCode: Int
    let etag: String?
}

protocol WebDAVClientProtocol: AnyObject {
    func testConnection(baseURL: URL, requireStrongETag: Bool) async throws
    func ensureCollection(_ collectionURL: URL, under baseURL: URL) async throws
    func list(_ collectionURL: URL, depth: Int) async throws -> [WebDAVResource]
    func get(_ url: URL, maximumBytes: Int) async throws -> Data
    func download(_ url: URL, to destinationURL: URL, maximumBytes: Int64) async throws
    func put(_ data: Data, to url: URL, ifMatch: String?, ifNoneMatch: Bool) async throws -> WebDAVResponse
    func putFile(_ fileURL: URL, to url: URL, ifMatch: String?, ifNoneMatch: Bool) async throws -> WebDAVResponse
    func delete(_ url: URL, ignoreMissing: Bool) async throws
    func exists(_ url: URL) async throws -> Bool
}

final class WebDAVHTTPClient: NSObject, WebDAVClientProtocol, URLSessionTaskDelegate, URLSessionDelegate {
    private let credential: WebDAVCredential
    private let allowedOrigin: WebDAVOrigin
    private let providedSessionConfiguration: URLSessionConfiguration?
    private let maximumMetadataBytes = 5 * 1024 * 1024
    private lazy var session: URLSession = {
        let configuration = (providedSessionConfiguration?.copy() as? URLSessionConfiguration)
            ?? URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    init(
        configuration: WebDAVConfiguration,
        credential: WebDAVCredential,
        sessionConfiguration: URLSessionConfiguration? = nil
    ) throws {
        guard let baseURL = configuration.baseURL else { throw WebDAVFeatureError.invalidURL }
        self.credential = credential
        self.allowedOrigin = try WebDAVOrigin(url: baseURL)
        self.providedSessionConfiguration = sessionConfiguration
        super.init()
    }

    deinit {
        session.invalidateAndCancel()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let protectionSpace = challenge.protectionSpace
        let method = protectionSpace.authenticationMethod

        if method == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        guard challenge.previousFailureCount == 0,
              protectionSpace.host.caseInsensitiveCompare(allowedOrigin.host) == .orderedSame,
              protectionSpace.port == allowedOrigin.port,
              method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        completionHandler(
            .useCredential,
            URLCredential(
                user: credential.username,
                password: credential.password,
                persistence: .forSession
            )
        )
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              (try? WebDAVOrigin(url: url)) == allowedOrigin else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func testConnection(baseURL: URL, requireStrongETag: Bool) async throws {
        try validateOrigin(baseURL)

        var options = URLRequest(url: baseURL)
        options.httpMethod = "OPTIONS"
        let (_, optionsResponse) = try await perform(options, acceptedStatusCodes: 200...299)
        let davHeader = optionsResponse.value(forHTTPHeaderField: "DAV") ?? ""
        guard davHeader.split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "1" }) else {
            throw WebDAVFeatureError.serverNotWebDAV
        }

        let probeDirectory = baseURL.appendingPathComponent(".pastelight-probe-\(UUID().uuidString)", isDirectory: true)
        let probeFile = probeDirectory.appendingPathComponent("probe.bin")
        do {
            try await ensureCollection(probeDirectory, under: baseURL)
            let firstData = Data("PasteLight-WebDAV-Probe-1".utf8)
            let firstResponse = try await put(firstData, to: probeFile, ifMatch: nil, ifNoneMatch: true)
            let downloaded = try await get(probeFile, maximumBytes: 1024)
            guard downloaded == firstData else { throw WebDAVFeatureError.corruptedPayload }

            let listedResources = try await list(probeDirectory, depth: 1)
            var etag = firstResponse.etag
                ?? listedResources.first(where: { $0.url.lastPathComponent == probeFile.lastPathComponent })?.etag

            if requireStrongETag {
                if etag == nil {
                    etag = try await list(probeFile, depth: 0).first?.etag
                }
                guard let etag, Self.isStrongETag(etag) else {
                    throw WebDAVFeatureError.strongETagRequired
                }

                let secondData = Data("PasteLight-WebDAV-Probe-2".utf8)
                _ = try await put(secondData, to: probeFile, ifMatch: etag, ifNoneMatch: false)
                do {
                    _ = try await put(firstData, to: probeFile, ifMatch: etag, ifNoneMatch: false)
                    throw WebDAVFeatureError.strongETagRequired
                } catch WebDAVFeatureError.remoteConflict {
                    // Expected: stale ETag must be rejected.
                }
            }
        } catch {
            try? await delete(probeDirectory, ignoreMissing: true)
            throw error
        }
        try await delete(probeDirectory, ignoreMissing: true)
    }

    func ensureCollection(_ collectionURL: URL, under baseURL: URL) async throws {
        try validateOrigin(collectionURL)
        try validateOrigin(baseURL)
        let baseComponents = baseURL.standardized.pathComponents
        let targetComponents = collectionURL.standardized.pathComponents
        guard targetComponents.starts(with: baseComponents) else {
            throw WebDAVFeatureError.invalidRemotePath
        }

        var currentURL = baseURL
        for component in targetComponents.dropFirst(baseComponents.count) where component != "/" {
            currentURL.appendPathComponent(component, isDirectory: true)
            var request = URLRequest(url: currentURL)
            request.httpMethod = "MKCOL"
            do {
                _ = try await perform(request, acceptedStatusCodes: 200...299)
            } catch WebDAVFeatureError.unsupportedResponse(405) {
                let resources = try await list(currentURL, depth: 0)
                guard resources.contains(where: { $0.isCollection }) else {
                    throw WebDAVFeatureError.unsupportedResponse(405)
                }
            }
        }
    }

    func list(_ collectionURL: URL, depth: Int) async throws -> [WebDAVResource] {
        try validateOrigin(collectionURL)
        guard depth == 0 || depth == 1 else { throw WebDAVFeatureError.serverMessage("仅支持 Depth 0 或 1") }
        var request = URLRequest(url: collectionURL)
        request.httpMethod = "PROPFIND"
        request.setValue(String(depth), forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(
            """
            <?xml version="1.0" encoding="utf-8" ?>
            <d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getetag/><d:getcontentlength/><d:getlastmodified/></d:prop></d:propfind>
            """.utf8
        )
        let (data, _) = try await perform(request, acceptedStatusCodes: 207...207)
        guard data.count <= maximumMetadataBytes else { throw WebDAVFeatureError.payloadTooLarge }
        let resources = try WebDAVMultiStatusParser.parse(
            data: data,
            requestURL: collectionURL,
            allowedOrigin: allowedOrigin
        )
        let baseComponents = collectionURL.standardized.pathComponents
        guard resources.allSatisfy({ resource in
            let components = resource.url.standardized.pathComponents
            guard components.starts(with: baseComponents) else { return false }
            return depth == 0
                ? components.count == baseComponents.count
                : components.count <= baseComponents.count + 1
        }) else {
            throw WebDAVFeatureError.invalidRemotePath
        }
        return resources
    }

    func get(_ url: URL, maximumBytes: Int) async throws -> Data {
        try validateOrigin(url)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (data, _) = try await perform(request, acceptedStatusCodes: 200...299)
        guard data.count <= maximumBytes else { throw WebDAVFeatureError.payloadTooLarge }
        return data
    }

    func download(_ url: URL, to destinationURL: URL, maximumBytes: Int64) async throws {
        try validateOrigin(url)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (temporaryURL, response) = try await session.download(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebDAVFeatureError.serverMessage("WebDAV 返回了无效响应")
        }
        if let finalURL = httpResponse.url { try validateOrigin(finalURL) }
        try validateStatus(httpResponse.statusCode)
        if let expectedLength = response.expectedContentLength as Int64?,
           expectedLength > maximumBytes {
            throw WebDAVFeatureError.payloadTooLarge
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: temporaryURL.path)
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard byteCount <= maximumBytes else { throw WebDAVFeatureError.payloadTooLarge }
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
    }

    func put(_ data: Data, to url: URL, ifMatch: String?, ifNoneMatch: Bool) async throws -> WebDAVResponse {
        try validateOrigin(url)
        var request = putRequest(url: url, ifMatch: ifMatch, ifNoneMatch: ifNoneMatch)
        request.httpBody = data
        let (_, response) = try await perform(request, acceptedStatusCodes: 200...299)
        return WebDAVResponse(statusCode: response.statusCode, etag: response.value(forHTTPHeaderField: "ETag"))
    }

    func putFile(_ fileURL: URL, to url: URL, ifMatch: String?, ifNoneMatch: Bool) async throws -> WebDAVResponse {
        try validateOrigin(url)
        let request = putRequest(url: url, ifMatch: ifMatch, ifNoneMatch: ifNoneMatch)
        let (_, response) = try await session.upload(for: request, fromFile: fileURL)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebDAVFeatureError.serverMessage("WebDAV 返回了无效响应")
        }
        if let finalURL = httpResponse.url { try validateOrigin(finalURL) }
        try validateStatus(httpResponse.statusCode)
        return WebDAVResponse(statusCode: httpResponse.statusCode, etag: httpResponse.value(forHTTPHeaderField: "ETag"))
    }

    func delete(_ url: URL, ignoreMissing: Bool) async throws {
        try validateOrigin(url)
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        do {
            let (data, response) = try await perform(request, acceptedStatusCodes: 200...299)
            if response.statusCode == 207, !data.isEmpty {
                _ = try WebDAVMultiStatusParser.parse(
                    data: data,
                    requestURL: url,
                    allowedOrigin: allowedOrigin
                )
            }
        } catch WebDAVFeatureError.unsupportedResponse(404) where ignoreMissing {
            return
        }
    }

    func exists(_ url: URL) async throws -> Bool {
        try validateOrigin(url)
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        do {
            _ = try await perform(request, acceptedStatusCodes: 200...299)
            return true
        } catch WebDAVFeatureError.unsupportedResponse(404) {
            return false
        } catch WebDAVFeatureError.unsupportedResponse(405) {
            do {
                return try await !list(url, depth: 0).isEmpty
            } catch WebDAVFeatureError.unsupportedResponse(404) {
                return false
            }
        }
    }

    private func putRequest(url: URL, ifMatch: String?, ifNoneMatch: Bool) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        if let ifMatch { request.setValue(ifMatch, forHTTPHeaderField: "If-Match") }
        if ifNoneMatch { request.setValue("*", forHTTPHeaderField: "If-None-Match") }
        return request
    }

    private func perform(
        _ request: URLRequest,
        acceptedStatusCodes: ClosedRange<Int>
    ) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebDAVFeatureError.serverMessage("WebDAV 返回了无效响应")
        }
        if let finalURL = httpResponse.url { try validateOrigin(finalURL) }
        guard acceptedStatusCodes.contains(httpResponse.statusCode) else {
            try validateStatus(httpResponse.statusCode)
            throw WebDAVFeatureError.unsupportedResponse(httpResponse.statusCode)
        }
        return (data, httpResponse)
    }

    private func validateStatus(_ statusCode: Int) throws {
        switch statusCode {
        case 200...299: return
        case 401: throw WebDAVFeatureError.authenticationFailed
        case 403: throw WebDAVFeatureError.serverMessage("服务器拒绝访问，请检查账号目录权限")
        case 409: throw WebDAVFeatureError.serverMessage("远端父目录不存在或服务器拒绝创建目录")
        case 412: throw WebDAVFeatureError.remoteConflict
        case 507: throw WebDAVFeatureError.serverMessage("WebDAV 存储空间或配额不足")
        default: throw WebDAVFeatureError.unsupportedResponse(statusCode)
        }
    }

    private func validateOrigin(_ url: URL) throws {
        guard try WebDAVOrigin(url: url) == allowedOrigin else {
            throw WebDAVFeatureError.invalidURL
        }
    }

    static func isStrongETag(_ etag: String) -> Bool {
        let value = etag.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.hasPrefix("W/") && value.hasPrefix("\"") && value.hasSuffix("\"")
    }
}

private struct WebDAVOrigin: Equatable {
    let scheme: String
    let host: String
    let port: Int

    init(url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), scheme == "https",
              let host = url.host?.lowercased() else {
            throw WebDAVFeatureError.insecureURL
        }
        self.scheme = scheme
        self.host = host
        self.port = url.port ?? 443
    }
}

private final class WebDAVMultiStatusParser: NSObject, XMLParserDelegate {
    private struct ResponseBuilder {
        var href = ""
        var isCollection = false
        var etag: String?
        var contentLength: Int64?
        var lastModified: Date?
        var responseStatusCode: Int?
    }

    private struct PropstatBuilder {
        var isCollection = false
        var etag: String?
        var contentLength: Int64?
        var lastModified: Date?
        var statusCode: Int?
    }

    private let requestURL: URL
    private let allowedOrigin: WebDAVOrigin
    private var currentResponse: ResponseBuilder?
    private var currentPropstat: PropstatBuilder?
    private var currentText = ""
    private(set) var resources: [WebDAVResource] = []
    private var firstResponseFailure: Int?

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter
    }()

    init(requestURL: URL, allowedOrigin: WebDAVOrigin) {
        self.requestURL = requestURL
        self.allowedOrigin = allowedOrigin
    }

    static func parse(data: Data, requestURL: URL, allowedOrigin: WebDAVOrigin) throws -> [WebDAVResource] {
        let delegate = WebDAVMultiStatusParser(requestURL: requestURL, allowedOrigin: allowedOrigin)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else {
            throw WebDAVFeatureError.serverMessage("无法解析 WebDAV Multi-Status 响应")
        }
        if let failure = delegate.firstResponseFailure {
            throw WebDAVFeatureError.unsupportedResponse(failure)
        }
        return delegate.resources
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard namespaceURI == "DAV:" || namespaceURI == nil else { return }
        let element = elementName.lowercased()
        currentText = ""
        if element == "response" { currentResponse = ResponseBuilder() }
        if element == "propstat" { currentPropstat = PropstatBuilder() }
        if element == "collection" { currentPropstat?.isCollection = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard namespaceURI == "DAV:" || namespaceURI == nil else { return }
        let element = elementName.lowercased()
        let value = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch element {
        case "href": currentResponse?.href = value
        case "status":
            let code = value.split(separator: " ").compactMap({ Int($0) }).first
            if currentPropstat != nil {
                currentPropstat?.statusCode = code
            } else {
                currentResponse?.responseStatusCode = code
            }
        case "getetag": currentPropstat?.etag = value.isEmpty ? nil : value
        case "getcontentlength": currentPropstat?.contentLength = Int64(value)
        case "getlastmodified": currentPropstat?.lastModified = Self.httpDateFormatter.date(from: value)
        case "propstat": finishCurrentPropstat()
        case "response": finishCurrentResponse()
        default: break
        }
        currentText = ""
    }

    private func finishCurrentPropstat() {
        defer { currentPropstat = nil }
        guard let propstat = currentPropstat,
              let status = propstat.statusCode,
              (200...299).contains(status) else {
            return
        }
        if var response = currentResponse {
            response.isCollection = response.isCollection || propstat.isCollection
            currentResponse = response
        }
        if let etag = propstat.etag { currentResponse?.etag = etag }
        if let contentLength = propstat.contentLength { currentResponse?.contentLength = contentLength }
        if let lastModified = propstat.lastModified { currentResponse?.lastModified = lastModified }
    }

    private func finishCurrentResponse() {
        guard let response = currentResponse else { return }
        defer { currentResponse = nil }
        if let status = response.responseStatusCode, !(200...299).contains(status) {
            if firstResponseFailure == nil { firstResponseFailure = status }
            return
        }
        guard !response.href.isEmpty,
              let url = (
                URL(string: response.href, relativeTo: requestURL)
                    ?? response.href.removingPercentEncoding.flatMap { URL(string: $0, relativeTo: requestURL) }
              )?.absoluteURL,
              let origin = try? WebDAVOrigin(url: url), origin == allowedOrigin else {
            return
        }
        resources.append(
            WebDAVResource(
                url: url,
                isCollection: response.isCollection,
                etag: response.etag,
                contentLength: response.contentLength,
                lastModified: response.lastModified
            )
        )
    }
}
