import AppKit
import MessageArchiverCore
import SwiftUI

/// The current skin's colours, ready for views. Read it with `@Environment(\.palette)`.
struct Palette {
    var accent: Color
    var panelBackground: Color
    var card: Color
    var sectionTitle: Color
    var chipFill: Color
    var chipText: Color
    var changedName: Color
    var flag: Color

    /// With Increase Contrast on, text the skin tints is drawn in the primary text colour.
    init(_ skin: Skin, increasedContrast: Bool) {
        accent = Color(skin.color(.accent))
        panelBackground = Color(skin.color(.panelBackground))
        card = Color(skin.color(.card))
        sectionTitle = increasedContrast ? .primary : Color(skin.color(.sectionTitle))
        chipFill = Color(skin.color(.chipFill))
        chipText = increasedContrast ? .primary : Color(skin.color(.chipText))
        changedName = Color(skin.color(.changedName))
        flag = Color(skin.color(.flag))
    }
}

extension EnvironmentValues {
    @Entry var palette = Palette(.standard, increasedContrast: false)
}

extension Color {
    /// Follows the window's appearance, light or dark.
    init(_ color: SkinColor) {
        let light = NSColor(rgb: RGB(hex: color.light)), dark = NSColor(rgb: RGB(hex: color.dark))
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

private extension NSColor {
    convenience init(rgb: RGB?) {
        let rgb = rgb ?? RGB(hex: "#808080")!
        self.init(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
    }
}

/// Puts the chosen skin into the environment, and its accent into `.tint`.
struct AppSkin: ViewModifier {
    @Environment(AppState.self) private var state
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let palette = Palette(state.skin, increasedContrast: contrast == .increased)
        content
            .environment(\.palette, palette)
            .tint(palette.accent)
    }
}

/// A rounded group of rows with a divider between each, on the skin's card colour.
struct PanelCard<Content: View>: View {
    @Environment(\.palette) private var palette
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(rows) { row in
                    if row.id != rows.first?.id {
                        Divider().padding(.leading, 12)
                    }
                    row
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                }
            }
        }
        .background(palette.card, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.08), lineWidth: 1))
    }
}

/// A title on the left and a control on the right, the way a grouped form lays out a row.
struct PanelRow<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            // The control keeps its size; a long title wraps instead.
            content.layoutPriority(1)
        }
    }
}
