// audiocap - captures one audio source and writes raw 16 kHz mono Float32 (little endian) to stdout.
//
//   audiocap --source system   system audio via Core Audio process tap (macOS 14.2+), no virtual driver
//   audiocap --source mic      default input device, follows device changes (AirPods on/off etc.)
//   audiocap --source system --seconds 5 > /tmp/test.raw   short test run
//
// Diagnostics go to stderr. A broken stdout pipe ends the process quietly.

import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation

signal(SIGPIPE, SIG_IGN)

let targetRate: Double = 16000
let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetRate,
                                 channels: 1, interleaved: false)!

func log(_ s: String) {
    FileHandle.standardError.write(("[audiocap] " + s + "\n").data(using: .utf8)!)
}

struct CapError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

// MARK: - Output

let stdoutHandle = FileHandle.standardOutput
let writeQueue = DispatchQueue(label: "audiocap.write")
var framesWritten: Int64 = 0
var peakSinceReport: Float = 0

func emit(_ buf: AVAudioPCMBuffer) {
    guard let ch = buf.floatChannelData else { return }
    let n = Int(buf.frameLength)
    if n == 0 { return }
    var peak: Float = 0
    for i in 0..<n { let v = abs(ch[0][i]); if v > peak { peak = v } }
    let data = Data(bytes: ch[0], count: n * MemoryLayout<Float>.size)
    writeQueue.async {
        framesWritten += Int64(n)
        if peak > peakSinceReport { peakSinceReport = peak }
        do { try stdoutHandle.write(contentsOf: data) } catch { exit(0) }
    }
}

// MARK: - Resampling to 16 kHz mono

final class Resampler {
    let inFormat: AVAudioFormat
    let converter: AVAudioConverter

    init?(from fmt: AVAudioFormat) {
        inFormat = fmt
        guard let c = AVAudioConverter(from: fmt, to: targetFormat) else { return nil }
        c.downmix = true
        converter = c
    }

    func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if input.frameLength == 0 { return nil }
        let ratio = targetRate / inFormat.sampleRate
        let cap = AVAudioFrameCount(Double(input.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: cap) else { return nil }
        var consumed = false
        var err: NSError?
        let status = converter.convert(to: out, error: &err) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return input
        }
        if status == .error {
            log("convert error: \(err?.localizedDescription ?? "?")")
            return nil
        }
        return out
    }
}

// MARK: - Core Audio helpers

func systemAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector,
                               mScope: kAudioObjectPropertyScopeGlobal,
                               mElement: kAudioObjectPropertyElementMain)
}

func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
    var addr = systemAddress(selector)
    var dev = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
    return (st == noErr && dev != kAudioObjectUnknown) ? dev : nil
}

func deviceUID(_ dev: AudioDeviceID) -> String? {
    var addr = systemAddress(kAudioDevicePropertyDeviceUID)
    var uid: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.stride)
    let st = withUnsafeMutablePointer(to: &uid) { ptr in
        AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, ptr)
    }
    return st == noErr ? (uid as String) : nil
}

// MARK: - System audio (process tap)

@available(macOS 14.2, *)
final class SystemCapture {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var resampler: Resampler?
    private var callbacks: Int64 = 0
    private let ioQueue = DispatchQueue(label: "audiocap.systap", qos: .userInitiated)
    private var withOutputSubdevice = false
    private var listenerInstalled = false

    func start() throws {
        try build()
        // A tap-only aggregate normally runs on its own clock. If no IO arrives,
        // rebuild it with the default output device as clock source.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            if self.callbacks == 0 && !self.withOutputSubdevice {
                log("no IO from tap-only aggregate, retrying with output device as clock")
                self.withOutputSubdevice = true
                self.teardown()
                do { try self.build() } catch { log("rebuild failed: \(error)"); exit(3) }
                self.installOutputListener()
            }
        }
    }

    private func build() throws {
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID()
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        desc.name = "live-transcriber"
        var err = AudioHardwareCreateProcessTap(desc, &tapID)
        guard err == noErr else { throw CapError("AudioHardwareCreateProcessTap failed: \(err)") }

        var subDevices: [[String: Any]] = []
        if withOutputSubdevice, let out = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice),
           let uid = deviceUID(out) {
            subDevices = [[kAudioSubDeviceUIDKey: uid]]
        }
        var agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "live-transcriber-agg",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: desc.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        if let first = subDevices.first, let uid = first[kAudioSubDeviceUIDKey] {
            agg[kAudioAggregateDeviceMainSubDeviceKey] = uid
        }
        err = AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggID)
        guard err == noErr else { throw CapError("AudioHardwareCreateAggregateDevice failed: \(err)") }

        var addr = systemAddress(kAudioTapPropertyFormat)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        err = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd)
        guard err == noErr else { throw CapError("tap format failed: \(err)") }
        guard let fmt = AVAudioFormat(streamDescription: &asbd) else { throw CapError("unsupported tap format") }
        guard let rs = Resampler(from: fmt) else { throw CapError("no converter for tap format \(fmt)") }
        resampler = rs
        log("system tap: \(fmt.sampleRate) Hz, \(fmt.channelCount) ch, clock=\(withOutputSubdevice ? "output device" : "tap")")

        err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, ioQueue) { [weak self] _, inInput, _, _, _ in
            guard let self else { return }
            self.callbacks += 1
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, bufferListNoCopy: inInput, deallocator: nil),
                  let out = rs.convert(buf) else { return }
            emit(out)
        }
        guard err == noErr, let pid = procID else { throw CapError("IOProc create failed: \(err)") }
        err = AudioDeviceStart(aggID, pid)
        guard err == noErr else { throw CapError("AudioDeviceStart failed: \(err)") }
    }

    private func installOutputListener() {
        if listenerInstalled { return }
        listenerInstalled = true
        var addr = systemAddress(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { [weak self] _, _ in
            guard let self else { return }
            log("default output changed, rebuilding tap")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.teardown()
                do { try self.build() } catch { log("rebuild failed: \(error)") }
            }
        }
    }

    func teardown() {
        if let pid = procID {
            AudioDeviceStop(aggID, pid)
            AudioDeviceDestroyIOProcID(aggID, pid)
            procID = nil
        }
        if aggID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggID); aggID = kAudioObjectUnknown }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID); tapID = kAudioObjectUnknown }
    }
}

