import CoreGraphics
import CoreText
import Foundation
import RewindCore

/// Core Graphics + Core Text drawing of an `Invoice`: US Letter, vector text, black and greys. One line
/// item (the period at the rate), then the day-by-day hours it came from; long periods run over pages.
public enum InvoicePDF {
    static let pageW: CGFloat = 612, pageH: CGFloat = 792
    static let margin: CGFloat = 60, width: CGFloat = 612 - 2 * 60
    static let contentBottom: CGFloat = 716

    /// Writes `folder/<number>.pdf` and returns its URL.
    @discardableResult
    public static func write(_ invoice: Invoice, to folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: invoice.fileName)
        try render(invoice).data.write(to: url, options: .atomic)
        return url
    }

    public static func render(_ inv: Invoice) -> (data: Data, pages: Int) {
        let f = Fonts()
        let pages = paginate(blocks(inv, f))
        let out = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: pageW, height: pageH)
        let info: [CFString: Any] = [kCGPDFContextTitle: "Invoice \(inv.number)", kCGPDFContextCreator: "Transmute",
                                     kCGPDFContextAuthor: inv.fromName]
        let ctx = CGContext(consumer: CGDataConsumer(data: out as CFMutableData)!, mediaBox: &box, info as CFDictionary)!
        let c = Canvas(ctx: ctx, f: f)
        for (i, page) in pages.enumerated() {
            ctx.beginPDFPage(nil)
            ctx.textMatrix = .identity
            if i > 0 {
                c.text("Invoice \(inv.number) · \(inv.fromName) · continued", f.small, x: 0, base: margin, gray: 0.45)
                c.rule(margin + 6, gray: 0.6, weight: 0.5)
            }
            for (b, y) in page { b.draw(c, y) }
            c.rule(740, gray: 0.6, weight: 0.5)
            c.text("Hours from Rewind (\(basisName(inv.basis))), rounded to 0.01 h per day.", f.small, x: 0, base: 752, gray: 0.45)
            c.text("Page \(i + 1) of \(pages.count)", f.small, x: width, base: 752, right: true, gray: 0.45)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return (out as Data, pages.count)
    }

    static func basisName(_ raw: String) -> String {
        (InvoiceSettings.Basis(rawValue: raw) ?? .work).title.lowercased()
    }

    // MARK: - Layout

    struct Block {
        var height: CGFloat
        /// Free space needed below it on the same page (keeps a heading with its first rows).
        var keep: CGFloat = 0
        /// Redrawn at the top of a continuation page when the block after it moves there.
        var repeats = false
        var draw: (Canvas, CGFloat) -> Void
    }

    static func paginate(_ blocks: [Block]) -> [[(Block, CGFloat)]] {
        var pages: [[(Block, CGFloat)]] = [[]]
        var y = margin
        var header: Block?
        for b in blocks {
            if y + b.height + b.keep > contentBottom, !pages[pages.count - 1].isEmpty {
                pages.append([])
                y = margin + 20
                if let h = header { pages[pages.count - 1].append((h, y)); y += h.height }
            }
            pages[pages.count - 1].append((b, y))
            y += b.height
            if b.repeats { header = b }
        }
        return pages
    }

    static let colHours: CGFloat = 352, colRate: CGFloat = 420, colAmount: CGFloat = 492

    static func blocks(_ inv: Invoice, _ f: Fonts) -> [Block] {
        var out: [Block] = []

        // Title row: INVOICE · number / issued / period.
        out.append(Block(height: 70) { c, y in
            c.text("INVOICE", f.title, x: 0, base: y + 26, kern: 1.5)
            c.text(inv.number, f.heading, x: c.width, base: y + 12, right: true)
            c.text("Issued \(Invoice.longDate(inv.issued))", f.regular, x: c.width, base: y + 28, right: true, gray: 0.35)
            c.text(Invoice.periodTitle(inv.period), f.regular, x: c.width, base: y + 42, right: true, gray: 0.35)
            c.rule(y + 60, weight: 1)
        })

        // From / Bill to.
        let from = party(inv.fromName, inv.fromAddress, inv.fromEmail), to = party(inv.clientName, inv.clientAddress, inv.clientEmail)
        let partyLines = max(from.count, to.count)
        out.append(Block(height: CGFloat(28 + partyLines * 13 + 22)) { c, y in
            c.text("FROM", f.label, x: 0, base: y + 8, gray: 0.45, kern: 0.8)
            c.text("BILL TO", f.label, x: c.width / 2, base: y + 8, gray: 0.45, kern: 0.8)
            for (i, l) in from.enumerated() { c.text(l, i == 0 ? f.bold : f.regular, x: 0, base: y + 26 + CGFloat(i) * 13, maxWidth: c.width / 2 - 12) }
            for (i, l) in to.enumerated() { c.text(l, i == 0 ? f.bold : f.regular, x: c.width / 2, base: y + 26 + CGFloat(i) * 13, maxWidth: c.width / 2) }
        })

        // The line item.
        out.append(Block(height: 20, keep: 60) { c, y in
            c.text("DESCRIPTION", f.label, x: 0, base: y + 10, gray: 0.45, kern: 0.8)
            c.text("HOURS", f.label, x: colHours, base: y + 10, right: true, gray: 0.45, kern: 0.8)
            c.text("RATE", f.label, x: colRate, base: y + 10, right: true, gray: 0.45, kern: 0.8)
            c.text("AMOUNT", f.label, x: colAmount, base: y + 10, right: true, gray: 0.45, kern: 0.8)
            c.rule(y + 16, weight: 0.75)
        })
        out.append(Block(height: 26) { c, y in
            c.text(inv.title, f.regular, x: 0, base: y + 16, maxWidth: colHours - 60)
            c.text(inv.hours, f.regular, x: colHours, base: y + 16, right: true)
            c.text(inv.rate, f.regular, x: colRate, base: y + 16, right: true)
            c.text(inv.amount, f.regular, x: colAmount, base: y + 16, right: true)
            c.rule(y + 24, gray: 0.6, weight: 0.5)
        })
        out.append(Block(height: 54) { c, y in
            c.text("Total (\(inv.currency))", f.heading, x: colRate - 24, base: y + 22, right: true)
            c.text(inv.amount, f.total, x: colAmount, base: y + 22, right: true)
            if !inv.terms.isEmpty { c.text(inv.terms, f.regular, x: 0, base: y + 22, maxWidth: colHours - 40, gray: 0.35) }
        })

        // The hours behind it.
        let dayRow: CGFloat = 15
        out.append(Block(height: 22, keep: dayRow * 3, repeats: true) { c, y in
            c.text("DATE", f.label, x: 0, base: y + 12, gray: 0.45, kern: 0.8)
            c.text("HOURS", f.label, x: 180, base: y + 12, right: true, gray: 0.45, kern: 0.8)
            c.rule(y + 18, weight: 0.75)
        })
        for d in inv.days {
            out.append(Block(height: dayRow) { c, y in
                c.text(Invoice.dayLabel(d.date), f.regular, x: 0, base: y + 11)
                c.text(ExportPeriodData.hours(d.hundredths), f.regular, x: 180, base: y + 11, right: true)
            })
        }
        out.append(Block(height: 24) { c, y in
            c.rule(y + 4, gray: 0.6, weight: 0.5)
            c.text("\(inv.days.count) day\(inv.days.count == 1 ? "" : "s")", f.regular, x: 0, base: y + 18, gray: 0.35)
            c.text(inv.hours, f.bold, x: 180, base: y + 18, right: true)
        })
        return out
    }

    /// Name, then the address lines, then the email — blanks dropped.
    static func party(_ name: String, _ address: String, _ email: String) -> [String] {
        ([name] + address.components(separatedBy: .newlines) + [email])
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // MARK: - Drawing primitives (top-down coordinates, x relative to the left margin)

    struct Fonts {
        let title = font("HelveticaNeue-Bold", 26)
        let total = font("HelveticaNeue-Bold", 14)
        let heading = font("HelveticaNeue-Medium", 11)
        let bold = font("HelveticaNeue-Bold", 10)
        let regular = font("HelveticaNeue", 10)
        let label = font("HelveticaNeue-Medium", 7)
        let small = font("HelveticaNeue", 7.5)
        static func font(_ name: String, _ size: CGFloat) -> CTFont { CTFontCreateWithName(name as CFString, size, nil) }
    }

    struct Canvas {
        let ctx: CGContext
        let f: Fonts
        var width: CGFloat { InvoicePDF.width }

        static func attributed(_ s: String, _ font: CTFont, gray: CGFloat, kern: CGFloat) -> NSAttributedString {
            NSAttributedString(string: s, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: gray, alpha: 1),
                NSAttributedString.Key(kCTKernAttributeName as String): kern,
            ])
        }

        func text(_ s: String, _ font: CTFont, x: CGFloat, base: CGFloat, right: Bool = false, maxWidth: CGFloat? = nil,
                  gray: CGFloat = 0, kern: CGFloat = 0) {
            var line = CTLineCreateWithAttributedString(Self.attributed(s, font, gray: gray, kern: kern))
            if let maxWidth, CTLineGetTypographicBounds(line, nil, nil, nil) > maxWidth {
                let ellipsis = CTLineCreateWithAttributedString(Self.attributed("…", font, gray: gray, kern: 0))
                line = CTLineCreateTruncatedLine(line, Double(maxWidth), .end, ellipsis) ?? line
            }
            let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            ctx.textPosition = CGPoint(x: margin + (right ? x - w : x), y: pageH - base)
            CTLineDraw(line, ctx)
        }

        func rule(_ y: CGFloat, gray: CGFloat = 0, weight: CGFloat) {
            ctx.setStrokeColor(CGColor(gray: gray, alpha: 1))
            ctx.setLineWidth(weight)
            ctx.strokeLineSegments(between: [CGPoint(x: margin, y: pageH - y), CGPoint(x: margin + width, y: pageH - y)])
        }
    }
}
