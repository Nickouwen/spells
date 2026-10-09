import CoreGraphics
import CoreText
import Foundation

/// Core Graphics + Core Text drawing of `ExportPDF.Document`: US Letter, vector text, black and greys only.
/// Layout is a list of fixed-height blocks; pagination is computed (continuation pages repeat the
/// running header and the current table's column header), then each page is drawn with its footer.
enum ExportPDFRender {
    static let pageW: CGFloat = 612, pageH: CGFloat = 792
    static let margin: CGFloat = 54, width: CGFloat = 612 - 2 * 54
    static let contentBottom: CGFloat = 728
    static let continuationTop: CGFloat = margin + 26

    struct Block {
        var height: CGFloat
        /// Extra free space required below this block on the same page (keeps headings with rows).
        var keep: CGFloat = 0
        var newPage = false
        /// Dropped instead of drawn when it would land at the top of a page.
        var spacer = false
        /// Column header to redraw when this block starts a continuation page.
        var header: Int?
        var draw: (Canvas, CGFloat) -> Void = { _, _ in }
    }

    /// Places blocks on pages: [[(block, top)]].
    static func paginate(_ blocks: [Block], headers: [Block]) -> [[(Block, CGFloat)]] {
        var pages: [[(Block, CGFloat)]] = [[]]
        var y = margin
        for b in blocks {
            if (b.newPage && !pages[pages.count - 1].isEmpty) || y + b.height + b.keep > contentBottom {
                if b.spacer { continue }
                pages.append([])
                y = continuationTop
                if let h = b.header {
                    pages[pages.count - 1].append((headers[h], y))
                    y += headers[h].height
                }
            }
            pages[pages.count - 1].append((b, y))
            y += b.height
        }
        return pages
    }

    static func render(_ doc: ExportPDF.Document) -> (Data, Int) {
        let canvasFonts = Fonts()
        let (blocks, headers) = layout(doc, canvasFonts)
        let pages = paginate(blocks, headers: headers)

        let out = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: pageW, height: pageH)
        let info: [CFString: Any] = [kCGPDFContextTitle: "Timesheet \(doc.data.period)", kCGPDFContextCreator: "hours",
                                     kCGPDFContextAuthor: doc.name]
        let ctx = CGContext(consumer: CGDataConsumer(data: out as CFMutableData)!, mediaBox: &box, info as CFDictionary)!
        let canvas = Canvas(ctx: ctx, f: canvasFonts)
        for (i, page) in pages.enumerated() {
            ctx.beginPDFPage(nil)
            ctx.textMatrix = .identity
            if i > 0 { runningHeader(doc, canvas) }
            for (b, y) in page { b.draw(canvas, y) }
            footer(doc, canvas, page: i + 1, of: pages.count)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return (out as Data, pages.count)
    }

    // MARK: - Content

    // Timesheet columns: date | project | activity | hours | day total.
    static let colProject: CGFloat = 76, colActivity: CGFloat = 206, colHours: CGFloat = 448

