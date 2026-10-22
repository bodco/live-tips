// audiocap - captures one audio source and writes raw 16 kHz mono Float32 (little endian) to stdout.
//
//   audiocap --source system   system audio via Core Audio process tap (macOS 14.2+), no virtual driver
//   audiocap --source mic      default input device, follows device changes (AirPods on/off etc.)
//   audiocap --source mic --device builtin   the Mac's own microphone, whatever the default input is
//   audiocap --source mic --device uid:<UID>   one chosen input (UIDs from --list-inputs)
//   audiocap --source mic --mic-backend direct   IOProc on the device, no AVAudioEngine (auto: engine, then direct if it gives no frames)
//   audiocap --list-inputs   JSON list of the inputs the Mac sees
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

private let logTimeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "HH:mm:ss"
    return f
}()

func log(_ s: String) {
    let t = logTimeFormatter.string(from: Date())
    FileHandle.standardError.write(("[audiocap] \(t) " + s + "\n").data(using: .utf8)!)
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
var micStallTicks = 0             // health ticks in a row with zero mic frames (stall watchdog)

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

func deviceName(_ dev: AudioObjectID) -> String {
    var addr = systemAddress(kAudioObjectPropertyName)
    var name: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.stride)
    let st = withUnsafeMutablePointer(to: &name) { ptr in
        AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, ptr)
    }
    return st == noErr ? (name as String) : "?"
}

func hasChannels(_ dev: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Bool {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                          mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, raw) == noErr else { return false }
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
}

func nominalRate(_ dev: AudioObjectID) -> Double? {
    var addr = systemAddress(kAudioDevicePropertyNominalSampleRate)
    var r: Float64 = 0
    var size = UInt32(MemoryLayout<Float64>.size)
    return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &r) == noErr ? r : nil
}

func setNominalRate(_ dev: AudioObjectID, _ rate: Double) -> Bool {
    var addr = systemAddress(kAudioDevicePropertyNominalSampleRate)
    var r: Float64 = rate
    return AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float64>.size), &r) == noErr
}

func deviceIsBuiltIn(_ dev: AudioDeviceID) -> Bool {
    var addr = systemAddress(kAudioDevicePropertyTransportType)
    var t: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &t) == noErr else { return false }
    return t == UInt32(kAudioDeviceTransportTypeBuiltIn)
}

/// Clock for the system tap aggregate. The Mac's built-in speakers: always 48 kHz and never switched
/// by Bluetooth. A headset as clock breaks capture: AirPods drop to 24 kHz (HFP) when any app opens
/// their mic, and the tap then delivers only half of the audio (seen 2026-10-15/16).
/// Nothing is played through the clock device; it only paces the IO.
func clockDeviceForTap() -> (AudioDeviceID, String)? {
    var ids: [AudioDeviceID] = []
    var addr = systemAddress(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    if AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 {
        ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) != noErr { ids = [] }
    }
    if let b = ids.first(where: { deviceIsBuiltIn($0) && hasChannels($0, kAudioObjectPropertyScopeOutput) }) {
        return (b, "built-in output")
    }
    if let d = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) { return (d, "default output") }
    return nil
}

