// 데모 앱의 표준 출력을 읽어 App Store 미리보기 원본 영상을 녹화한다. record.sh에서 호출한다.
// 사용법: <앱 표준 출력> | recorder <out.mov>
//
// - DEMO_WINDOW <id>: 해당 창의 영역에서 TriClean의 창만 캡처한다(다른 앱 창은 제외).
// - DEMO_START / DEMO_CAPTION <문구> / DEMO_END: 녹화 시작, 자막 교체, 종료.
// - DEMO_NOTE <문구>: 화면이 예시 데이터임을 알리는 작은 문구(오른쪽 위에 계속 표시).
// - 1920×1080, 30fps H.264로 배경 그라데이션 + 창(그림자 포함) + 상단 자막을 합성한다.
import AppKit
import AVFoundation
import CoreImage
import ScreenCaptureKit

let outURL = URL(fileURLWithPath: CommandLine.arguments[1])
let canvas = CGRect(x: 0, y: 0, width: 1920, height: 1080)
let fps: Int32 = 30
let windowTarget = CGRect(x: 260, y: 30, width: 1400, height: 850)   // CI coords (bottom-left)
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

let ci = CIContext(options: [.workingColorSpace: sRGB, .outputColorSpace: sRGB])

let background: CIImage = {
    let g = CIFilter(name: "CILinearGradient", parameters: [
        "inputPoint0": CIVector(x: 0, y: 1080),
        "inputPoint1": CIVector(x: 1920, y: 0),
        "inputColor0": CIColor(red: 0.03, green: 0.30, blue: 0.78),
        "inputColor1": CIColor(red: 0.24, green: 0.14, blue: 0.58),
    ])!.outputImage!
    return g.cropped(to: canvas)
}()

let shadow: CIImage = {
    let r = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
        "inputExtent": CIVector(cgRect: windowTarget),
        "inputRadius": 26,
        "inputColor": CIColor(red: 0, green: 0, blue: 0, alpha: 0.5),
    ])!.outputImage!
    return r.applyingGaussianBlur(sigma: 22).transformed(by: .init(translationX: 0, y: -10)).cropped(to: canvas)
}()

func captionImage(_ text: String) -> CIImage {
    let w = 1920, h = 200
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    let para = NSMutableParagraphStyle(); para.alignment = .center
    let shadow = NSShadow(); shadow.shadowColor = NSColor(white: 0, alpha: 0.25); shadow.shadowBlurRadius = 8; shadow.shadowOffset = .init(width: 0, height: -2)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 64, weight: .bold),
        .foregroundColor: NSColor.white, .paragraphStyle: para, .shadow: shadow,
    ]
    var str = NSAttributedString(string: text, attributes: attrs)
    // 독일어 등 긴 번역도 화면 밖으로 잘리지 않도록 폭에 맞춰 글자를 줄인다.
    var fontSize: CGFloat = 64
    while str.size().width > 1800, fontSize > 36 {
        fontSize -= 2
        var smaller = attrs
        smaller[.font] = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        str = NSAttributedString(string: text, attributes: smaller)
    }
    let size = str.size()
    str.draw(in: CGRect(x: 0, y: (CGFloat(h) - size.height) / 2 - 4, width: CGFloat(w), height: size.height + 8))
    NSGraphicsContext.restoreGraphicsState()
    return CIImage(cgImage: ctx.makeImage()!).transformed(by: .init(translationX: 0, y: 880))
}

func noteImage(_ text: String) -> CIImage {
    let w = 1920, h = 60
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    let para = NSMutableParagraphStyle(); para.alignment = .right
    let str = NSAttributedString(string: text, attributes: [
        .font: NSFont.systemFont(ofSize: 22, weight: .medium),
        .foregroundColor: NSColor(white: 1, alpha: 0.75), .paragraphStyle: para,
    ])
    let size = str.size()
    str.draw(in: CGRect(x: 0, y: (CGFloat(h) - size.height) / 2, width: CGFloat(w) - 40, height: size.height + 4))
    NSGraphicsContext.restoreGraphicsState()
    return CIImage(cgImage: ctx.makeImage()!).transformed(by: .init(translationX: 0, y: 1080 - 60))
}

func withAlpha(_ img: CIImage, _ a: CGFloat) -> CIImage {
    img.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: a)])
}