    static func layout(_ doc: ExportPDF.Document, _ f: Fonts) -> ([Block], [Block]) {
        let data = doc.data
        var blocks: [Block] = [], headers: [Block] = []
        let hours = { (h: Int64) in ExportPeriodData.hours(h) }

        blocks.append(titleBlock(doc, f))

        // Day × project table.
        blocks.append(section("Billable time by day", right: "hours, rounded per entry to 0.01 h", f))
        headers.append(columnHeader([("Date", 0, false), ("Project", colProject, false), ("Activity", colActivity, false),
                                     ("Hours", colHours, true), ("Day total", width, true)], f))
        let dayHeader = headers.count - 1
        blocks.append(headers[dayHeader])
        let groups = Dictionary(grouping: data.rows, by: \.date)
        if groups.isEmpty { blocks.append(note("No billable time in this period.", f)) }
        for date in groups.keys.sorted() {
            let rows = groups[date]!
            let dayTotal = rows.reduce(0) { $0 + $1.hundredths }
            for (i, r) in rows.enumerated() {
                let first = i == 0, last = i == rows.count - 1
                blocks.append(Block(height: 14, keep: first ? CGFloat(min(rows.count - 1, 4)) * 14 : 0, header: dayHeader) { c, y in
                    let base = y + 10
                    if first {
                        c.text(dayLabel(date), c.f.medium, x: 0, base: base)
                        c.text(hours(dayTotal), c.f.medium, x: width, base: base, right: true)
                    }
                    c.text(r.project, c.f.regular, x: colProject, base: base, maxWidth: colActivity - colProject - 8)
                    c.text(r.summary, c.f.small, x: colActivity, base: base, maxWidth: colHours - 48 - colActivity - 8, gray: 0.35)
                    c.text(hours(r.hundredths), c.f.regular, x: colHours, base: base, right: true)
                    if last { c.rule(y + 14, gray: 0.78, weight: 0.5) }
                })
            }
        }
        let entries = data.rows.count, days = groups.count
        blocks.append(Block(height: 26) { c, y in
            c.rule(y + 1, weight: 1.2)
            c.text("Period total", c.f.bold, x: 0, base: y + 17)
            c.text("\(days) day\(days == 1 ? "" : "s") · \(entries) entr\(entries == 1 ? "y" : "ies")", c.f.small,
                   x: colProject, base: y + 17, gray: 0.35)
            c.text("\(hours(data.totalHundredths)) h", c.f.bold, x: width, base: y + 17, right: true)
        })

        // Project summary strip.
        let projects = ExportPDF.projects(data)
        if !projects.isEmpty {
            blocks.append(Block(height: 22, spacer: true))
            blocks.append(section("Summary by project", right: nil, f))
            headers.append(columnHeader([("Project", 0, false), ("Days", 200, true), ("Share", 226, false),
                                         ("Hours", width, true)], f))
            blocks.append(headers[headers.count - 1])
            let total = max(data.totalHundredths, 1)
            for p in projects {
                let share = Double(p.hundredths) / Double(total)
                blocks.append(Block(height: 16, header: headers.count - 1) { c, y in
                    let base = y + 11
                    c.text(p.project, c.f.medium, x: 0, base: base, maxWidth: 170)
                    c.text("\(p.days)", c.f.regular, x: 200, base: base, right: true)
                    c.bar(x: 226, y: y + 5, width: 170, height: 6, fraction: share)
                    c.text(String(format: "%.0f%%", share * 100), c.f.small, x: 430, base: base, right: true, gray: 0.35)
                    c.text(hours(p.hundredths), c.f.regular, x: width, base: base, right: true)
                    c.rule(y + 16, gray: 0.85, weight: 0.4)
                })
            }
            blocks.append(Block(height: 20) { c, y in
                c.text("Total", c.f.bold, x: 0, base: y + 13)
                c.text("\(hours(data.totalHundredths)) h", c.f.bold, x: width, base: y + 13, right: true)
            })

            // Category breakdown: each project's billed total split by category.
            blocks.append(Block(height: 22, spacer: true))
            // Keep a short table in one piece rather than orphaning a few rows on the next page.
            var catSection = section("Billable time by category", right: "project totals split in proportion to time", f)
            let catHeight = 18 + 14 * CGFloat(projects.reduce(0) { $0 + $1.categories.count })
            if catHeight < 360 { catSection.keep = catHeight }
            blocks.append(catSection)
            headers.append(columnHeader([("Project", 0, false), ("Category", colProject + 60, false), ("Share", 400, true),
                                         ("Hours", colHours, true), ("Total", width, true)], f))
            let catHeader = headers.count - 1
            blocks.append(headers[catHeader])
            for p in projects {
                let split = ExportPDF.allocate(p.hundredths, p.categories.map(\.ms))
                for (i, cat) in p.categories.enumerated() {
                    let first = i == 0, last = i == p.categories.count - 1
                    let share = p.ms > 0 ? Double(cat.ms) / Double(p.ms) : 0
                    blocks.append(Block(height: 14, keep: first ? CGFloat(min(p.categories.count - 1, 4)) * 14 : 0,
                                        header: catHeader) { c, y in
                        let base = y + 10
                        if first {
                            c.text(p.project, c.f.medium, x: 0, base: base, maxWidth: colProject + 52)
                            c.text(hours(p.hundredths), c.f.medium, x: width, base: base, right: true)
                        }
                        c.text(cat.name, c.f.regular, x: colProject + 60, base: base, maxWidth: 200)
                        c.text(String(format: "%.0f%%", share * 100), c.f.small, x: 400, base: base, right: true, gray: 0.35)
                        c.text(hours(split[i]), c.f.regular, x: colHours, base: base, right: true)
                        if last { c.rule(y + 14, gray: 0.78, weight: 0.5) }
                    })
                }
            }
        }

        if doc.mode == .audit { audit(doc, f, &blocks, &headers) }
        return (blocks, headers)
    }

