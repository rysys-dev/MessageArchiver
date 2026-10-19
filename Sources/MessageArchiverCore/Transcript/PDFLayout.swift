import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Lays out and draws paginated PDFs with Core Text (decision Q10): text is broken into lines
/// and images sized first, then paginated, so the page count is known before a page is drawn
/// ("Page X of Y", spec §9.4), and the same input always gives the same pages.
enum PDFLayout {
    /// US Letter, with room for the header and footer.
    static let pageSize = CGSize(width: 612, height: 792)
    static let margin = CGFloat(54)
    static let top = CGFloat(76)
    static let bottom = CGFloat(66)
    static var contentWidth: CGFloat { pageSize.width - 2 * margin }
    static var contentHeight: CGFloat { pageSize.height - top - bottom }

    /// One drawable row: a line of text or an image.
    struct Row {
        enum Content {
            case line(CTLine, ascent: CGFloat)
            case image(CGImage, CGSize)
        }

        var content: Content
        var height: CGFloat
        var indent: CGFloat = 0
    }

    /// Rows that belong together: a cover, or one transcript entry.
    struct Block {
        var rows: [Row]
        /// The first rows that must share a page: an entry's header with its first line.
        var keep: Int
        /// Shown as "(entry #12 continued)" when the block runs onto a new page.
        var entry: Int?
        var pageBreakBefore = false
        var spaceAfter: CGFloat = 10
    }

    struct Placed {
        var row: Row
        var y: CGFloat
    }

    struct Page {
        var rows: [Placed] = []
        var continues: Int?
    }

    // MARK: Text

    static func font(_ size: CGFloat, bold: Bool = false, italic: Bool = false) -> CTFont {
        let base = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        guard italic, let slanted = CTFontCreateCopyWithSymbolicTraits(base, size, nil, .italicTrait, .italicTrait) else { return base }
        return slanted
    }

