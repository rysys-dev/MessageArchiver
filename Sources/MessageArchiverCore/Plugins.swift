import Darwin
import Foundation
import Security

/// A plug-in's `plugin.json` (Milestone 17): who it is, which file runs, and what it needs.
public struct PluginManifest: Codable, Sendable, Equatable {
    /// Its source id (`whatsapp`); also its folder's name.
    public var id: SourceID
    public var name: String
    public var version: String
    public var `protocol`: Int
    /// The oldest MessageArchiver it works with.
    public var minimumApp: String
    /// The helper's file name, beside `plugin.json`.
    public var executable: String

    enum CodingKeys: String, CodingKey { case id, name, version, `protocol`, minimumApp = "minimum_app", executable }
}

/// A plug-in in the plug-ins folder, and whether it can be run.
public struct InstalledPlugin: Sendable {
    public var folder: URL
    public var manifest: PluginManifest?
    /// Why it can't be run (a bad manifest, a signature that doesn't check out); nil when it can.
    public var problem: String?

    public var executable: URL? { manifest.map { folder.appendingPathComponent($0.executable) } }
    public var instructions: URL { folder.appendingPathComponent("instructions.html") }
    public var name: String { manifest?.name ?? folder.lastPathComponent }
}

/// Only plug-ins RYSYS signed run (Milestone 17): a plug-in reads every message, so its
/// signature must check out against the RYSYS Local Code Signing certificate, built in here.
/// There's no Developer ID, so no Team ID to check: the certificate itself is pinned.
public enum PluginTrust {
    /// SHA-1 of the RYSYS Local Code Signing certificate (valid until 2036-10-05). Its private
    /// key is in the maintainer's login keychain, and must be backed up: without it, no new plug-in
    /// installs in a copy of the app that pins it.
    public static let rysysCertificate = "7BCF54E9C72EB1122B65138555DC6D9A03E73708"
    public static let requirement = "certificate leaf = H\"\(rysysCertificate)\""

    /// Nil when the file's signature is whole and meets `requirement`; otherwise why not.
    public static func problem(with executable: URL, requirement: String = requirement) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess, let code else {
            return "it isn’t a program MessageArchiver can check"
        }
        var req: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess, let req else {
            return "the signing requirement couldn’t be read"
        }
        var error: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), req, &error)
        error?.release()
        switch status {
        case errSecSuccess: return nil
        case errSecCSUnsigned: return "it isn’t signed"
        case errSecCSReqFailed: return "it isn’t signed by RYSYS"
        default: return "its signature doesn’t check out (it was changed after it was signed)"
        }
    }
}

public enum PluginError: Error, Equatable, LocalizedError {
    case notAPlugin(String)
    case badManifest(String)
    case wrongProtocol(name: String, speaks: Int)
    case needsNewerApp(name: String, version: String)
    case untrusted(name: String, why: String)
    case reserved(String)

    public var errorDescription: String? {
        switch self {
        case .notAPlugin(let file): "\(file) isn’t a MessageArchiver plug-in."
        case .badManifest(let why): "This plug-in’s description (plugin.json) can’t be read: \(why)."
        case .wrongProtocol(let name, let speaks):
            "\(name) speaks protocol \(speaks), and this MessageArchiver speaks \(Engine.protocolVersion). Get the version of the plug-in made for this MessageArchiver, or update MessageArchiver."
        case .needsNewerApp(let name, let version): "\(name) needs MessageArchiver \(version) or later. Update MessageArchiver first."
        case .untrusted(let name, let why): "\(name) wasn’t installed: \(why). Plug-ins come only from apps.rysys.net."
        case .reserved(let id): "A plug-in can’t be called “\(id)”: that is MessageArchiver’s own."
        }
    }
}

/// The plug-ins folder, `<data folder>/Plugins/<id>/`: install, list, remove (Milestone 17).
public enum PluginStore {
    public static var folder: URL { AppPaths.support.appendingPathComponent("Plugins") }

