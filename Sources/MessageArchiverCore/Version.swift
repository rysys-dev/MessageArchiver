import Foundation

// The single source of the version: the app footer, the About panel, the transcript cover
// page and the bundle's Info.plist (via Scripts/install.sh) all read it from here.
public enum AppVersion {
    public static let string = "1.1.0"

    /// The app, its platform and its version, so apps.rysys.net can show this build's page:
    /// its guide and download (conventions §1).
    public static var websiteURL: URL {
        URL(string: "https://apps.rysys.net/?app=messagearchiver&sys=macos&v=\(string)")!
    }

    /// Which build this is (decision Q6): the short git commit `Scripts/install.sh` stamps into
    /// the bundle's Info.plist, with "-modified" if the tree had uncommitted changes. "dev" for
    /// a build that didn't come from install.sh (tests, debug runs).
    public static var buildCode: String {
        Bundle.main.object(forInfoDictionaryKey: "RYSYSBuildCode") as? String ?? "dev"
    }

    /// "1.0.0 (c6ccf89)", as the About panel, archives and transcripts name the build.
    public static var full: String { "\(string) (\(buildCode))" }

    /// Where anyone given the app can get its source (GPL-3.0; decision Q4: a public GitHub
    /// repo). Nil until the repo exists: the About panel then leaves the link out, and
    /// Scripts/release.sh refuses to package.
    public static let sourceURL: URL? = URL(string: "https://github.com/rysys-dev/MessageArchiver")

    public static let upstreamName = "imessage-exporter"
    public static let upstreamURL = URL(string: "https://github.com/ReagentX/imessage-exporter")!
}
