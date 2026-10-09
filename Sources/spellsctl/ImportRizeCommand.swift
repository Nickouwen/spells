import Foundation
import HoursCore

/// `spellsctl import-rize --source <snapshot.json|api> [--dry-run] [--since YYYY-MM-DD]`
@MainActor func importRize() async throws {
    guard let source = options["--source"] else { die("import-rize: --source <snapshot.json|api> is required") }
    let since = options["--since"].map { s -> LocalDate in
        guard let p = ExportPeriod.parse("\(s)..\(s)", today: today) else { die("bad --since '\(s)' (YYYY-MM-DD)") }
        return p.from
    }
    let dryRun = flags.contains("--dry-run")

    let file: URL
    switch source {
    case "local":
        throw RizeImportError.noLocalHistory
    case "api":
        guard let key = ProcessInfo.processInfo.environment["RIZE_API_KEY"], !key.isEmpty else {
            die("--source api needs RIZE_API_KEY (create one in Rize → Settings → API)", 1)
        }
        let snap = try await RizeFetcher(apiKey: key) { FileHandle.standardError.write(Data("rize: \($0)\n".utf8)) }
            .fetch(since: since)
        let dir = paths.home.appending(path: "imports", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Date().ISO8601Format(.iso8601.year().month().day().dateSeparator(.omitted).time(includingFractionalSeconds: false).timeSeparator(.omitted))
        file = dir.appending(path: "rize-\(stamp).json")
        try snap.encoded().write(to: file)
        say("saved snapshot \(file.path) — pass it as --source to import exactly this data")
    default:
        file = URL(filePath: (source as NSString).expandingTildeInPath)
    }

    let (snap, sha) = try RizeSnapshot.load(file)
    let db = openDB()
    let importer = RizeImporter(db)
    let plan = try importer.plan(snap, since: since)
    let tz = snap.tz
    func h(_ ms: Int64) -> String { String(format: "%.1f h", Double(ms) / 3_600_000) }
    func day(_ ms: Int64) -> LocalDate { LocalDate.containing(ms: ms, in: tz) }

    say("Rize snapshot \(file.lastPathComponent)  sha256:\(sha.prefix(16))…  tz \(snap.timezone)  fetched \(snap.fetchedAt)")
    say("DB \(paths.db.path)")
    if let lo = plan.blocks.first?.loMs, let hi = plan.blocks.last?.hiMs {
        say("range \(day(lo))..\(day(hi - 1)) (Hours days, \(Hours.defaultDayStartHour):00 boundary)")
    }
    say("\(plan.events) Rize events → \(plan.sourceBlocks) blocks, \(h(plan.sourceMs))\(since.map { " since \($0)" } ?? "")"
        + (plan.idleMs > 0 ? "  (idle dropped: \(h(plan.idleMs)))" : ""))
    say("to import: \(plan.blocks.count) blocks, \(h(plan.totalMs))")
    say("skipped: already imported \(plan.alreadyImportedBlocks) blocks / \(h(plan.alreadyImportedMs)); "
        + "overlapping Hours-tracked \(plan.overlapBlocks) blocks / \(h(plan.overlapMs)); partly clipped \(plan.clippedBlocks)")

    var month: [String: Int64] = [:], cat: [String: Int64] = [:], proj: [String: Int64] = [:]
    var rize: [String: Int64] = [:], unmapped: [String: Int64] = [:]
    var noMatch: Int64 = 0
    let names = Dictionary(ClassifySeed.categories.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
    for b in plan.blocks {
        let d = day(b.loMs)
        month[String(format: "%04d-%02d", d.year, d.month), default: 0] += b.durationMs
        cat[b.categoryId.flatMap { names[$0] } ?? "Uncategorized", default: 0] += b.durationMs
        proj[b.project ?? "(no project)", default: 0] += b.durationMs
        if let k = b.rizeCategory {
            rize[k, default: 0] += b.durationMs
            if !RizeCategoryMap.map(k).mapped { unmapped[k, default: 0] += b.durationMs }
        } else {
            noMatch += b.durationMs
        }
    }
    func top(_ d: [String: Int64], _ n: Int = 12) -> [(String, Int64)] { d.sorted { $0.value > $1.value }.prefix(n).map { ($0.key, $0.value) } }
    say("per month:"); for (k, v) in month.sorted(by: { $0.key < $1.key }) { say("  \(k)  \(h(v))") }
    say("Hours categories:"); for (k, v) in top(cat) { say("  \(k.padding(toLength: 18, withPad: " ", startingAt: 0)) \(h(v))") }
    say("Rize → Hours:")
    for (k, v) in top(rize, 40) {
        let to = RizeCategoryMap.map(k)
        say("  \((plan.rizeCategoryNames[k] ?? k).padding(toLength: 20, withPad: " ", startingAt: 0)) → \(to.mapped ? (to.categoryId.flatMap { names[$0] } ?? "Uncategorized") : "UNMAPPED → Uncategorized")  \(h(v))")
    }
    say("unmapped Rize categories: " + (unmapped.isEmpty ? "none" : top(unmapped, 40).map { "\($0.0) \(h($0.1))" }.joined(separator: ", "))
        + (noMatch > 0 ? "; no Rize category found: \(h(noMatch))" : ""))
    let missing = try importer.missingProjects(plan)
    say("projects: " + (proj.count == 1 && proj["(no project)"] != nil ? "none in Rize"
        : top(proj).map { "\($0.0) \(h($0.1))\(missing.contains($0.0) ? " (NEW)" : "")" }.joined(separator: ", ")))

    let checked = plan.daily.filter { $0.rizeMs > 0 }
    if !checked.isEmpty {
        let close = checked.filter { abs($0.eventsMs - $0.rizeMs) * 20 <= $0.rizeMs }.count
        let ev = checked.reduce(0) { $0 + $1.eventsMs }, rz = checked.reduce(0) { $0 + $1.rizeMs }
        say("vs Rize day totals: events \(h(ev)) vs Rize tracked \(h(rz)) over \(checked.count) days; within 5%: \(close)")
        for d in checked.sorted(by: { abs($0.eventsMs - $0.rizeMs) > abs($1.eventsMs - $1.rizeMs) }).prefix(3) {
            say("  worst \(d.date): events \(h(d.eventsMs)) vs Rize \(h(d.rizeMs))")
        }
    }

    if dryRun { say("dry run: nothing written"); return }
    let r = try importer.apply(plan, snap: snap, sourceName: file.lastPathComponent, sha256: sha)
    say("wrote \(r.blocks) blocks, \(h(r.ms)) in \(r.groups.count) edit group(s) \(r.groups.map { "#\($0)" }.joined(separator: " "))"
        + (r.createdProjects.isEmpty ? "" : "; created projects: \(r.createdProjects.joined(separator: ", "))"))

    // Read back 3 sample days (largest, median, smallest Rize day) from the store vs Rize's own totals.
    let sample = checked.sorted { $0.rizeMs < $1.rizeMs }
    let picks = sample.isEmpty ? [] : Array(Set([sample.count - 1, sample.count / 2, 0])).sorted().map { sample[$0] }
    let buckets = Dictionary(snap.summaryBuckets.map { ($0.date, $0) }, uniquingKeysWith: { a, _ in a })
    for p in picks {
        guard let b = buckets[p.date] else { continue }
        let spans = try Store(db).effectiveSpans(rangeFrom: try rizeMs(b.startTime), to: try rizeMs(b.endTime))
        let imported = spans.filter { $0.source == .manual && $0.label?.hasPrefix("Rize · ") == true }.reduce(0) { $0 + $1.durationMs }
        let all = spans.filter { $0.kind == .active }.reduce(0) { $0 + $1.durationMs }
        say("check \(p.date): Rize \(h(p.rizeMs))  imported \(h(imported))  all Hours active \(h(all))")
    }
}