var systemExpectedRate: Double = 0      // tap rate, for the health check
var systemCallbacks: Int64 = 0

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
        if forceDeviceClock {
            log("test: forcing a device clock")
            withOutputSubdevice = true
            try build()
            installOutputListener()
            return
        }
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
        var clockName = "tap"
        if withOutputSubdevice, let clk = clockDeviceForTap(), let uid = deviceUID(clk.0) {
            subDevices = [[kAudioSubDeviceUIDKey: uid]]
            clockName = "\(clk.1) (\(deviceName(clk.0)))"
            clockDevice = clk.0
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
        systemExpectedRate = fmt.sampleRate
        // The aggregate must run at the tap's rate, or it delivers only part of the audio.
        if let aggRate = nominalRate(aggID), abs(aggRate - fmt.sampleRate) > 1 {
            let ok = setNominalRate(aggID, fmt.sampleRate)
            log("aggregate ran at \(aggRate) Hz, tap is \(fmt.sampleRate) Hz: set to tap rate \(ok ? "ok" : "FAILED")")
        }
        let aggNow = nominalRate(aggID).map { String(format: "%.0f", $0) } ?? "?"
        log("system tap: \(fmt.sampleRate) Hz, \(fmt.channelCount) ch, clock=\(clockName), aggregate=\(aggNow) Hz")
        installRateListener()

        err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, ioQueue) { [weak self] _, inInput, _, _, _ in
            guard let self else { return }
            self.callbacks += 1
            systemCallbacks += 1
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, bufferListNoCopy: inInput, deallocator: nil),
                  let out = rs.convert(buf) else { return }
            emit(out)
        }
        guard err == noErr, let pid = procID else { throw CapError("IOProc create failed: \(err)") }
        err = AudioDeviceStart(aggID, pid)
        guard err == noErr else { throw CapError("AudioDeviceStart failed: \(err)") }
    }

    private var clockDevice = AudioDeviceID(kAudioObjectUnknown)
    private var rateListenerDevice = AudioObjectID(kAudioObjectUnknown)

    /// Rebuild when the aggregate's rate changes (a clock device switching modes mid-call).
    private func installRateListener() {
        guard aggID != kAudioObjectUnknown, rateListenerDevice != aggID else { return }
        rateListenerDevice = aggID
        var addr = systemAddress(kAudioDevicePropertyNominalSampleRate)
        let watched = aggID
        AudioObjectAddPropertyListenerBlock(watched, &addr, .main) { [weak self] _, _ in
            guard let self, self.aggID == watched else { return }
            log("aggregate sample rate changed to \(nominalRate(watched) ?? 0) Hz, rebuilding tap")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.teardown()
                do { try self.build() } catch { log("rebuild failed: \(error)") }
            }
        }
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

var micRestarts: Int64 = 0
var micMode = "default"          // "default" = system default input, "builtin" = the Mac's own microphone, "uid" = the input with micUID
var micUID = ""                  // for micMode "uid": CoreAudio device UID chosen in the window
var warnedNoBuiltin = false
var warnedNoUID = false

func allDevices() -> [AudioDeviceID] {
    var addr = systemAddress(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
          size > 0 else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
    else { return [] }
    return ids
}

func hasInputChannels(_ dev: AudioDeviceID) -> Bool {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                          mScope: kAudioObjectPropertyScopeInput,
                                          mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, raw) == noErr else { return false }
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
}

func isBuiltIn(_ dev: AudioDeviceID) -> Bool {
    var addr = systemAddress(kAudioDevicePropertyTransportType)
    var t: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &t) == noErr else { return false }
    return t == UInt32(kAudioDeviceTransportTypeBuiltIn)
}

/// The input device to record: the system default, or the Mac's own microphone when --device builtin.
/// With builtin the choice does not change when AirPods, Jabra or other headsets connect.
func targetMicDevice() -> AudioDeviceID? {
    if micMode == "builtin" {
        if let b = allDevices().first(where: { hasInputChannels($0) && isBuiltIn($0) }) { return b }
        if !warnedNoBuiltin {
            warnedNoBuiltin = true
            log("built-in microphone not found, using the default input")
        }
    }
    if micMode == "uid" {
        if let d = allDevices().first(where: { hasInputChannels($0) && deviceUID($0) == micUID }) { return d }
        if !warnedNoUID {
            warnedNoUID = true
            log("chosen input \(micUID) not found, using the default input")
        }
    }
    return defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
}

/// JSON list of every input device the Mac sees now (for the window's Mic menu): uid, name, builtin, default.
func listInputsJSON() -> String {
    let def = defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
    var items: [String] = []
    for d in allDevices() where hasInputChannels(d) {
        guard let uid = deviceUID(d) else { continue }
        // Skip the aggregate devices this tool creates for the system tap.
        let name = deviceName(d)
        if uid.lowercased().contains("audiocap") || name.lowercased().contains("audiocap") { continue }
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        items.append("{\"uid\":\"\(esc(uid))\",\"name\":\"\(esc(name))\",\"builtin\":\(isBuiltIn(d) ? "true" : "false"),\"default\":\(d == def ? "true" : "false")}")
    }
    return "[" + items.joined(separator: ",") + "]"
}

func currentDevice(of au: AudioUnit) -> AudioDeviceID? {
    var dev = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let st = AudioUnitGetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                  &dev, &size)
    return (st == noErr && dev != kAudioObjectUnknown) ? dev : nil
}

final class MicCapture {
    private var engine = AVAudioEngine()
    private var restartPending = false
    var retired = false               // replaced by DirectMic: ignore notifications, never restart

