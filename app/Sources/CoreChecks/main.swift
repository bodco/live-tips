// Core checks without a test framework: the Command Line Tools ship neither XCTest nor
// swift-testing, and the app must build without Xcode. Run: swift run -c release CoreChecks
import Foundation
import LiveTipsCore

var failures = 0
var passed = 0
func expect(_ ok: @autoclosure () -> Bool, _ what: String = "", line: Int = #line) {
    if ok() { passed += 1 } else { failures += 1; print("FAIL line \(line) \(what)") }
}

func frameRoundTripAcrossChunks() {
    let frames = [Frame(kind: .heartbeat, payload: Data("{\"t\":1}".utf8)),
                  Frame(kind: .micAudio, payload: Data(repeating: 7, count: 640))]
    var bytes = Data()
    frames.forEach { bytes.append($0.encoded()) }
    var dec = FrameDecoder()
    var got: [Frame] = []
    var i = 0
    while i < bytes.count {
        let end = min(i + 37, bytes.count)
        got += dec.feed(bytes.subdata(in: i..<end))
        i = end
    }
    expect(got == frames)
    expect(dec.malformed == 0)
}

func frameResyncAfterGarbage() {
    var dec = FrameDecoder()
    var bytes = Data([0xFF, 0x00])
    bytes.append(Frame(kind: .log, payload: Data("ok".utf8)).encoded())
    let got = dec.feed(bytes)
    expect(got.last?.payload == Data("ok".utf8))
    expect(dec.malformed > 0)
}

func watchdogStartGraceThenStallTerminateKillRestart() {
    var w = HelperWatchdog()
    expect(w.evaluate(now: 5, startedAt: 0, lastHeartbeat: nil, lastMicAudio: nil, micMuted: false, alive: true) == .none)
    expect(w.evaluate(now: 20, startedAt: 0, lastHeartbeat: 19, lastMicAudio: 5, micMuted: false, alive: true) == .terminate)
    expect(w.evaluate(now: 24, startedAt: 0, lastHeartbeat: 19, lastMicAudio: 5, micMuted: false, alive: true) == .kill)
    expect(w.evaluate(now: 25, startedAt: 0, lastHeartbeat: 19, lastMicAudio: 5, micMuted: false, alive: false) == .restart(afterSeconds: 2))
}

func watchdogMutedMicIsNotAStall() {
    var w = HelperWatchdog()
    expect(w.evaluate(now: 60, startedAt: 0, lastHeartbeat: 59.5, lastMicAudio: 1, micMuted: true, alive: true) == .none)
}

func watchdogTwoFailedRestartsSwitchToBuiltInMic() {
    var w = HelperWatchdog()
    _ = w.evaluate(now: 20, startedAt: 0, lastHeartbeat: nil, lastMicAudio: nil, micMuted: false, alive: true)
    expect(w.evaluate(now: 21, startedAt: 0, lastHeartbeat: nil, lastMicAudio: nil, micMuted: false, alive: false) == .restart(afterSeconds: 2))
    _ = w.evaluate(now: 40, startedAt: 30, lastHeartbeat: nil, lastMicAudio: nil, micMuted: false, alive: true)
    expect(w.evaluate(now: 41, startedAt: 30, lastHeartbeat: nil, lastMicAudio: nil, micMuted: false, alive: false) == .switchToBuiltInMic)
}

frameRoundTripAcrossChunks()
frameResyncAfterGarbage()
watchdogStartGraceThenStallTerminateKillRestart()
watchdogMutedMicIsNotAStall()
watchdogTwoFailedRestartsSwitchToBuiltInMic()
print("core checks: \(passed) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
