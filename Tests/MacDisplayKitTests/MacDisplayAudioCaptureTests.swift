import XCTest
@testable import MacDisplayCaptureKit

final class MacDisplayAudioCaptureTests: XCTestCase {
    func testAudioCaptureConfigurationDefaultsToStereoPCM() {
        let configuration = MDKAudioCaptureConfiguration.microphone()

        if case .microphone(let inputID) = configuration.source {
            XCTAssertNil(inputID)
        } else {
            XCTFail("Expected microphone source.")
        }
        XCTAssertEqual(configuration.sampleRate, 48_000)
        XCTAssertEqual(configuration.channelCount, 2)
        XCTAssertEqual(configuration.frameSize, 480)
        XCTAssertEqual(configuration.deliveryMode, .multiplexed)
    }

    func testAudioCaptureSessionRequiresCallbacksForCallbackOnlyMode() async {
        let session = makeSession(
            configuration: MDKAudioCaptureConfiguration.microphone(deliveryMode: .callbackOnly)
        )

        do {
            try await session.start()
            XCTFail("Expected callback-only audio session start to fail without callbacks.")
        } catch let error as MDKAudioCaptureSessionError {
            XCTAssertEqual(error, .callbackRequiredForCallbackOnlyMode)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testAudioCaptureSessionStreamsFramesFromSource() async throws {
        let source = TestAudioSource()
        let session = makeSession(source: source)
        let stream = await session.frames()
        var iterator = stream.makeAsyncIterator()

        try await session.start()
        source.emit(frame: Self.makeFrame(sequenceNumber: 1, frameCount: 240))

        let frame = try await iterator.next()
        XCTAssertEqual(frame?.sequenceNumber, 1)
        XCTAssertEqual(frame?.frameCount, 240)
        XCTAssertEqual(frame?.channelCount, 2)

        await session.stop()
    }

    func testAudioCaptureSessionInvokesCallbacks() async throws {
        let source = TestAudioSource()
        let recorder = AudioCallbackRecorder()
        let session = makeSession(source: source)

        try await session.start(
            callbacks: MDKAudioCaptureCallbacks(
                frameHandler: { frame in
                    Task {
                        await recorder.record(frame: frame)
                    }
                },
                eventHandler: { event in
                    Task {
                        await recorder.record(event: event)
                    }
                }
            )
        )

        source.emit(frame: Self.makeFrame(sequenceNumber: 7, frameCount: 128))
        try await Task.sleep(nanoseconds: 30_000_000)

        let frameSequenceNumbers = await recorder.frameSequenceNumbers
        let eventKinds = await recorder.eventKinds
        XCTAssertEqual(frameSequenceNumbers, [7])
        XCTAssertEqual(eventKinds.first, .started)

        await session.stop()
        try await Task.sleep(nanoseconds: 30_000_000)
        let finalEventKinds = await recorder.eventKinds
        XCTAssertEqual(finalEventKinds.last, .stopped)
    }

    func testAudioCaptureSessionDropsFramesWithoutConsumerStream() async throws {
        let source = TestAudioSource()
        let session = makeSession(source: source)

        try await session.start()
        source.emit(frame: Self.makeFrame(sequenceNumber: 3, frameCount: 64))
        try await Task.sleep(nanoseconds: 20_000_000)

        let statistics = await session.statisticsSnapshot()
        XCTAssertEqual(statistics.emittedFrameCount, 0)
        XCTAssertEqual(statistics.droppedFrameCount, 1)

        await session.stop()
    }
}

private extension MacDisplayAudioCaptureTests {
    static func makeFrame(sequenceNumber: UInt64, frameCount: Int) -> MDKAudioFrame {
        let floatCount = frameCount * 2
        let samples = Array(repeating: Float(sequenceNumber), count: floatCount)
        let data = samples.withUnsafeBufferPointer {
            Data(buffer: $0)
        }
        return MDKAudioFrame(
            sequenceNumber: sequenceNumber,
            hostTimeNanoseconds: sequenceNumber * 1_000_000,
            sampleRate: 48_000,
            channelCount: 2,
            frameCount: frameCount,
            pcmFloat32LE: data
        )
    }

    func makeSession(
        configuration: MDKAudioCaptureConfiguration = MDKAudioCaptureConfiguration.microphone(),
        source: TestAudioSource = TestAudioSource()
    ) -> MDKAudioCaptureSession {
        MDKAudioCaptureSession(
            configuration: configuration,
            sourceFactory: { _, frameHandler, _ in
                source.frameHandler = frameHandler
                return source
            }
        )
    }
}

private final class TestAudioSource: MDKAudioCaptureSourceRuntime, @unchecked Sendable {
    var frameHandler: (@Sendable (MDKAudioFrame) -> Void)?
    private(set) var started = false

    func start() async throws {
        started = true
    }

    func stop() async -> Int32 {
        started = false
        return 0
    }

    func emit(frame: MDKAudioFrame) {
        frameHandler?(frame)
    }
}

private actor AudioCallbackRecorder {
    private(set) var frameSequenceNumbers: [UInt64] = []
    private(set) var eventKinds: [MDKAudioCaptureSessionEventKind] = []

    func record(frame: MDKAudioFrame) {
        frameSequenceNumbers.append(frame.sequenceNumber)
    }

    func record(event: MDKAudioCaptureSessionEvent) {
        eventKinds.append(event.kind)
    }
}