    func retire() {
        retired = true
        if let o = observer { NotificationCenter.default.removeObserver(o); observer = nil }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
    }
    private var device = AudioDeviceID(kAudioObjectUnknown)
    private var rate: Double = 0
    private var channels: AVAudioChannelCount = 0

    func start() throws {
        if let dev = targetMicDevice(),
           let au = engine.inputNode.audioUnit,
           currentDevice(of: au) != dev {
            // Switch only when needed: setting the device posts a configuration change, and a
            // restart on every change used to loop several times a second, losing the audio.
            var d = dev
            let st = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &d, UInt32(MemoryLayout<AudioDeviceID>.size))
            if st != noErr { log("set input device failed: \(st)") }
        }
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else { throw CapError("input device has no format") }
        try installMicTap(fmt)
        engine.prepare()
        try engine.start()
        // The hardware format can differ before and after start (device switch, other app on the mic).
        // Re-read it and rebuild the tap on the SAME engine instead of restarting the whole engine:
        // a tap with a stale format delivers zero frames.
        let live = engine.inputNode.outputFormat(forBus: 0)
        if live.sampleRate > 0, live.channelCount > 0,
           (live.sampleRate != fmt.sampleRate || live.channelCount != fmt.channelCount) {
            try installMicTap(live)
        }
        let fin = engine.inputNode.outputFormat(forBus: 0)
        device = input.audioUnit.flatMap { currentDevice(of: $0) }
            ?? targetMicDevice() ?? AudioDeviceID(kAudioObjectUnknown)
        rate = fin.sampleRate
        channels = fin.channelCount
        log("mic: \(fin.sampleRate) Hz, \(fin.channelCount) ch, device=\(deviceName(device))")
    }

    private func installMicTap(_ fmt: AVAudioFormat) throws {
        guard let rs = Resampler(from: fmt) else { throw CapError("no converter for mic format \(fmt)") }
        engine.inputNode.removeTap(onBus: 0)
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: fmt) { buf, _ in
            if let out = rs.convert(buf) { emit(out) }
        }
    }

    /// AVAudioEngine posts a configuration change right after start and whenever another app
    /// (Meet, Zoom, AirPods switching to the headset profile) touches the input. Rebuild the
    /// engine only when the device or its format really changed; otherwise keep it running.
    func configurationChanged() {
        if retired { return }
        let dev = targetMicDevice() ?? device
        let fmt = engine.inputNode.outputFormat(forBus: 0)
        if dev == device && fmt.sampleRate > 0 && fmt.channelCount > 0 {
            // Same device: only the format moved (or the engine paused). Retap on the same engine.
            if fmt.sampleRate != rate || fmt.channelCount != channels {
                do { try installMicTap(fmt); rate = fmt.sampleRate; channels = fmt.channelCount
                     log("mic retap: \(fmt.sampleRate) Hz, \(fmt.channelCount) ch") }
                catch { log("mic retap failed: \(error)"); scheduleRestart("retap failed"); return }
            }
            if !engine.isRunning {
                do { try engine.start() } catch { log("mic resume failed: \(error)"); scheduleRestart("resume failed") }
            }
            return
        }
        scheduleRestart("engine configuration change (\(fmt.sampleRate) Hz, \(fmt.channelCount) ch)")
    }

    func defaultInputChanged() {
        if retired { return }
        if let dev = targetMicDevice(), dev == device { return }   // builtin: a new headset changes nothing
        scheduleRestart("default input changed")
    }

    private var restartTimes: [Date] = []

    func scheduleRestart(_ reason: String) {
        if retired { return }
        if restartPending { return }
        restartPending = true
        micRestarts += 1
        let now = Date()
        restartTimes = restartTimes.filter { now.timeIntervalSince($0) < 20 } + [now]
        var delay = 0.7
        if restartTimes.count > 5 {
            // Restart storm: back off, and a forced built-in mic falls back to the system default input.
            delay = 3.0
            if micMode == "builtin" || micMode == "uid" {
                micMode = "default"
                log("mic restart storm on the chosen input, falling back to the default input")
            }
        }
        log("mic restart: \(reason)")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
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

    var observer: NSObjectProtocol?

    func observe() {
        if let o = observer { NotificationCenter.default.removeObserver(o) }
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                          object: engine, queue: .main) { [weak self] _ in
            self?.configurationChanged()
        }
    }

    func installDefaultInputListener() {
        var addr = systemAddress(kAudioHardwarePropertyDefaultInputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { [weak self] _, _ in
            self?.defaultInputChanged()
        }
    }
}

