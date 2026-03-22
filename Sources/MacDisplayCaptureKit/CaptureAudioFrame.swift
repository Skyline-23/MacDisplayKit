import Foundation

public enum MDKAudioSampleFormat: String, Codable, Equatable, Sendable {
    case float32Interleaved = "float32-interleaved"
}

public struct MDKAudioFrame: Codable, Equatable, Sendable {
    public let sequenceNumber: UInt64
    public let hostTimeNanoseconds: UInt64
    public let sampleRate: Int
    public let channelCount: Int
    public let frameCount: Int
    public let sampleFormat: MDKAudioSampleFormat
    public let pcmFloat32LE: Data

    public init(
        sequenceNumber: UInt64,
        hostTimeNanoseconds: UInt64,
        sampleRate: Int,
        channelCount: Int,
        frameCount: Int,
        sampleFormat: MDKAudioSampleFormat = .float32Interleaved,
        pcmFloat32LE: Data
    ) {
        self.sequenceNumber = sequenceNumber
        self.hostTimeNanoseconds = hostTimeNanoseconds
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.frameCount = frameCount
        self.sampleFormat = sampleFormat
        self.pcmFloat32LE = pcmFloat32LE
    }
}

public struct MDKAudioCaptureSessionStatistics: Codable, Equatable, Sendable {
    public let emittedFrameCount: UInt64
    public let droppedFrameCount: UInt64
    public let captureFailureCount: UInt64
    public let automaticRestartCount: UInt64
    public let lastErrorDescription: String?
    public let lastStopStatus: Int32?
    public let isRunning: Bool

    public init(
        emittedFrameCount: UInt64 = 0,
        droppedFrameCount: UInt64 = 0,
        captureFailureCount: UInt64 = 0,
        automaticRestartCount: UInt64 = 0,
        lastErrorDescription: String? = nil,
        lastStopStatus: Int32? = nil,
        isRunning: Bool = false
    ) {
        self.emittedFrameCount = emittedFrameCount
        self.droppedFrameCount = droppedFrameCount
        self.captureFailureCount = captureFailureCount
        self.automaticRestartCount = automaticRestartCount
        self.lastErrorDescription = lastErrorDescription
        self.lastStopStatus = lastStopStatus
        self.isRunning = isRunning
    }
}

public enum MDKAudioCaptureSessionEventKind: String, Codable, Equatable, Sendable {
    case started
    case stopped
    case restarted
    case failed
    case droppedFrame
}

public struct MDKAudioCaptureSessionEvent: Codable, Equatable, Sendable {
    public let kind: MDKAudioCaptureSessionEventKind
    public let message: String?
    public let stopStatus: Int32?
    public let automaticRestartCount: UInt64?
    public let sourceSequenceNumber: UInt64?

    public init(
        kind: MDKAudioCaptureSessionEventKind,
        message: String? = nil,
        stopStatus: Int32? = nil,
        automaticRestartCount: UInt64? = nil,
        sourceSequenceNumber: UInt64? = nil
    ) {
        self.kind = kind
        self.message = message
        self.stopStatus = stopStatus
        self.automaticRestartCount = automaticRestartCount
        self.sourceSequenceNumber = sourceSequenceNumber
    }
}

public struct MDKAudioCaptureCallbacks: Sendable {
    public let frameHandler: @Sendable (MDKAudioFrame) -> Void
    public let eventHandler: (@Sendable (MDKAudioCaptureSessionEvent) -> Void)?

    public init(
        frameHandler: @escaping @Sendable (MDKAudioFrame) -> Void,
        eventHandler: (@Sendable (MDKAudioCaptureSessionEvent) -> Void)? = nil
    ) {
        self.frameHandler = frameHandler
        self.eventHandler = eventHandler
    }
}

public enum MDKAudioCaptureSessionError: Error, LocalizedError, Equatable {
    case alreadyRunning
    case callbackRequiredForCallbackOnlyMode
    case frameStreamUnsupportedInCallbackOnlyMode
    case inputUnavailable(description: String)
    case captureFailed(description: String)
    case restartLimitReached(lastErrorDescription: String)

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "Audio capture session is already running."
        case .callbackRequiredForCallbackOnlyMode:
            return "Audio capture session requires callbacks when delivery mode is callback-only."
        case .frameStreamUnsupportedInCallbackOnlyMode:
            return "Audio capture session does not support frame streams when delivery mode is callback-only."
        case .inputUnavailable(let description):
            return "Audio capture input unavailable: \(description)"
        case .captureFailed(let description):
            return "Audio capture failed: \(description)"
        case .restartLimitReached(let lastErrorDescription):
            return "Audio capture exhausted its automatic restarts. Last error: \(lastErrorDescription)"
        }
    }
}
