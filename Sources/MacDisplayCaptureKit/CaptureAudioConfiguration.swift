import Foundation

public enum MDKAudioCaptureSource: Equatable, Sendable, Codable {
    case microphone(inputID: String?)
    case systemOutput(displayID: UInt32, excludesCurrentProcessAudio: Bool)

    private enum CodingKeys: String, CodingKey {
        case kind
        case inputID = "input-id"
        case displayID = "display-id"
        case excludesCurrentProcessAudio = "excludes-current-process-audio"
    }

    private enum Kind: String, Codable {
        case microphone
        case systemOutput = "system-output"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .microphone(let inputID):
            try container.encode(Kind.microphone, forKey: .kind)
            try container.encodeIfPresent(inputID, forKey: .inputID)
        case .systemOutput(let displayID, let excludesCurrentProcessAudio):
            try container.encode(Kind.systemOutput, forKey: .kind)
            try container.encode(displayID, forKey: .displayID)
            try container.encode(excludesCurrentProcessAudio, forKey: .excludesCurrentProcessAudio)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .microphone:
            self = .microphone(inputID: try container.decodeIfPresent(String.self, forKey: .inputID))
        case .systemOutput:
            self = .systemOutput(
                displayID: try container.decode(UInt32.self, forKey: .displayID),
                excludesCurrentProcessAudio: try container.decodeIfPresent(Bool.self, forKey: .excludesCurrentProcessAudio) ?? false
            )
        }
    }
}

public typealias MDKAudioCaptureDeliveryMode = MDKEncodedCaptureDeliveryMode
public typealias MDKAudioCaptureBackpressurePolicy = MDKEncodedCaptureBackpressurePolicy
public typealias MDKAudioCaptureRecoveryPolicy = MDKEncodedCaptureRecoveryPolicy

public struct MDKAudioCaptureConfiguration: Codable, Equatable, Sendable {
    public let source: MDKAudioCaptureSource
    public let sampleRate: Int
    public let channelCount: Int
    public let frameSize: Int
    public let deliveryMode: MDKAudioCaptureDeliveryMode
    public let backpressurePolicy: MDKAudioCaptureBackpressurePolicy
    public let recoveryPolicy: MDKAudioCaptureRecoveryPolicy

    public init(
        source: MDKAudioCaptureSource,
        sampleRate: Int = 48_000,
        channelCount: Int = 2,
        frameSize: Int = 480,
        deliveryMode: MDKAudioCaptureDeliveryMode = .multiplexed,
        backpressurePolicy: MDKAudioCaptureBackpressurePolicy = .dropOldest(limit: 8),
        recoveryPolicy: MDKAudioCaptureRecoveryPolicy = MDKAudioCaptureRecoveryPolicy()
    ) {
        self.source = source
        self.sampleRate = max(sampleRate, 1)
        self.channelCount = max(channelCount, 1)
        self.frameSize = max(frameSize, 1)
        self.deliveryMode = deliveryMode
        self.backpressurePolicy = backpressurePolicy
        self.recoveryPolicy = recoveryPolicy
    }

    public static func microphone(
        inputID: String? = nil,
        sampleRate: Int = 48_000,
        channelCount: Int = 2,
        frameSize: Int = 480,
        deliveryMode: MDKAudioCaptureDeliveryMode = .multiplexed,
        backpressurePolicy: MDKAudioCaptureBackpressurePolicy = .dropOldest(limit: 8),
        recoveryPolicy: MDKAudioCaptureRecoveryPolicy = MDKAudioCaptureRecoveryPolicy()
    ) -> Self {
        Self(
            source: .microphone(inputID: inputID),
            sampleRate: sampleRate,
            channelCount: channelCount,
            frameSize: frameSize,
            deliveryMode: deliveryMode,
            backpressurePolicy: backpressurePolicy,
            recoveryPolicy: recoveryPolicy
        )
    }

    public static func systemOutput(
        displayID: UInt32,
        sampleRate: Int = 48_000,
        channelCount: Int = 2,
        frameSize: Int = 480,
        excludesCurrentProcessAudio: Bool = false,
        deliveryMode: MDKAudioCaptureDeliveryMode = .multiplexed,
        backpressurePolicy: MDKAudioCaptureBackpressurePolicy = .dropOldest(limit: 8),
        recoveryPolicy: MDKAudioCaptureRecoveryPolicy = MDKAudioCaptureRecoveryPolicy()
    ) -> Self {
        Self(
            source: .systemOutput(
                displayID: displayID,
                excludesCurrentProcessAudio: excludesCurrentProcessAudio
            ),
            sampleRate: sampleRate,
            channelCount: channelCount,
            frameSize: frameSize,
            deliveryMode: deliveryMode,
            backpressurePolicy: backpressurePolicy,
            recoveryPolicy: recoveryPolicy
        )
    }
}
