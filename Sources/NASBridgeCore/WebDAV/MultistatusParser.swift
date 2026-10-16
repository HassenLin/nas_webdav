import Foundation

/// RFC 4918 `multistatus` 回應的解析器（只取本專案用到的屬性）。
///
/// 規則：
///   - 以命名空間感知模式解析，元素以 local name 比對（`d:`、`D:`、無前綴皆可）。
///   - 一個 `response` 可有多個 `propstat`；只採用狀態為 200 的 propstat 內的屬性。
enum MultistatusParser {
    struct Response: Equatable {
        var href = ""
        var isCollection = false
        var contentLength: Int64?
        var lastModified: Date?
        var creationDate: Date?
        var quotaAvailable: Int64?
        var quotaUsed: Int64?
    }

    static func parse(_ data: Data) -> [Response] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        parser.parse()
        return delegate.responses
    }

    // MARK: - 日期

    /// getlastmodified：RFC 1123（`Tue, 15 Nov 1994 12:45:26 GMT`）。
    /// DateFormatter 的解析在 macOS 10.9+ 為執行緒安全。
    private static let rfc1123: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    static func parseHTTPDate(_ s: String) -> Date? { rfc1123.date(from: s) }

    /// creationdate：ISO 8601（可能含或不含小數秒）。
    static func parseISODate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    // MARK: - SAX 委派

    private final class Delegate: NSObject, XMLParserDelegate {
        var responses: [Response] = []
        private var current: Response?
        private var pending = Response()     // 目前 propstat 收集中的屬性
        private var pendingStatusOK = false
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            switch name {
            case "response": current = Response()
            case "propstat": pending = Response(); pendingStatusOK = false
            case "collection": pending.isCollection = true
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "href": current?.href = value
            case "status": pendingStatusOK = value.contains(" 200")
            case "getcontentlength": pending.contentLength = Int64(value)
            case "getlastmodified": pending.lastModified = MultistatusParser.parseHTTPDate(value)
            case "creationdate": pending.creationDate = MultistatusParser.parseISODate(value)
            case "quota-available-bytes": pending.quotaAvailable = Int64(value)
            case "quota-used-bytes": pending.quotaUsed = Int64(value)
            case "propstat":
                if pendingStatusOK, var c = current {
                    c.isCollection = c.isCollection || pending.isCollection
                    c.contentLength = pending.contentLength ?? c.contentLength
                    c.lastModified = pending.lastModified ?? c.lastModified
                    c.creationDate = pending.creationDate ?? c.creationDate
                    c.quotaAvailable = pending.quotaAvailable ?? c.quotaAvailable
                    c.quotaUsed = pending.quotaUsed ?? c.quotaUsed
                    current = c
                }
            case "response":
                if let c = current { responses.append(c) }
                current = nil
            default: break
            }
            text = ""
        }
    }
}
