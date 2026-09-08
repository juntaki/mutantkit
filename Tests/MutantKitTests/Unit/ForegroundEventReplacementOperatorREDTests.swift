import Foundation
import MutationModel
import SwiftFrontend
import Testing

/// RED tests for `apple.lifecycle.foreground-event-replacement`. Positive
/// scenarios prove discovery finds both directions (Variant A:
/// `didBecomeActive -> willEnterForeground`; Variant B: `willEnterForeground
/// -> didBecomeActive`) across the real shapes the task contract requires.
/// Negative scenarios prove the matcher is substantially narrower than "member
/// name matches" — see `ForegroundEventReplacementCompileViabilityAcceptanceTests`
/// for the direct `swiftc`/UIKit compile-safety proof these shapes are
/// grounded in.
@Suite("RED: Apple lifecycle foreground-event-replacement operator")
struct ForegroundEventReplacementOperatorREDTests {
    private let operatorID = "apple.lifecycle.foreground-event-replacement"

    // MARK: - Positive scenarios: Variant A (didBecomeActive -> willEnterForeground)

    @Test("Direct argument use of didBecomeActiveNotification produces the Variant A mutant")
    func directArgumentUseIsVariantA() throws {
        let source = """
        import UIKit

        final class LifecycleObserver {
            func register() {
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(didBecomeActive),
                    name: UIApplication.didBecomeActiveNotification,
                    object: nil
                )
            }
            @objc func didBecomeActive() {}
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.count == 1, "expected exactly one candidate, got \(points.map(\.originalText))")
        let point = try #require(points.first)
        #expect(point.originalText == "UIApplication.didBecomeActiveNotification")
        #expect(point.replacementText == "UIApplication.willEnterForegroundNotification")
    }

    @Test("An assigned notification name produces the Variant A mutant")
    func assignedNotificationNameIsVariantA() throws {
        let source = """
        import UIKit

        struct Constants {
            static let activationNotification = UIApplication.didBecomeActiveNotification
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.count == 1)
        let point = try #require(points.first)
        #expect(point.originalText == "UIApplication.didBecomeActiveNotification")
        #expect(point.replacementText == "UIApplication.willEnterForegroundNotification")
    }