    static func audit(_ doc: ExportPDF.Document, _ f: Fonts, _ blocks: inout [Block], _ headers: inout [Block]) {
        let data = doc.data, m = data.metrics
        var first = section("Audit appendix", right: "disclosure \(doc.disclosure.rawValue)", f)
        first.newPage = true
        blocks.append(first)
        let manual = ExportPDF.manualMs(data)
        let late = doc.edits.filter { $0.createdMs >= doc.periodEndMs }.count
        let disclosure = switch doc.disclosure {
        case .L0: "L0: app names and categories; titles, URLs and edit details withheld"
        case .L1: "L1: L0 plus URL hosts; titles and edit details withheld"
        case .L2: "L2: full detail, including titles and edit details"
        }
        let facts: [(String, String)] = [
            ("Disclosure", disclosure),
            ("Billable definition", ExportPeriodData.definitionVersion),
            ("Tracked time", hm(m.trackedMs)),
            ("Work time", hm(m.workMs)),
            ("Billable, unrounded", "\(hm(m.billableMs)) (billed: \(ExportPeriodData.hours(data.totalHundredths)) h, Σ of rounded entries)"),
            ("Work without a project", "\(hm(m.unassignedWorkMs)) (not billed)"),
            ("Manual entries (billable)", m.billableMs > 0
                ? "\(hm(manual)) · \(String(format: "%.1f", Double(manual) * 100 / Double(m.billableMs)))% of billable"
                : hm(manual)),
            ("Edits touching the period", "\(doc.edits.count), of which \(late) recorded after the period ended"),
        ]
        for (k, v) in facts {
            blocks.append(Block(height: 14) { c, y in
                c.text(k, c.f.small, x: 0, base: y + 10, gray: 0.35)
                c.text(v, c.f.regular, x: 150, base: y + 10, maxWidth: width - 150)
            })
        }

        blocks.append(Block(height: 20, spacer: true))
        blocks.append(section("Edits", right: "† recorded after the period ended", f))
        headers.append(columnHeader([("Seq", 0, false), ("Recorded", 40, false), ("Op", 132, false),
                                     ("Applies to", 176, false), ("Detail", 300, false)], f))
        blocks.append(headers[headers.count - 1])
        if doc.edits.isEmpty { blocks.append(note("No edits touch this period.", f)) }
        for e in doc.edits {
            let detail = ExportPDF.editDetail(e, data, doc.disclosure)
            let late = e.createdMs >= doc.periodEndMs
            let applies = e.hiMs > e.loMs ? "\(stamp(e.loMs, doc.tz, "MMM d HH:mm"))–\(stamp(e.hiMs, doc.tz, "HH:mm"))" : "—"
            blocks.append(Block(height: 14, header: headers.count - 1) { c, y in
                let base = y + 10
                c.text("#\(e.seq)", c.f.small, x: 0, base: base)
                c.text(stamp(e.createdMs, doc.tz, "yyyy-MM-dd HH:mm") + (late ? " †" : ""), c.f.small, x: 40, base: base)
                c.text(e.op.rawValue, c.f.small, x: 132, base: base)
                c.text(applies, c.f.small, x: 176, base: base)
                c.text(detail, c.f.small, x: 300, base: base, maxWidth: width - 300)
                c.rule(y + 14, gray: 0.88, weight: 0.4)
            })
        }

        blocks.append(Block(height: 20, spacer: true))
        blocks.append(section("Anchors", right: "RFC 3161 time-stamps of the chain head", f))
        headers.append(columnHeader([("ID", 0, false), ("Authority", 40, false), ("Requested (UTC)", 120, false),
                                     ("Time-stamped (UTC)", 230, false), ("Head", 340, false)], f))
        blocks.append(headers[headers.count - 1])
        if doc.anchors.isEmpty { blocks.append(note("No anchors from this period yet. Run spellsctl anchor, then re-export.", f)) }
        for a in doc.anchors {
            blocks.append(Block(height: 14, header: headers.count - 1) { c, y in
                let base = y + 10
                c.text("#\(a.id)", c.f.small, x: 0, base: base)
                c.text(a.tsa ?? a.method, c.f.small, x: 40, base: base)
                c.text(utc(a.requestedMs), c.f.small, x: 120, base: base)
                c.text(a.genTimeMs.map(utc) ?? "pending", c.f.small, x: 230, base: base)
                c.text("#\(a.headSeq) \(exportHex(a.headHash).prefix(16))", c.f.mono, x: 340, base: base)
                c.rule(y + 14, gray: 0.88, weight: 0.4)
            })
        }
    }