final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    let lock = NSLock()
    var latest: CVPixelBuffer?
    var stream: SCStream?
    var writer: AVAssetWriter!
    var input: AVAssetWriterInput!
    var adaptor: AVAssetWriterInputPixelBufferAdaptor!
    var timer: DispatchSourceTimer?
    let q = DispatchQueue(label: "rec")
    var startTime: CFAbsoluteTime = 0
    var nextIndex: Int64 = 0
    var recording = false
    var caption: CIImage?, prevCaption: CIImage?, captionChange: CFAbsoluteTime = 0
    var note: CIImage?
    var frameCount = 0

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pb = sb.imageBuffer else { return }
        if let info = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
           let raw = info[.status] as? Int, raw != SCFrameStatus.complete.rawValue { return }
        lock.lock(); latest = pb; lock.unlock()
        frameCount += 1
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { log("stream error: \(error)") }

    func startCapture(windowID: CGWindowID) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let win = content.windows.first(where: { $0.windowID == windowID }), let app = win.owningApplication else {
            throw NSError(domain: "rec", code: 1, userInfo: [NSLocalizedDescriptionKey: "window \(windowID) not found"])
        }
        let center = CGPoint(x: win.frame.midX, y: win.frame.midY)
        guard let display = content.displays.first(where: { $0.frame.contains(center) }) else { throw NSError(domain: "rec", code: 2) }
        let scale = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID })?.backingScaleFactor ?? 2
        let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.sourceRect = win.frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        cfg.width = Int(win.frame.width * scale)
        cfg.height = Int(win.frame.height * scale)
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.backgroundColor = .clear
        cfg.showsCursor = false
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        cfg.queueDepth = 6
        log("capture window \(windowID) frame=\(win.frame) display=\(display.displayID) scale=\(scale) px=\(cfg.width)x\(cfg.height)")
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "cap"))
        try await s.startCapture()
        stream = s
    }

    func setupWriter() throws {
        try? FileManager.default.removeItem(at: outURL)
        writer = try AVAssetWriter(outputURL: outURL, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 1920, AVVideoHeightKey: 1080,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 10_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 30,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 1920, kCVPixelBufferHeightKey as String: 1080,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error! }
        writer.startSession(atSourceTime: .zero)
    }

    func compose(now: CFAbsoluteTime) -> CIImage {
        var img = shadow.composited(over: background)
        lock.lock(); let pb = latest; lock.unlock()
        if let pb {
            let w = CIImage(cvPixelBuffer: pb)
            let s = windowTarget.width / w.extent.width
            let scaled = w.applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": s, "inputAspectRatio": 1])
                .transformed(by: .init(translationX: windowTarget.minX, y: windowTarget.minY))
            img = scaled.composited(over: img)
        }
        // 이전 자막을 먼저 지우고(0.2s) 새 자막을 띄운다(0.25s). 겹치면 글자가 뒤섞여 보인다.
        let dt = now - captionChange
        if let prevCaption, dt < 0.2 { img = withAlpha(prevCaption, 1 - dt / 0.2).composited(over: img) }
        let fadeIn = prevCaption == nil ? min(1, dt / 0.25) : max(0, min(1, (dt - 0.2) / 0.25))
        if let caption { img = withAlpha(caption, fadeIn).composited(over: img) }
        if let note { img = note.composited(over: img) }
        return img.cropped(to: canvas)
    }

    func begin() {
        q.sync {
            startTime = CFAbsoluteTimeGetCurrent(); recording = true
            let t = DispatchSource.makeTimerSource(queue: q)
            t.schedule(deadline: .now(), repeating: .milliseconds(8))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume(); timer = t
        }
    }

    func tick() {
        guard recording else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let target = Int64((now - startTime) * Double(fps))
        guard nextIndex <= target, input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let out else { return }
        ci.render(compose(now: now), to: out, bounds: canvas, colorSpace: sRGB)
        while nextIndex <= target {
            if !adaptor.append(out, withPresentationTime: CMTime(value: nextIndex, timescale: fps)) { log("append failed \(String(describing: writer.error))") }
            nextIndex += 1
        }
    }

    func setNote(_ text: String) {
        q.async { self.note = noteImage(text) }
    }

    func setCaption(_ text: String) {
        q.async { self.prevCaption = self.caption; self.caption = captionImage(text); self.captionChange = CFAbsoluteTimeGetCurrent() }
    }

    func finish() {
        q.sync { recording = false; timer?.cancel() }
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        log("finished: frames=\(nextIndex) captured=\(frameCount) status=\(writer.status.rawValue) err=\(String(describing: writer.error))")
        Task { try? await self.stream?.stopCapture(); exit(0) }
    }
}

let rec = Recorder()
Thread {
    while let line = readLine() {
        let stamp = String(format: "%.2f", CFAbsoluteTimeGetCurrent() - (rec.startTime == 0 ? CFAbsoluteTimeGetCurrent() : rec.startTime))
        log("[\(stamp)] \(line)")
        if line.hasPrefix("DEMO_WINDOW "), let id = UInt32(line.dropFirst(12)) {
            Task {
                do { try await rec.startCapture(windowID: id); try rec.setupWriter() }
                catch { log("capture failed: \(error)"); exit(2) }
            }
        } else if line == "DEMO_START" {
            rec.begin()
        } else if line.hasPrefix("DEMO_NOTE ") {
            rec.setNote(String(line.dropFirst(10)))
        } else if line.hasPrefix("DEMO_CAPTION ") {
            rec.setCaption(String(line.dropFirst(13)))
        } else if line == "DEMO_END" {
            rec.finish(); return
        } else if line.hasPrefix("DEMO_ERROR") { exit(3) }
    }
    log("stdin closed"); if rec.recording { rec.finish() } else { exit(4) }
}.start()
dispatchMain()
