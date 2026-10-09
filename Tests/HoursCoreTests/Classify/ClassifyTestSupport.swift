@testable import HoursCore

/// Active tracked span fixture for classification tests.
func classifySpan(_ bundle: String? = "com.google.Chrome", app: String = "Google Chrome",
                  title: String? = nil, url: String? = nil, ms: Int64 = 1_000,
                  kind: SpanKind = .active, source: SpanSource = .tracked,
                  category: Int64? = nil, project: Int64? = nil) -> EffectiveSpan {
    EffectiveSpan(startMs: 0, endMs: ms, tzId: "UTC", kind: kind, bundleId: bundle, appName: app,
                  title: title, url: url, categoryOverride: category, projectOverride: project,
                  source: source, rawSeq: 1)
}

func seedClassifier(extra: [Rule] = []) -> Classifier {
    Classifier(categories: ClassifySeed.categories, rules: ClassifySeed.rules + extra, projects: ClassifySeed.projects)
}

extension Classifier {
    func category(_ span: EffectiveSpan) -> Int64? { classify(span).categoryId }
    func project(_ span: EffectiveSpan) -> Int64? { classify(span).projectId }
}