    static func titleBlock(_ doc: ExportPDF.Document, _ f: Fonts) -> Block {
        let witnessW = width - 16
        let witnessH = Canvas.wrappedHeight(doc.witness, f.mono, width: witnessW)
        let boxTop: CGFloat = 104, boxH = 22 + witnessH + 7
        return Block(height: boxTop + boxH + 22) { c, y in
            c.text("Timesheet", c.f.title, x: 0, base: y + 24)
            c.text(periodTitle(doc.data.period), c.f.heading, x: width, base: y + 13, right: true)
            c.text("\(ExportPeriodData.hours(doc.data.totalHundredths)) h billable", c.f.regular, x: width, base: y + 28,
                   right: true, gray: 0.35)
            c.rule(y + 38, weight: 1.2)
            let client = ExportPDF.client(doc.data)
            let p = doc.data.period
            let cells: [(String, String, Bool)] = [
                ("Consultant", doc.name.isEmpty ? "—" : doc.name, false),
                ("Period", "\(p.from) – \(p.through) · \(p.days.count) days", false),
                ("Generated", stamp(doc.generatedMs, doc.tz, "yyyy-MM-dd HH:mm zzz"), false),
                ("Client", client.isEmpty ? "—" : client, false),
                ("Time zone", "\(doc.tz.identifier) · day starts \(String(format: "%02d", Hours.defaultDayStartHour)):00", false),
                ("Chain head", "#\(doc.headSeq) \(exportHex(doc.headHash).prefix(16))", true),
            ]
            for (i, cell) in cells.enumerated() {
                let x = CGFloat(i % 3) * (width / 3), top = y + 56 + CGFloat(i / 3) * 26
                c.text(cell.0.uppercased(), c.f.label, x: x, base: top, gray: 0.4, kern: 0.6)
                c.text(cell.1, cell.2 ? c.f.monoValue : c.f.regular, x: x, base: top + 11, maxWidth: width / 3 - 10)
            }
            c.box(top: y + boxTop, height: boxH)
            c.text("INVOICE WITNESS — PASTE INTO THE INVOICE MEMO", c.f.label, x: 8, base: y + boxTop + 12, gray: 0.4, kern: 0.6)
            c.wrapped(doc.witness, c.f.mono, x: 8, top: y + boxTop + 17, width: witnessW, height: witnessH)
        }
    }

    static func section(_ title: String, right: String?, _ f: Fonts) -> Block {
        Block(height: 22, keep: 34) { c, y in
            c.text(title, c.f.heading, x: 0, base: y + 13)
            if let right { c.text(right, c.f.small, x: width, base: y + 13, right: true, gray: 0.45) }
        }
    }