    /// Every plug-in there, each checked as it is now (a file changed since it was installed
    /// fails its signature, and doesn't run).
    public static func installed(in folder: URL = folder, requirement: String = PluginTrust.requirement) -> [InstalledPlugin] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted().map { name in
            let dir = folder.appendingPathComponent(name)
            do {
                let manifest = try readManifest(in: dir)
                let problem = PluginTrust.problem(with: dir.appendingPathComponent(manifest.executable), requirement: requirement)
                return InstalledPlugin(folder: dir, manifest: manifest, problem: problem.map { "\($0). Reinstall it from apps.rysys.net" })
            } catch {
                return InstalledPlugin(folder: dir, manifest: nil, problem: error.localizedDescription)
            }
        }
    }

    /// The engines to run: the plug-ins that check out, each in the sandbox.
    public static func engines(_ plugins: [InstalledPlugin]) -> [Engine] {
        plugins.compactMap { p in
            guard p.problem == nil, let exe = p.executable, let id = p.manifest?.id else { return nil }
            var engine = Engine(executable: exe, sourceID: id)
            engine.sandboxed = true
            return engine
        }
    }

    /// Unpacks a `.maplugin` (a zip holding `plugin.json`, the helper, `instructions.html`, its
    /// license and notices), checks it, and only then puts it in place: a plug-in already there
    /// goes to the Trash. Nothing that fails a check is kept.
    @discardableResult
    public static func install(_ archive: URL, into folder: URL = folder, requirement: String = PluginTrust.requirement,
                               appVersion: String = AppVersion.string, trash: TrashCan = .standard()) throws -> InstalledPlugin {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let staging = folder.appendingPathComponent(".installing-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }
        try unzip(archive, into: staging)
        // The zip holds the plug-in's folder, or its files directly.
        let entries = ((try? fm.contentsOfDirectory(atPath: staging.path)) ?? []).filter { !$0.hasPrefix(".") && $0 != "__MACOSX" }
        let root = entries.count == 1 && !fm.fileExists(atPath: staging.appendingPathComponent("plugin.json").path)
            ? staging.appendingPathComponent(entries[0]) : staging
        guard fm.fileExists(atPath: root.appendingPathComponent("plugin.json").path) else {
            throw PluginError.notAPlugin(archive.lastPathComponent)
        }
        let manifest = try readManifest(in: root)
        guard manifest.id != .messages else { throw PluginError.reserved(manifest.id.rawValue) }
        guard manifest.protocol == Engine.protocolVersion else {
            throw PluginError.wrongProtocol(name: manifest.name, speaks: manifest.protocol)
        }
        guard compare(appVersion, manifest.minimumApp) != .orderedAscending else {
            throw PluginError.needsNewerApp(name: manifest.name, version: manifest.minimumApp)
        }
        let exe = root.appendingPathComponent(manifest.executable)
        if let why = PluginTrust.problem(with: exe, requirement: requirement) {
            throw PluginError.untrusted(name: manifest.name, why: why)
        }
        // Checked: the download's quarantine flag comes off this copy only, so it can run.
        for path in (fm.enumerator(atPath: root.path)?.allObjects as? [String] ?? []) + [""] {
            removexattr(root.appendingPathComponent(path).path, "com.apple.quarantine", XATTR_NOFOLLOW)
        }
        let target = folder.appendingPathComponent(manifest.id.rawValue)
        if fm.fileExists(atPath: target.path) { try trash.discard(target) }
        try fm.moveItem(at: root, to: target)
        return InstalledPlugin(folder: target, manifest: manifest, problem: nil)
    }

    /// To the Trash, never deleted outright.
    public static func remove(_ plugin: InstalledPlugin, trash: TrashCan = .standard()) throws {
        try trash.discard(plugin.folder)
    }

    static func readManifest(in folder: URL) throws -> PluginManifest {
        let data: Data
        do { data = try Data(contentsOf: folder.appendingPathComponent("plugin.json")) } catch {
            throw PluginError.badManifest("there is no plugin.json")
        }
        let manifest: PluginManifest
        do { manifest = try JSONDecoder().decode(PluginManifest.self, from: data) } catch {
            throw PluginError.badManifest("\(error)")
        }
        // An id is a folder name and a source id: plain letters, digits and dashes.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        guard !manifest.id.rawValue.isEmpty, manifest.id.rawValue.unicodeScalars.allSatisfy(allowed.contains) else {
            throw PluginError.badManifest("its id “\(manifest.id)” isn’t letters, digits and dashes")
        }
        guard !manifest.executable.contains("/"), !manifest.executable.hasPrefix(".") else {
            throw PluginError.badManifest("its program must sit beside plugin.json")
        }
        return manifest
    }

    /// `ditto`, as Finder unzips: reads the zip, writes only the staging folder.
    static func unzip(_ archive: URL, into folder: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", archive.path, folder.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw PluginError.notAPlugin(archive.lastPathComponent) }
    }

    /// Dotted versions, number by number: "1.10.0" is after "1.9.2".
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let (p, q) = (i < x.count ? x[i] : 0, i < y.count ? y[i] : 0)
            if p != q { return p < q ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}
