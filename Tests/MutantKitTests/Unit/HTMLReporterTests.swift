import Foundation
import MutationModel
@testable import Reporting
import Testing

/// The HTML reporter renders into a self-contained file the user can open on a
/// plane. That means every byte originates in their own source — including
/// `</script>`, `<img onerror=…>`, and anything else a malicious or accidental
/// payload can produce. Unconditional escaping is the only defence, and this
/// suite holds it.
@Suite("HTML reporter")
struct HTMLReporterTests {
    /// A surviving mutant whose source diff contains an inline `<script>` tag.
    /// The naive failure is to drop the diff verbatim into a `<pre>`, where it
    /// either breaks out of the element or, in some viewers, executes.
    @Test("A diff containing </script> is escaped, never spliced")
    func scriptTagIsEscaped() throws {
        let point = try makeAnchoredPoint()
        let plan = makePlan(mutations: [point])
        let results = [
            makeResult(
                point: point,
                outcome: .survived,
                evidence: makeEvidence(diff: """
                --- a/Sources/Foo.swift
                +++ b/Sources/Foo.swift
                @@ -1,1 +1,1 @@
                -let payload = "safe"
                +let payload = "</script><script>alert(1)</script>"
                """),
                diagnosis: "no test covered this mutant"
            )
        ]
        let report = makeReport(plan: plan, results: results)

        let html = try HTMLReporter().render(report)

        // The literal sequence that would terminate a script context must not
        // appear outside escaping. The raw string `<\/script>` would still be
        // wrong inside an attribute; the entities are the only safe form.
        #expect(!html.contains("</script><script>"))
        #expect(html.contains("&lt;/script&gt;"))
    }

    /// A diff carrying the full XSS starter pack — tag open, tag close, both
    /// quote flavors, and an ampersand — has to round-trip with every byte
    /// escaped exactly once. Missing one of the five is the bug; double-escaping
    /// the ampersand produces `&amp;lt;` and is what the "must replace & first"
    /// rule exists to prevent.
    @Test("Every HTML-significant character is escaped exactly once")
    func everySignificantCharacterIsEscaped() throws {
        let payload = #"<a href="x">O'Reilly & "B"</a>"#
        let escaped = payload.htmlEscaped

        #expect(escaped == "&lt;a href=&quot;x&quot;&gt;O&#39;Reilly &amp; &quot;B&quot;&lt;/a&gt;")
        #expect(!escaped.contains("<") || escaped.contains("&lt;"))
        #expect(!escaped.contains(">") || escaped.contains("&gt;"))
        // No double-escaping: the ampersand entity does not contain another.
        #expect(!escaped.contains("&amp;lt;"))
        #expect(!escaped.contains("&amp;#"))
        #expect(!escaped.contains("&amp;quot;"))
        #expect(!escaped.contains("&amp;amp;"))
    }

    @Test("An empty string escapes to itself")
    func emptyStringEscapesToItself() {
        #expect("".htmlEscaped == "")
    }

    @Test("Plain ASCII without HTML-significant characters escapes to itself")
    func plainASCIIEscapesToItself() {
        // `->` would be escaped as `-&gt;`, so use a payload with none of the
        // five significant characters (&, <, >, ", ').
        #expect("struct Foo { func bar() returning Int { 42 } }".htmlEscaped
            == "struct Foo { func bar() returning Int { 42 } }")
    }

    /// Unicode and emoji are not HTML-significant and must pass through
    /// unchanged. The escaping function is not a sanitiser for arbitrary input.
    @Test("Unicode and emoji pass through unchanged")
    func unicodePassesThrough() {
        let text = "変異テスト 🧬 ＡＢＣ café"
        #expect(text.htmlEscaped == text)
    }

    /// A survivor's diagnosis also comes from outside the tool, and goes into a
    /// `<p>` element. The same rule applies: never splice raw text.
    @Test("A survivor's diagnosis is escaped")
    func diagnosisIsEscaped() throws {
        let point = try makeAnchoredPoint()
        let plan = makePlan(mutations: [point])
        let results = [
            makeResult(
                point: point,
                outcome: .survived,
                diagnosis: #"break out: <img src=x onerror="alert(1)">"#
            )
        ]
        let report = makeReport(plan: plan, results: results)

        let html = try HTMLReporter().render(report)

        #expect(!html.contains(#"<img src=x onerror="alert(1)">"#))
        #expect(html.contains("&lt;img"))
    }

    /// The plan ID and project root appear in headings and code elements. A
    /// hostile project name containing `<` could break the heading markup.
    @Test("Plan metadata is escaped in headings")
    func metadataIsEscaped() throws {
        let plan = makePlan(mutations: [])
        let hostile = RunReport(
            planID: "plan_<script>",
            startedAt: Date(timeIntervalSince1970: 0),
            finishedAt: Date(timeIntervalSince1970: 1),
            projectRoot: "/tmp/<b>bold</b>",
            toolchain: plan.toolchain,
            baseline: makeBaseline(),
            ledger: makeLedger([]),
            integrity: IntegrityChecker.check(plan: plan, ledger: makeLedger([]), baselinePassed: true)
        )

        let html = try HTMLReporter().render(hostile)

        #expect(!html.contains("plan_<script>"))
        #expect(html.contains("plan_&lt;script&gt;"))
        #expect(!html.contains("/tmp/<b>bold</b>"))
        #expect(html.contains("/tmp/&lt;b&gt;bold&lt;/b&gt;"))
    }

    @Test("The report is a complete HTML document")
    func reportIsCompleteDocument() throws {
        let point = try makeAnchoredPoint()
        let plan = makePlan(mutations: [point])
        let report = makeReport(plan: plan, results: [makeResult(point: point, outcome: .killedByAssertion)])

        let html = try HTMLReporter().render(report)

        #expect(html.hasPrefix("<!DOCTYPE html>"))
        #expect(html.hasSuffix("</html>\n") || html.hasSuffix("</html>"))
        #expect(html.contains("<html"))
        #expect(html.contains("<body"))
    }
}

private extension MutationEvidence {
    /// A real diff, supplied by the test, that exercises a specific payload.
    init(diff: String) {
        self.init(
            sourceBeforeHash: ContentHash.of("before"),
            sourceAfterHash: ContentHash.of("after"),
            sourceDiff: diff,
            buildProductHash: ContentHash.of("mutant"),
            applicationEvidence: .isolated(.buildProductDiffersFromBaseline(
                mutantHash: ContentHash.of("mutant"),
                baselineHash: ContentHash.of("baseline")
            ))
        )
    }
}

private func makeEvidence(diff: String) -> MutationEvidence { MutationEvidence(diff: diff) }