    @Test("A multiline member access is still recognized as Variant A")
    func multilineMemberAccessIsVariantA() throws {
        let source = """
        import UIKit

        final class LifecycleObserver {
            func register() {
                let name = UIApplication
                    .didBecomeActiveNotification
                NotificationCenter.default.addObserver(self, selector: #selector(fire), name: name, object: nil)
            }
            @objc func fire() {}
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.count == 1)
        let point = try #require(points.first)
        #expect(point.replacementText.contains("willEnterForegroundNotification"))
    }

    // MARK: - Positive scenarios: Variant B (willEnterForeground -> didBecomeActive)

    @Test("Direct argument use of willEnterForegroundNotification produces the Variant B mutant")
    func directArgumentUseIsVariantB() throws {
        let source = """
        import UIKit

        final class LifecycleObserver {
            func register() {
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(willEnterForeground),
                    name: UIApplication.willEnterForegroundNotification,
                    object: nil
                )
            }
            @objc func willEnterForeground() {}
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.count == 1)
        let point = try #require(points.first)
        #expect(point.originalText == "UIApplication.willEnterForegroundNotification")
        #expect(point.replacementText == "UIApplication.didBecomeActiveNotification")
    }

    @Test("An array literal of notification names produces one candidate per matched element")
    func arrayLiteralProducesBothDirections() throws {
        let source = """
        import UIKit

        struct Constants {
            static let names: [Notification.Name] = [
                UIApplication.didBecomeActiveNotification,
                UIApplication.willEnterForegroundNotification
            ]
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.count == 2, "expected one candidate per array element, got \(points.map(\.originalText))")
        let originals = Set(points.map(\.originalText))
        #expect(originals == ["UIApplication.didBecomeActiveNotification", "UIApplication.willEnterForegroundNotification"])
    }

    @Test("A set literal of notification names produces one candidate per matched element")
    func setLiteralProducesBothDirections() throws {
        let source = """
        import UIKit

        struct Constants {
            static let names: Set<Notification.Name> = [
                UIApplication.didBecomeActiveNotification,
                UIApplication.willEnterForegroundNotification
            ]
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.count == 2)
    }

    // MARK: - Positive scenario: multiple constants / both intentionally registered

    @Test("Multiple lifecycle constants in one file each produce their own stable, direction-distinct candidate")
    func multipleConstantsInOneFile() throws {
        let source = """
        import UIKit

        final class DualLifecycleObserver {
            func register() {
                NotificationCenter.default.addObserver(self, selector: #selector(activate), name: UIApplication.didBecomeActiveNotification, object: nil)
                NotificationCenter.default.addObserver(self, selector: #selector(foreground), name: UIApplication.willEnterForegroundNotification, object: nil)
            }
            @objc func activate() {}
            @objc func foreground() {}
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.count == 2)
        // Stable mutation IDs distinguish the two directions: two different
        // MutationCandidates on the same file/declaration must not collide.
        let ids = Set(points.map(\.id))
        #expect(ids.count == 2, "each direction must get its own stable mutation ID")
    }

    @Test("Both constants intentionally registered together (compatibility shape) each remain independent candidates")
    func bothConstantsIntentionallyRegisteredTogether() throws {
        // Mirrors real correct code that listens on both lifecycle paths for
        // compatibility -- see this operator's own doc comment, "Known-safe,
        // expected special case."
        let source = """
        import UIKit

        final class CompatibilityObserver {
            func register() {
                let center = NotificationCenter.default
                center.addObserver(self, selector: #selector(refresh), name: UIApplication.didBecomeActiveNotification, object: nil)
                center.addObserver(self, selector: #selector(refresh), name: UIApplication.willEnterForegroundNotification, object: nil)
            }
            @objc func refresh() {}
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.count == 2)
        let originals = Set(points.map(\.originalText))
        #expect(originals == ["UIApplication.didBecomeActiveNotification", "UIApplication.willEnterForegroundNotification"])
    }

    // MARK: - Negative scenarios

    @Test("UIApplication.didEnterBackgroundNotification is excluded")
    func didEnterBackgroundIsExcluded() throws {
        let source = """
        import UIKit

        final class Observer {
            func register() {
                NotificationCenter.default.addObserver(self, selector: #selector(fire), name: UIApplication.didEnterBackgroundNotification, object: nil)
            }
            @objc func fire() {}
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.isEmpty)
    }

    @Test("UIApplication.willResignActiveNotification is excluded")
    func willResignActiveIsExcluded() throws {
        let source = """
        import UIKit

        final class Observer {
            func register() {
                NotificationCenter.default.addObserver(self, selector: #selector(fire), name: UIApplication.willResignActiveNotification, object: nil)
            }
            @objc func fire() {}
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.isEmpty)
    }

    @Test("A custom type's own didBecomeActiveNotification member is excluded")
    func customTypeMemberIsExcluded() throws {
        let source = """
        struct MyLifecycleConstants {
            static let didBecomeActiveNotification = "com.example.didBecomeActive"
        }

        func register() -> String {
            MyLifecycleConstants.didBecomeActiveNotification
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.isEmpty)
    }

    @Test("NSApplication.didBecomeActiveNotification is excluded")
    func nsApplicationIsExcluded() throws {
        let source = """
        import AppKit

        final class Observer {
            func register() {
                NotificationCenter.default.addObserver(self, selector: #selector(fire), name: NSApplication.didBecomeActiveNotification, object: nil)
            }
            @objc func fire() {}
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.isEmpty)
    }

    @Test("An arbitrary string literal is excluded")
    func arbitraryStringLiteralIsExcluded() throws {
        let source = """
        struct Constants {
            static let name = "UIApplicationDidBecomeActiveNotification"
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.isEmpty)
    }

    @Test("A similarly-named identifier that is not the exact constant is excluded")
    func similarlyNamedIdentifierIsExcluded() throws {
        let source = """
        import UIKit

        final class Observer {
            func register() -> Bool {
                UIApplication.shared.isIdleTimerDisabled
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.isEmpty)
    }

    @Test("The dot-shorthand implicit-member form is excluded in v1 (no UIApplication base to match on)")
    func implicitMemberFormIsExcluded() throws {
        let source = """
        import UIKit

        final class Observer {
            func register() {
                NotificationCenter.default.addObserver(forName: .didBecomeActiveNotification, object: nil, queue: .main) { _ in }
            }
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.isEmpty, "v1 requires the explicit UIApplication. qualifier -- see the operator's own doc comment")
    }

    @Test("The legacy Notification.Name.UIApplicationDidBecomeActive spelling is excluded")
    func legacySpellingIsExcluded() throws {
        let source = """
        import UIKit

        final class Observer {
            func register() {
                NotificationCenter.default.addObserver(self, selector: #selector(fire), name: NSNotification.Name.UIApplicationDidBecomeActive, object: nil)
            }
            @objc func fire() {}
        }
        """
        let points = try CoreOperatorExpansionTestSupport.discover(source, operatorID: operatorID)
        #expect(points.isEmpty)
    }
}
