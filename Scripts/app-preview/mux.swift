// 사용법: mux <video.mov> <out.mov>  (record.sh에서 호출)
// 영상은 재인코딩 없이 그대로 옮기고, 무음 스테레오 AAC 48kHz(256kbps) 트랙을 더한다(App Preview는 오디오 트랙 필요).
import AVFoundation

let src = URL(fileURLWithPath: CommandLine.arguments[1])
let out = URL(fileURLWithPath: CommandLine.arguments[2])
try? FileManager.default.removeItem(at: out)

let asset = AVURLAsset(url: src)
let duration = try await asset.load(.duration)
let vTrack = try await asset.loadTracks(withMediaType: .video)[0]
let vFormat = try await vTrack.load(.formatDescriptions)[0]

let reader = try AVAssetReader(asset: asset)
let vOut = AVAssetReaderTrackOutput(track: vTrack, outputSettings: nil)
reader.add(vOut)

let writer = try AVAssetWriter(outputURL: out, fileType: .mov)
let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: vFormat)
vIn.expectsMediaDataInRealTime = false
let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 256_000,
])
writer.add(vIn); writer.add(aIn)
reader.startReading()
writer.startWriting()
writer.startSession(atSourceTime: .zero)

var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1,
    mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
var aFmt: CMAudioFormatDescription?
CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &aFmt)

func silentBuffer(start: Int64, frames: Int) -> CMSampleBuffer {
    let bytes = frames * 4
    var block: CMBlockBuffer?
    CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
    CMBlockBufferFillDataBytes(with: 0, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes)
    var sb: CMSampleBuffer?
    CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: aFmt!, sampleCount: frames, presentationTimeStamp: CMTime(value: start, timescale: 48_000), packetDescriptions: nil, sampleBufferOut: &sb)
    return sb!
}

let totalFrames = Int64(duration.seconds * 48_000)
var audioPos: Int64 = 0
var videoDone = false
let q = DispatchQueue(label: "mux")
let group = DispatchGroup()
group.enter()
vIn.requestMediaDataWhenReady(on: q) {
    while vIn.isReadyForMoreMediaData {
        if let s = vOut.copyNextSampleBuffer() { vIn.append(s) } else { vIn.markAsFinished(); group.leave(); return }
    }
}
group.enter()
aIn.requestMediaDataWhenReady(on: DispatchQueue(label: "aud")) {
    while aIn.isReadyForMoreMediaData {
        if audioPos >= totalFrames { aIn.markAsFinished(); group.leave(); return }
        let n = Int(min(4_800, totalFrames - audioPos))
        aIn.append(silentBuffer(start: audioPos, frames: n)); audioPos += Int64(n)
    }
}
group.wait()
writer.endSession(atSourceTime: duration)
await writer.finishWriting()
print("status", writer.status.rawValue, writer.error as Any)