    /// (title, x, right-aligned at x).
    static func columnHeader(_ cols: [(String, CGFloat, Bool)], _ f: Fonts) -> Block {
        Block(height: 18) { c, y in
            for (t, x, right) in cols { c.text(t.uppercased(), c.f.label, x: x, base: y + 11, right: right, gray: 0.4, kern: 0.6) }
            c.rule(y + 16, weight: 0.75)
        }
    }

    static func note(_ s: String, _ f: Fonts) -> Block {
        Block(height: 16) { c, y in c.text(s, c.f.small, x: 0, base: y + 11, maxWidth: width, gray: 0.4) }
    }

    static func runningHeader(_ doc: ExportPDF.Document, _ c: Canvas) {
        let left = ["Timesheet", doc.name, periodTitle(doc.data.period)].filter { !$0.isEmpty }.joined(separator: " · ")
        c.text(left, c.f.small, x: 0, base: margin + 8, gray: 0.4)
        c.text("continued", c.f.small, x: width, base: margin + 8, right: true, gray: 0.4)
        c.rule(margin + 13, gray: 0.6, weight: 0.5)
    }

    /// `Chain head #<seq> <hash[0:16]> · anchored <genTime> by <TSA> · timesheet.csv sha256:<16 hex> · page n/m`
    static func footerLine(_ doc: ExportPDF.Document) -> String {
        let anchored = doc.headAnchor.map { "anchored \(utc($0.genTimeMs!)) by \($0.tsa ?? $0.method)" } ?? "head not yet anchored"
        return "Chain head #\(doc.headSeq) \(exportHex(doc.headHash).prefix(16)) · \(anchored)"
            + " · timesheet.csv sha256:\(exportSHA256Hex(doc.data.timesheetCSV).prefix(16))"
    }

    static func footer(_ doc: ExportPDF.Document, _ c: Canvas, page: Int, of pages: Int) {
        c.rule(740, gray: 0.6, weight: 0.5)
        c.text(footerLine(doc) + " · page \(page)/\(pages)", c.f.footer, x: 0, base: 751, maxWidth: width)
        c.text("To verify: SHA-256 of timesheet.csv must begin with the digest above; in the audit bundle, "
               + "python3 verify.py <dir> checks the hash chain and its RFC 3161 time-stamps.",
               c.f.footer, x: 0, base: 761, maxWidth: width, gray: 0.4)
    }

    // MARK: - Formatting

    static func formatter(_ pattern: String, _ tz: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = pattern
        return f
    }

    static func stamp(_ ms: Int64, _ tz: TimeZone, _ pattern: String) -> String {
        formatter(pattern, tz).string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    /// `2026-10-04 08:12Z`.
    static func utc(_ ms: Int64) -> String { stamp(ms, .gmt, "yyyy-MM-dd HH:mm'Z'") }

    static func noon(_ d: LocalDate) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .gmt
        return cal.date(from: DateComponents(year: d.year, month: d.month, day: d.day, hour: 12))!
    }

    /// `Tue Sep 16`.
    static func dayLabel(_ d: LocalDate) -> String { formatter("EEE MMM d", .gmt).string(from: noon(d)) }

    /// `Sep 16–30, 2026` · `Sep 28 – Oct 3, 2026` · `Dec 28, 2026 – Jan 3, 2027`.
    static func periodTitle(_ p: ExportPeriod) -> String {
        let a = noon(p.from), b = noon(p.through)
        if p.from.year != p.through.year {
            return "\(formatter("MMM d, yyyy", .gmt).string(from: a)) – \(formatter("MMM d, yyyy", .gmt).string(from: b))"
        }
        if p.from.month != p.through.month {
            return "\(formatter("MMM d", .gmt).string(from: a)) – \(formatter("MMM d, yyyy", .gmt).string(from: b))"
        }
        if p.from == p.through { return formatter("MMM d, yyyy", .gmt).string(from: a) }
        return "\(formatter("MMM d", .gmt).string(from: a))–\(p.through.day), \(p.through.year)"
    }

    /// `12h 05m`.
    static func hm(_ ms: Int64) -> String {
        let m = (ms + 30_000) / 60_000
        return String(format: "%lldh %02lldm", m / 60, m % 60)
    }

    // MARK: - Drawing primitives (top-down coordinates, x relative to the left margin)

