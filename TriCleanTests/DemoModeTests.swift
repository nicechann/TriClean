//
//  DemoModeTests.swift
//  TriCleanTests
//
//  App Store 미리보기용 DEBUG 데모 모드.
//  - 데모가 바꾼 DEBUG 구매 강제값은 정상 종료·중간 실패 모두에서 키 존재 여부까지 되돌린다.
//  - 영상 자막은 하드코딩된 한 언어가 아니라 14개 언어 리소스를 따른다.
//

#if DEBUG
import XCTest
@testable import TriClean

@MainActor
final class DemoModeTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private let key = DebugPurchaseOverrideSession.key

    override func setUp() async throws {
        suiteName = "DemoModeTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeSession(restored: @escaping (Bool?) -> Void = { _ in }) -> (DebugPurchaseOverrideSession, () -> [Bool]) {
        var applied: [Bool] = []
        let session = DebugPurchaseOverrideSession(
            defaults: defaults, forcing: true, apply: { applied.append($0) }, onRestore: restored
        )
        return (session, { applied })
    }

    // MARK: - 구매 강제값 복원

    func test_키가_없던_경우_종료후_키를_지운다() {
        XCTAssertNil(defaults.object(forKey: key))
        var restoredValue: Bool?? = .none
        let (session, applied) = makeSession { restoredValue = .some($0) }

        XCTAssertEqual(applied(), [true])
        XCTAssertEqual(defaults.object(forKey: key) as? Bool, true)
        XCTAssertNil(session.originalValue)

        session.restore()
        XCTAssertNil(defaults.object(forKey: key), "원래 없던 키는 false로 남기지 말고 지워야 한다")
        XCTAssertEqual(restoredValue, .some(nil))
    }

    func test_키가_있던_경우_원래_값으로_되돌린다() {
        for original in [false, true] {
            defaults.set(original, forKey: key)
            let (session, _) = makeSession()
            XCTAssertEqual(defaults.bool(forKey: key), true)
            XCTAssertEqual(session.originalValue, original)

            session.restore()
            XCTAssertEqual(defaults.object(forKey: key) as? Bool, original)
        }
    }

    func test_정상_종료하면_되돌린다() async {
        let (session, _) = makeSession()
        let completed = await DemoMode.withPurchaseOverride(session) {
            XCTAssertEqual(self.defaults.object(forKey: self.key) as? Bool, true)
            return true
        }
        XCTAssertTrue(completed)
        XCTAssertTrue(session.isRestored)
        XCTAssertNil(defaults.object(forKey: key))
    }

    func test_창을_만들지_못해_중간에_끝나도_되돌린다() async {
        defaults.set(false, forKey: key)
        let (session, _) = makeSession()
        let completed = await DemoMode.withPurchaseOverride(session) { false }
        XCTAssertFalse(completed)
        XCTAssertTrue(session.isRestored)
        XCTAssertEqual(defaults.object(forKey: key) as? Bool, false)
    }

    func test_여러_경로에서_불려도_한_번만_되돌린다() {
        var restoreCount = 0
        let (session, _) = makeSession { _ in restoreCount += 1 }
        session.restore()
        // 되돌린 뒤 사용자가 설정에서 바꾼 값을 앱 종료 알림의 두 번째 복원이 덮으면 안 된다.
        defaults.set(true, forKey: key)
        session.restore()
        XCTAssertEqual(restoreCount, 1)
        XCTAssertEqual(defaults.object(forKey: key) as? Bool, true)
    }

    // MARK: - 자막

    private let languages = ["de", "en", "es", "fr", "it", "ja", "ko", "nl", "pl", "pt-BR", "ru", "tr", "zh-Hans", "zh-Hant"]

    private func strings(for language: String) throws -> [String: String] {
        let bundle = Bundle(for: StoreManager.self)
        let path = try XCTUnwrap(
            bundle.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: language),
            language
        )
        return try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: String], language)
    }

    func test_자막은_14개_언어_리소스를_따른다() throws {
        let keys = DemoMode.Caption.allCases.map(\.rawValue) + ["demo.note.sample_data"]
        XCTAssertEqual(DemoMode.Caption.allCases.count, 6)

        var captionsByLanguage: [String: [String]] = [:]
        for language in languages {
            let table = try strings(for: language)
            let values = try keys.map { key in try XCTUnwrap(table[key], "\(language): \(key)") }
            for (key, value) in zip(keys, values) {
                XCTAssertFalse(value.isEmpty, "\(language): \(key)")
                XCTAssertNotEqual(value, key, "\(language): \(key)")
            }
            captionsByLanguage[language] = values
        }
        // 언어마다 실제로 다른 자막이 들어 있어야 한다(한 언어로 고정되면 같아진다).
        XCTAssertNotEqual(captionsByLanguage["en"], captionsByLanguage["ko"])
        XCTAssertNotEqual(captionsByLanguage["ja"], captionsByLanguage["ko"])
        XCTAssertEqual(Set(captionsByLanguage.values.map { $0.joined(separator: "|") }).count, languages.count)
    }

    func test_자막은_앱_언어로_해석된다() {
        for caption in DemoMode.Caption.allCases {
            XCTAssertEqual(caption.text, caption.rawValue.localized)
            XCTAssertNotEqual(caption.text, caption.rawValue, "현재 언어에 번역이 없습니다: \(caption.rawValue)")
        }
    }
}
#endif