// MARK: - Microphone

final class MicCapture {
    private var engine = AVAudioEngine()
    private var restartPending = false

    func start() throws {
        if let dev = defaultDevice(kAudioHardwarePropertyDefaultInputDevice),
           let au = engine.inputNode.audioUnit {
            var d = dev
            let st = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &d, UInt32(MemoryLayout<AudioDeviceID>.size))
            if st != noErr { log("set input device failed: \(st)") }
        }
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else { throw CapError("input device has no format") }
        guard let rs = Resampler(from: fmt) else { throw CapError("no converter for mic format \(fmt)") }
        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { buf, _ in
            if let out = rs.convert(buf) { emit(out) }
        }
        engine.prepare()
        try engine.start()
        log("mic: \(fmt.sampleRate) Hz, \(fmt.channelCount) ch")
    }

    func scheduleRestart(_ reason: String) {
        if restartPending { return }
        restartPending = true
        log("mic restart: \(reason)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self else { return }
            self.restartPending = false
            self.engine.stop()
            self.engine.inputNode.removeTap(onBus: 0)
            self.engine = AVAudioEngine()
            self.observe()
            do { try self.start() } catch {
                log("mic restart failed: \(error), retrying")
                self.scheduleRestart("retry")
            }
        }
    }

    private var observer: NSObjectProtocol?

    func observe() {
        if let o = observer { NotificationCenter.default.removeObserver(o) }
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                          object: engine, queue: .main) { [weak self] _ in
            self?.scheduleRestart("engine configuration change")
        }
    }

    func installDefaultInputListener() {
        var addr = systemAddress(kAudioHardwarePropertyDefaultInputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { [weak self] _, _ in
            self?.scheduleRestart("default input changed")
        }
    }
}

func requestMicAccess() -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: return true
    case .notDetermined:
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        AVCaptureDevice.requestAccess(for: .audio) { granted in ok = granted; sem.signal() }
        sem.wait()
        return ok
    default: return false
    }
}

// MARK: - Main

var source = ""
var seconds: Double = 0
var argv = CommandLine.arguments.dropFirst().makeIterator()
while let a = argv.next() {
    switch a {
    case "--source": source = argv.next() ?? ""
    case "--seconds": seconds = Double(argv.next() ?? "0") ?? 0
    case "-h", "--help":
        print("usage: audiocap --source system|mic [--seconds N]")
        exit(0)
    default:
        log("unknown argument \(a)")
        exit(64)
    }
}

var keepAlive: [AnyObject] = []

switch source {
case "system":
    guard #available(macOS 14.2, *) else { log("system audio needs macOS 14.2+"); exit(2) }
    let cap = SystemCapture()
    do { try cap.start() } catch { log("\(error)"); exit(1) }
    keepAlive.append(cap)
    let term: () -> Void = { cap.teardown() }
    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler { term(); exit(0) }
        src.resume()
        keepAlive.append(src as AnyObject)
    }
case "mic":
    guard requestMicAccess() else { log("microphone access denied (System Settings > Privacy > Microphone)"); exit(1) }
    let mic = MicCapture()
    mic.observe()
    mic.installDefaultInputListener()
    do { try mic.start() } catch { log("\(error)"); exit(1) }
    keepAlive.append(mic)
default:
    log("usage: audiocap --source system|mic [--seconds N]")
    exit(64)
}

// Health line every 10 s: frames written and peak level. Peak 0 for a long time = silence or no permission.
let health = DispatchSource.makeTimerSource(queue: .main)
health.schedule(deadline: .now() + 10, repeating: 10)
health.setEventHandler {
    writeQueue.async {
        log(String(format: "health source=%@ frames=%lld peak=%.4f", source, framesWritten, peakSinceReport))
        peakSinceReport = 0
    }
}
health.resume()

if seconds > 0 {
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
        writeQueue.sync {}
        exit(0)
    }
}

dispatchMain()