/// Direct device capture (2026-10-22): an IOProc on the input device itself, no AVAudioEngine.
/// Some USB headsets (Jabra Link 380 dongle) deliver no buffers at all to AVAudioEngine's input
/// node while a call app uses them, but work through a plain IOProc, like the system tap does.
final class DirectMic {
    private var dev = AudioDeviceID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "audiocap.directmic", qos: .userInteractive)
    private var restartPending = false

    func start() throws {
        guard let d = targetMicDevice() else { throw CapError("no input device") }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamFormat,
                                              mScope: kAudioObjectPropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var err = AudioObjectGetPropertyData(d, &addr, 0, nil, &size, &asbd)
        guard err == noErr else { throw CapError("input stream format failed: \(err)") }
        guard let fmt = AVAudioFormat(streamDescription: &asbd) else { throw CapError("unsupported input format") }
        guard let rs = Resampler(from: fmt) else { throw CapError("no converter for input format \(fmt)") }
        var pid: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&pid, d, ioQueue) { _, inInput, _, _, _ in
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, bufferListNoCopy: inInput, deallocator: nil),
                  let out = rs.convert(buf) else { return }
            emit(out)
        }
        guard err == noErr, let p = pid else { throw CapError("IOProc create failed: \(err)") }
        err = AudioDeviceStart(d, p)
        guard err == noErr else { AudioDeviceDestroyIOProcID(d, p); throw CapError("AudioDeviceStart failed: \(err)") }
        dev = d
        procID = p
        log("mic direct: \(fmt.sampleRate) Hz, \(fmt.channelCount) ch, device=\(deviceName(d))")
        watch(d)
    }

    /// A headset switching between music and call mode changes its rate and format; a device can vanish.
    private var watched = Set<AudioObjectID>()
    private func watch(_ d: AudioDeviceID) {
        guard !watched.contains(d) else { return }
        watched.insert(d)
        let sels: [(AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
            (kAudioDevicePropertyStreamFormat, kAudioObjectPropertyScopeInput),
            (kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
            (kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal)]
        for (sel, scope) in sels {
            var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(d, &addr, .main) { [weak self] _, _ in
                guard let self, self.dev == d else { return }
                self.scheduleRestart("input device format or state changed")
            }
        }
    }

    func stop() {
        if let p = procID, dev != kAudioObjectUnknown { AudioDeviceStop(dev, p); AudioDeviceDestroyIOProcID(dev, p) }
        procID = nil
    }

    func scheduleRestart(_ reason: String) {
        if restartPending { return }
        restartPending = true
        micRestarts += 1
        log("mic direct restart: \(reason)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self else { return }
            self.restartPending = false
            self.stop()
            do { try self.start() } catch { log("mic direct restart failed: \(error), retrying"); self.scheduleRestart("retry") }
        }
    }

    func installDefaultInputListener() {
        var addr = systemAddress(kAudioHardwarePropertyDefaultInputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { [weak self] _, _ in
            guard let self, micMode == "default" else { return }
            self.scheduleRestart("default input changed")
        }
    }
}

var engineTried = false

func startEngineMic(_ why: String) {
    engineTried = true
    log("mic: \(why), using AVAudioEngine")
    directRef?.stop()
    directRef = nil
    let mic = MicCapture()
    mic.observe()
    mic.installDefaultInputListener()
    do { try mic.start() } catch { log("\(error)"); exit(1) }
    keepAlive.append(mic)
    micRef = mic
}

var micBackend = "auto"           // auto: AVAudioEngine, switch to DirectMic when it gives no frames; engine | direct
var directRef: DirectMic?

func startDirectMic(_ why: String) {
    log("mic: \(why): direct device capture")
    micRef?.retire()
    micRef = nil
    let d = DirectMic()
    do { try d.start() } catch {
        log("mic direct failed: \(error)")
        if micBackend == "auto" && !engineTried { startEngineMic("direct capture failed"); return }
        exit(1)
    }
    d.installDefaultInputListener()
    keepAlive.append(d)
    directRef = d
}

func requestMicAccess() -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: return true
    case .notDetermined:
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        AVCaptureDevice.requestAccess(for: .audio) { granted in ok = granted; sem.signal() }
        // 2026-10-21: a CLI tool may never get the prompt on screen; never hang here forever.
        if sem.wait(timeout: .now() + 10) == .timedOut {
            log("microphone permission prompt not answered in 10 s (System Settings > Privacy > Microphone)")
            return false
        }
        return ok
    default: return false
    }
}

