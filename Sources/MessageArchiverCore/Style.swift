import Foundation

/// A conversation style (decision Q3, spec §9.2): a folder `Styles/<name>/` holding
/// `style.css` and `page.html`, a page template with `{{title}}`, `{{stylesheet}}`,
/// `{{header}}`, `{{content}}` and `{{footer}}`. v1 ships one, "Traditional".
public struct Style: Sendable, Equatable {
    public var name: String
    public var css: String
    /// The page up to `{{content}}`, and after it.
    var head: String
    var foot: String

    public static let traditional = "Traditional"

    public init(name: String, css: String, page: String) throws {
        let parts = page.components(separatedBy: "{{content}}")
        guard parts.count == 2 else { throw StyleError.badTemplate(name) }
        self.name = name
        self.css = css
        head = parts[0]
        foot = parts[1]
    }

    public static func load(_ name: String = traditional, from directory: URL? = Style.directory) throws -> Style {
        guard let folder = directory?.appendingPathComponent(name) else { throw StyleError.notFound(name) }
        do {
            let css = try String(contentsOf: folder.appendingPathComponent("style.css"), encoding: .utf8)
            let page = try String(contentsOf: folder.appendingPathComponent("page.html"), encoding: .utf8)
            return try Style(name: name, css: css, page: page)
        } catch let error as StyleError {
            throw error
        } catch {
            throw StyleError.notFound(name)
        }
    }

    /// `MAR_STYLES_DIR`; else `Contents/Resources/Styles` in the app; else the repo's `Styles/`
    /// (tests and debug builds).
    public static var directory: URL? {
        if let override = ProcessInfo.processInfo.environment["MAR_STYLES_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Styles"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        // Debug only: #filePath would put the build machine's path into a release binary.
        #if DEBUG
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let styles = repo.appendingPathComponent("Styles")
        return FileManager.default.fileExists(atPath: styles.path) ? styles : nil
        #else
        return nil
        #endif
    }

    func pageHead(title: String, stylesheet: String, header: String) -> String {
        head.replacingOccurrences(of: "{{title}}", with: HTML.escape(title))
            .replacingOccurrences(of: "{{stylesheet}}", with: HTML.escape(stylesheet))
            .replacingOccurrences(of: "{{header}}", with: header)
    }

    func pageFoot(footer: String) -> String {
        foot.replacingOccurrences(of: "{{footer}}", with: footer)
    }
}

public enum StyleError: Error, Equatable, LocalizedError {
    case notFound(String)
    case badTemplate(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let name): "The “\(name)” conversation style is missing from this copy of MessageArchiver."
        case .badTemplate(let name): "The “\(name)” conversation style’s page.html has no {{content}}."
        }
    }
}

enum HTML {
    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(c)
            }
        }
        return out
    }

    /// A relative path for `href` and `src`: each component percent-encoded, slashes kept.
    static func path(_ relative: String) -> String {
        relative.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? String($0) }
            .joined(separator: "/")
    }
}
