import AppKit
import MessageArchiverCore

@MainActor
enum AboutPanel {
    static func show() {
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        let small = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let plain: [NSAttributedString.Key: Any] = [.font: small, .paragraphStyle: centered]

        // GPL-3.0 attribution (spec §2): the engine is built on imessage-exporter's library.
        let credits = NSMutableAttributedString()
        credits.append(NSAttributedString(string: "rysys.net", attributes: plain.merging(
            [.link: AppVersion.websiteURL]) { $1 }))
        credits.append(NSAttributedString(string: "\n\nBuilt on the imessage-database library from ", attributes: plain))
        credits.append(NSAttributedString(string: AppVersion.upstreamName, attributes: plain.merging(
            [.link: AppVersion.upstreamURL]) { $1 }))
        credits.append(NSAttributedString(string: " by ReagentX.\nFree software under the GNU GPL v3.", attributes: plain))
        if let source = AppVersion.sourceURL {
            credits.append(NSAttributedString(string: "\n", attributes: plain))
            credits.append(NSAttributedString(string: "Source code", attributes: plain.merging([.link: source]) { $1 }))
        }
        if let notices = Bundle.main.url(forResource: "THIRD-PARTY-NOTICES", withExtension: "txt") {
            credits.append(NSAttributedString(string: AppVersion.sourceURL == nil ? "\n" : " · ", attributes: plain))
            credits.append(NSAttributedString(string: "Third-party notices", attributes: plain.merging([.link: notices]) { $1 }))
        }

        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "MessageArchiver",
            .applicationVersion: AppVersion.string,
            .version: AppVersion.buildCode,
            .credits: credits,
        ])
        NSApp.activate()
    }
}
