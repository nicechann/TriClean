//
//  PhotoScreenshotNameTests.swift
//  TriCleanTests
//
//  Spotlight가 인덱싱하지 않은 볼륨에서는 파일명 폴백이 유일한 판별 수단이다.
//

import XCTest
@testable import TriClean

final class PhotoScreenshotNameTests: XCTestCase {

    private func isScreenshot(_ name: String) -> Bool {
        PhotoScannerViewModel.matchesScreenshotName(URL(fileURLWithPath: "/tmp/\(name)"))
    }

    func test_지원_언어의_기본_스크린샷_파일명을_인식한다() {
        let names = [
            "Screenshot 2026-06-17 at 10.50.12.png",   // en
            "Screen Shot 2026-06-17.png",              // en (구형)
            "스크린샷 2026-06-17 오전 10.50.12.png",      // ko
            "スクリーンショット 2026-06-17.png",            // ja
            "Bildschirmfoto 2026-06-17 um 10.50.12.png", // de
            "Captura de pantalla 2026-06-17.png",      // es
            "Capture d'écran 2026-06-17.png"           // fr
        ]
        for name in names {
            XCTAssertTrue(isScreenshot(name), "'\(name)'을(를) 스크린샷으로 인식하지 못했습니다")
        }
    }

    func test_일반_사진은_스크린샷으로_보지_않는다() {
        for name in ["IMG_0421.png", "family-trip.png", "logo.png"] {
            XCTAssertFalse(isScreenshot(name), "'\(name)'이(가) 스크린샷으로 잘못 분류되었습니다")
        }
    }

    func test_png가_아니면_제외한다() {
        XCTAssertFalse(isScreenshot("Screenshot 2026-06-17.jpg"))
        XCTAssertFalse(isScreenshot("스크린샷 2026-06-17.heic"))
    }

    func test_대소문자를_구분하지_않는다() {
        XCTAssertTrue(isScreenshot("SCREENSHOT 2026.png"))
        XCTAssertTrue(isScreenshot("bildschirmfoto 2026.png"))
    }
}