// MARK: - Main

var source = ""
var seconds: Double = 0
var forceDeviceClock = false   // test only: skip the tap-only clock, as when it gives no IO
var argv = CommandLine.arguments.dropFirst().makeIterator()
while let a = argv.next() {
    switch a {
    case "--source": source = argv.next() ?? ""
    case "--seconds": seconds = Double(argv.next() ?? "0") ?? 0
    case "--force-device-clock": forceDeviceClock = true
    case "--device":
        let dv = argv.next() ?? "default"
        if dv == "builtin" { micMode = "builtin" }
        else if dv.hasPrefix("uid:") && dv.count > 4 { micMode = "uid"; micUID = String(dv.dropFirst(4)) }
        else { micMode = "default" }
    case "--mic-backend": micBackend = argv.next() ?? "auto"
    case "--list-inputs":
        print(listInputsJSON())
        exit(0)
    case "-h", "--help":
        print("usage: audiocap --source system|mic [--device default|builtin|uid:<UID>] [--mic-backend auto|engine|direct] [--seconds N] | --list-inputs")
        exit(0)
    default:
        log("unknown argument \(a)")
        exit(64)
    }
}

var keepAlive: [AnyObject] = []
var micRef: MicCapture?          // for the stall watchdog in the health timer
var micStarted = false           // set once mic.start() returned (startup watchdog)

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
    // Startup watchdog (2026-10-21): at 12:21 the mic start hung for 3.5 min with no log line at
    // all (CoreAudio). If the start does not finish in 10 s, exit, so the recorder starts a fresh one.
    log("mic: starting (permission, device, engine)")
    DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
        if !micStarted { log("mic start hung for 10 s, exiting so the recorder restarts it"); exit(5) }
    }
    guard requestMicAccess() else { log("microphone access denied (System Settings > Privacy > Microphone)"); exit(1) }
    if micBackend == "engine" {
        startEngineMic("engine requested")
    } else {
        // 2026-10-22: direct device capture first. AVAudioEngine hung on start while a call app
        // took the mic (17:08, four 10 s hangs in a row) and gave no buffers from a USB headset
        // in call mode; a plain IOProc worked in both cases.
        startDirectMic("direct capture first")
    }
    micStarted = true
    log("mic input: " + (micMode == "builtin" ? "the Mac's built-in microphone" : (micMode == "uid" ? "chosen input \(micUID)" : "system default input")))
default:
    log("usage: audiocap --source system|mic [--seconds N]")
    exit(64)
}

// Health line every 10 s: frames written and peak level. Peak 0 for a long time = silence or no permission.
var lastHealthFrames: Int64 = 0
let health = DispatchSource.makeTimerSource(queue: .main)
health.schedule(deadline: .now() + 10, repeating: 10)
health.setEventHandler {
    writeQueue.async {
        log(String(format: "health source=%@ frames=%lld peak=%.4f restarts=%lld", source, framesWritten, peakSinceReport, micRestarts))
        peakSinceReport = 0
        // 10 s at 16 kHz = 160000 frames. Much less while IO runs = part of the audio is lost.
        let delta = framesWritten - lastHealthFrames
        lastHealthFrames = framesWritten
        // Stall watchdog (2026-10-21): the input tap can stop delivering buffers with no
        // configuration change notice (Meet reconfiguring the input on unmute). Two health ticks
        // (20 s) with zero mic frames = rebuild the engine.
        if source == "mic" {
            micStallTicks = delta == 0 ? micStallTicks + 1 : 0
            if micStallTicks >= 2 {
                micStallTicks = 0
                DispatchQueue.main.async {
                    if let d = directRef { d.scheduleRestart("stalled: no mic frames for 20 s") }
                    else if micBackend == "auto" { startDirectMic("engine stalled: no mic frames for 20 s") }
                    else { micRef?.scheduleRestart("stalled: no mic frames for 20 s") }
                }
            }
        }
        if source == "system" && delta > 0 && delta < 130000 {
            log(String(format: "WARNING system audio at %.0f%% of real time (%lld frames in 10 s), speech will be chopped",
                       Double(delta) / 1600.0, delta))
        }
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
