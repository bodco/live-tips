import Foundation

/// Framing of the audiocap helper's stdout: every frame is a 1-byte kind, a 4-byte little-endian
/// payload length and the payload. Audio frames carry float32 mono 16 kHz samples; heartbeat frames
/// carry a JSON status ({"t":..,"mic":..,"sys":..}). The app restarts the helper when heartbeats stop.
public enum FrameKind: UInt8 {
    case micAudio = 1
    case systemAudio = 2
    case heartbeat = 3
    case log = 4
}

public struct Frame: Equatable {
    public let kind: FrameKind
    public let payload: Data
    public init(kind: FrameKind, payload: Data) {
        self.kind = kind
        self.payload = payload
    }

    public func encoded() -> Data {
        var d = Data([kind.rawValue])
        var n = UInt32(payload.count).littleEndian
        withUnsafeBytes(of: &n) { d.append(contentsOf: $0) }
        d.append(payload)
        return d
    }
}

/// Incremental decoder: feed arbitrary chunks from the pipe, get complete frames out.
public struct FrameDecoder {
    private var buf = Data()
    public private(set) var malformed = 0
    public static let maxPayload = 16 * 1024 * 1024

    public init() {}

    public mutating func feed(_ chunk: Data) -> [Frame] {
        buf.append(chunk)
        var out: [Frame] = []
        while buf.count >= 5 {
            let start = buf.startIndex
            let kindByte = buf[start]
            let len = buf.subdata(in: (start + 1)..<(start + 5)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
            guard let kind = FrameKind(rawValue: kindByte), Int(len) <= FrameDecoder.maxPayload else {
                malformed += 1
                buf.removeFirst()          // resync byte by byte
                continue
            }
            let total = 5 + Int(len)
            guard buf.count >= total else { break }
            out.append(Frame(kind: kind, payload: buf.subdata(in: (start + 5)..<(start + total))))
            buf.removeFirst(total)
        }
        return out
    }
}

/// Decides what to do with the helper from heartbeats and audio activity (pure, testable).
/// Mirrors the live-transcriber watchdog: start guard, stall guard, escalate terminate then kill,
/// growing backoff up to 60 s, switch to the built-in mic after 2 failed restarts in a row.
public struct HelperWatchdog {
    public enum Action: Equatable {
        case none
        case terminate
        case kill
        case restart(afterSeconds: Double)
        case switchToBuiltInMic
    }

    public var startGrace: Double = 10
    public var heartbeatTimeout: Double = 5
    public var stallSeconds: Double = 12
    public var killAfterTerminate: Double = 3
    public private(set) var failedRestartsInRow = 0
    private var terminatedAt: Double?
    private var backoff: Double = 2

    public init() {}

    public mutating func evaluate(now: Double, startedAt: Double, lastHeartbeat: Double?, lastMicAudio: Double?,
                                  micMuted: Bool, alive: Bool) -> Action {
        if let t = terminatedAt {
            if alive && now - t >= killAfterTerminate { return .kill }
            if !alive {
                terminatedAt = nil
                failedRestartsInRow += 1
                if failedRestartsInRow >= 2 {
                    failedRestartsInRow = 0
                    return .switchToBuiltInMic
                }
                let wait = backoff
                backoff = min(backoff * 2, 60)
                return .restart(afterSeconds: wait)
            }
            return .none
        }
        if !alive {
            terminatedAt = now
            return .none
        }
        if now - startedAt < startGrace { return .none }
        let hbStale = lastHeartbeat.map { now - $0 > heartbeatTimeout } ?? true
        let micStalled = !micMuted && (lastMicAudio.map { now - $0 > stallSeconds } ?? true)
        if hbStale || micStalled {
            terminatedAt = now
            return .terminate
        }
        return .none
    }

    /// Real audio arrived after a restart: the episode is over.
    public mutating func recovered() {
        failedRestartsInRow = 0
        backoff = 2
    }
}