    static func text(_ s: String, size: CGFloat, bold: Bool = false, italic: Bool = false, gray: Bool = false) -> NSAttributedString {
        let color = gray ? CGColor(gray: 0.35, alpha: 1) : CGColor(gray: 0, alpha: 1)
        return NSAttributedString(string: s, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font(size, bold: bold, italic: italic),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ])
    }

    /// Breaks text into rows that fit `width`; line breaks in the text are kept.
    static func rows(_ text: NSAttributedString, width: CGFloat = contentWidth, indent: CGFloat = 0) -> [Row] {
        guard text.length > 0 else { return [] }
        let typesetter = CTTypesetterCreateWithAttributedString(text as CFAttributedString)
        var rows: [Row] = []
        var start = 0
        while start < text.length {
            let count = max(1, CTTypesetterSuggestLineBreak(typesetter, start, Double(width - indent)))
            let line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            rows.append(Row(content: .line(line, ascent: ascent), height: ceil((ascent + descent) * 1.18 + leading), indent: indent))
            start += count
        }
        return rows
    }

    static func line(_ s: String, size: CGFloat, bold: Bool = false, gray: Bool = false) -> CTLine {
        CTLineCreateWithAttributedString(text(s, size: size, bold: bold, gray: gray) as CFAttributedString)
    }

    // MARK: Images

    /// An image scaled down for a page and kept as JPEG, so a PDF with many photos stays small.
    static func image(at url: URL, maxWidth: CGFloat = contentWidth * 0.6, maxHeight: CGFloat = 252) -> Row? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 1200,
              ] as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, thumb, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
        guard CGImageDestinationFinalize(dest), let provider = CGDataProvider(data: data),
              let jpeg = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        let w = CGFloat(jpeg.width), h = CGFloat(jpeg.height)
        let scale = min(maxWidth / w, maxHeight / h, 1)
        let size = CGSize(width: floor(w * scale), height: floor(h * scale))
        return Row(content: .image(jpeg, size), height: size.height + 8)
    }

    // MARK: Pagination

    /// Places every row. An entry's first `keep` rows go to a new page together if they don't
    /// fit where they are; after that a block may run on, and the new page says so.
    static func paginate(_ blocks: [Block], height: CGFloat = contentHeight, continuedHeight: CGFloat = 14) -> [Page] {
        var pages = [Page()]
        var y: CGFloat = 0
        func newPage(continuing entry: Int?) {
            pages.append(Page(rows: [], continues: entry))
            y = entry == nil ? 0 : continuedHeight
        }
        for block in blocks {
            if block.pageBreakBefore, !pages[pages.count - 1].rows.isEmpty { newPage(continuing: nil) }
            let keepHeight = block.rows.prefix(block.keep).reduce(0) { $0 + $1.height }
            if y + keepHeight > height, y > 0 { newPage(continuing: nil) }
            for (i, row) in block.rows.enumerated() {
                if y + row.height > height, y > (pages[pages.count - 1].continues == nil ? 0 : continuedHeight) {
                    newPage(continuing: i > 0 ? block.entry : nil)
                }
                pages[pages.count - 1].rows.append(Placed(row: row, y: y))
                y += row.height
            }
            y += block.spaceAfter
        }
        return pages
    }

    // MARK: Drawing

    struct Decoration {
        /// Top left and top right of every page.
        var headerLeft: String
        var headerRight: String
        /// The Bates number of a page, by its index from 0.
        var bates: (Int) -> String
        var footerRight: String
        var title: String
        var author: String
        var creator: String
    }

    /// Draws the pages to `url`, written under a hidden name and moved into place when done,
    /// never over an existing file.
    static func draw(_ pages: [Page], decoration d: Decoration, to url: URL) throws {
        let partial = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).partial")
        defer { try? FileManager.default.removeItem(at: partial) }
        var box = CGRect(origin: .zero, size: pageSize)
        let info: [CFString: Any] = [kCGPDFContextTitle: d.title, kCGPDFContextAuthor: d.author, kCGPDFContextCreator: d.creator]
        guard let ctx = CGContext(partial as CFURL, mediaBox: &box, info as CFDictionary) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        let total = pages.count
        for (index, page) in pages.enumerated() {
            ctx.beginPDFPage(nil)
            ctx.textMatrix = .identity
            let headerY = pageSize.height - 40
            put(line(d.headerLeft, size: 8.5, gray: true), x: margin, baseline: headerY, ctx)
            putRight(line(d.headerRight, size: 8.5, gray: true), right: pageSize.width - margin, baseline: headerY, ctx)
            ctx.setStrokeColor(gray: 0.75, alpha: 1)
            ctx.setLineWidth(0.5)
            ctx.stroke(CGRect(x: margin, y: headerY - 8, width: contentWidth, height: 0))

            let topY = pageSize.height - top
            if let entry = page.continues {
                put(line("(entry #\(entry) continued)", size: 8.5, gray: true), x: margin, baseline: topY - 9, ctx)
            }
            for placed in page.rows {
                let rowTop = topY - placed.y
                switch placed.row.content {
                case .line(let line, let ascent):
                    put(line, x: margin + placed.row.indent, baseline: rowTop - ascent, ctx)
                case .image(let image, let size):
                    ctx.draw(image, in: CGRect(x: margin + placed.row.indent, y: rowTop - size.height - 2, width: size.width, height: size.height))
                }
            }

            let footerY = CGFloat(34)
            ctx.stroke(CGRect(x: margin, y: footerY + 14, width: contentWidth, height: 0))
            put(line(d.bates(index), size: 9, bold: true), x: margin, baseline: footerY, ctx)
            let pageLine = line("Page \(index + 1) of \(total)", size: 9)
            put(pageLine, x: (pageSize.width - width(pageLine)) / 2, baseline: footerY, ctx)
            putRight(line(d.footerRight, size: 8.5, gray: true), right: pageSize.width - margin, baseline: footerY, ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        try FileManager.default.moveItem(at: partial, to: url)
    }

    static func width(_ line: CTLine) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    static func put(_ line: CTLine, x: CGFloat, baseline: CGFloat, _ ctx: CGContext) {
        ctx.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(line, ctx)
    }

    static func putRight(_ line: CTLine, right: CGFloat, baseline: CGFloat, _ ctx: CGContext) {
        put(line, x: right - width(line), baseline: baseline, ctx)
    }
}