    struct Fonts {
        let title = font("HelveticaNeue-Bold", 24)
        let heading = font("HelveticaNeue-Medium", 11)
        let regular = font("HelveticaNeue", 8.5)
        let medium = font("HelveticaNeue-Medium", 8.5)
        let bold = font("HelveticaNeue-Bold", 9)
        let small = font("HelveticaNeue", 7.5)
        let label = font("HelveticaNeue-Medium", 6)
        let footer = font("HelveticaNeue", 6)
        let mono = font("Menlo-Regular", 6.5)
        let monoValue = font("Menlo-Regular", 7.5)

        static func font(_ name: String, _ size: CGFloat) -> CTFont { CTFontCreateWithName(name as CFString, size, nil) }
    }

    struct Canvas {
        let ctx: CGContext
        let f: Fonts

        static func attributed(_ s: String, _ font: CTFont, gray: CGFloat = 0, kern: CGFloat = 0) -> NSAttributedString {
            NSAttributedString(string: s, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: gray, alpha: 1),
                NSAttributedString.Key(kCTKernAttributeName as String): kern,
                // No "ff"/"fi" ligatures: hashes and digests must copy out of the PDF verbatim.
                NSAttributedString.Key(kCTLigatureAttributeName as String): 0,
            ])
        }

        func text(_ s: String, _ font: CTFont, x: CGFloat, base: CGFloat, right: Bool = false, maxWidth: CGFloat? = nil,
                  gray: CGFloat = 0, kern: CGFloat = 0) {
            var line = CTLineCreateWithAttributedString(Self.attributed(s, font, gray: gray, kern: kern))
            if let maxWidth, CTLineGetTypographicBounds(line, nil, nil, nil) > maxWidth {
                let ellipsis = CTLineCreateWithAttributedString(Self.attributed("…", font, gray: gray))
                line = CTLineCreateTruncatedLine(line, Double(maxWidth), .end, ellipsis) ?? line
            }
            let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            ctx.textPosition = CGPoint(x: margin + (right ? x - w : x), y: pageH - base)
            CTLineDraw(line, ctx)
        }

        static func wrappedHeight(_ s: String, _ font: CTFont, width: CGFloat) -> CGFloat {
            let setter = CTFramesetterCreateWithAttributedString(attributed(s, font))
            return ceil(CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil,
                                                                     CGSize(width: width, height: .greatestFiniteMagnitude), nil).height)
        }

        func wrapped(_ s: String, _ font: CTFont, x: CGFloat, top: CGFloat, width: CGFloat, height: CGFloat) {
            let setter = CTFramesetterCreateWithAttributedString(Self.attributed(s, font))
            let path = CGPath(rect: CGRect(x: margin + x, y: pageH - top - height, width: width, height: height), transform: nil)
            CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(), path, nil), ctx)
        }

        func rule(_ y: CGFloat, gray: CGFloat = 0, weight: CGFloat) {
            ctx.setStrokeColor(CGColor(gray: gray, alpha: 1))
            ctx.setLineWidth(weight)
            ctx.strokeLineSegments(between: [CGPoint(x: margin, y: pageH - y), CGPoint(x: margin + width, y: pageH - y)])
        }

        func box(top: CGFloat, height: CGFloat) {
            ctx.setStrokeColor(CGColor(gray: 0.55, alpha: 1))
            ctx.setLineWidth(0.5)
            ctx.stroke(CGRect(x: margin, y: pageH - top - height, width: width, height: height))
        }

        /// A share bar: light track, dark fill. Prints as two greys.
        func bar(x: CGFloat, y: CGFloat, width w: CGFloat, height h: CGFloat, fraction: Double) {
            let r = CGRect(x: margin + x, y: pageH - y - h, width: w, height: h)
            ctx.setFillColor(CGColor(gray: 0.9, alpha: 1))
            ctx.fill(r)
            ctx.setFillColor(CGColor(gray: 0.25, alpha: 1))
            ctx.fill(CGRect(x: r.minX, y: r.minY, width: w * CGFloat(min(max(fraction, 0), 1)), height: h))
        }
    }
}
