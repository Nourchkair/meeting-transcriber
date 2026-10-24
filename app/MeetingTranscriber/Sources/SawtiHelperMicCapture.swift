import AudioTapLib
import Darwin
import Foundation
import os.log

private let helperCaptureLogger = Logger(subsystem: AppPaths.logSubsystem, category: "CaptureHelper")

struct SawtiCaptureHelperEvent: Decodable, Sendable {
    let type: String
    let code: String?
    let levelDBFS: Double?
    let secondsSinceLastBuffer: Double?
    let secondsSinceLastEnergy: Double?
}

/// Receives newline-delimited status from the child process. The channel holds
/// only bounded health/control state; transcript text and audio never cross it.
final class SawtiCaptureHelperEventReader: @unchecked Sendable {
    private let condition = NSCondition()
    private var remainder = Data()
    private var hasReady = false
    private var hasStopped = false
    private var didClose = false
    private var processTerminated = false
    private var stopRequested = false
    private var startupError: String?
    private var latestLevelDBFS = -120.0
    private var latestSignalAges = ChannelSignalAges.unknown
    private var captureGaveUp = false
    private var readHandle: FileHandle?

    func attach(to handle: FileHandle) {
        readHandle = handle
        handle.readabilityHandler = { [weak self] readableHandle in
            let data = readableHandle.availableData
            if data.isEmpty {
                self?.ingestEOF()
            } else {
                self?.ingest(data)
            }
        }
    }

    func ingest(_ data: Data) {
        condition.lock()
        remainder.append(data)
        while let newline = remainder.firstIndex(of: 0x0A) {
            let line = Data(remainder[..<newline])
            remainder.removeSubrange(...newline)
            if let event = try? JSONDecoder().decode(SawtiCaptureHelperEvent.self, from: line) {
                apply(event)
            }
        }
        condition.broadcast()
        condition.unlock()
    }

    func ingestEOF() {
        condition.lock()
        didClose = true
        condition.broadcast()
        condition.unlock()
    }

    func requestStop() {
        condition.lock()
        stopRequested = true
        condition.unlock()
    }

    func ingestProcessTermination() {
        condition.lock()
        processTerminated = true
        condition.broadcast()
        condition.unlock()
    }

    func waitForReady(timeout: TimeInterval) -> String? {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !hasReady, startupError == nil, !didClose {
            guard condition.wait(until: deadline) else { break }
        }
        return hasReady ? nil : (startupError ?? "helper_start_timeout")
    }

    func waitForStopped(timeout: TimeInterval) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !hasStopped, !didClose {
            guard condition.wait(until: deadline) else { break }
        }
        return hasStopped
    }

    func closeReadHandle() {
        readHandle?.readabilityHandler = nil
        try? readHandle?.close()
        readHandle = nil
    }

    var health: (levelDBFS: Double, ages: ChannelSignalAges, gaveUp: Bool) {
        condition.lock()
        defer { condition.unlock() }
        let exitedUnexpectedly = processTerminated && !stopRequested && !hasStopped
        return (latestLevelDBFS, latestSignalAges, captureGaveUp || exitedUnexpectedly)
    }

    private func apply(_ event: SawtiCaptureHelperEvent) {
        switch event.type {
        case "ready": hasReady = true
        case "stopped": hasStopped = true
        case "error": startupError = event.code ?? "helper_start_failed"
        case "gave_up": captureGaveUp = true
        case "health":
            if let level = event.levelDBFS { latestLevelDBFS = level }
            latestSignalAges = ChannelSignalAges(
                secondsSinceLastBuffer: event.secondsSinceLastBuffer,
                secondsSinceLastEnergy: event.secondsSinceLastEnergy,
            )
        default: break
        }
    }
}

/// Process-isolated microphone capture for Sawti's in-person workflow.
/// App-audio and dual-source meeting capture continue through AudioTapLib in
/// the host process until that topology passes its own Beta validation.
@MainActor
final class SawtiHelperMicCapture: AudioCapturing {
    private let configuration: AudioCaptureConfiguration
    private let helperURL: URL
    private var process: Process?
    private var inputPipe: Pipe?
    private var eventReader: SawtiCaptureHelperEventReader?
    private var termination: DispatchSemaphore?
    private var helperFailedToStop = false
    private var ownsOutput = false

    init(
        configuration: AudioCaptureConfiguration,
        helperURL: URL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/SawtiCaptureHelper"),
    ) {
        self.configuration = configuration
        self.helperURL = helperURL
    }

    var appLevelDBFS: Double {
        -120
    }

    var micLevelDBFS: Double {
        eventReader?.health.levelDBFS ?? -120
    }

    var appCaptureGaveUp: Bool {
        false
    }

    var micCaptureGaveUp: Bool {
        helperFailedToStop || (eventReader?.health.gaveUp ?? false)
    }

    var appSilentTrackWatchdogGaveUp: Bool {
        false
    }

    var appSignalAges: ChannelSignalAges {
        .unknown
    }

    var micSignalAges: ChannelSignalAges {
        eventReader?.health.ages ?? .unknown
    }

    func start() throws {
        guard configuration.appOutputURL == nil,
              let outputURL = configuration.micOutputURL
        else { throw SawtiHelperCaptureError.unsupportedTrackLayout }
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw SawtiHelperCaptureError.helperUnavailable
        }
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw SawtiHelperCaptureError.outputAlreadyExists
        }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let reader = SawtiCaptureHelperEventReader()
        let termination = DispatchSemaphore(value: 0)
        process.executableURL = helperURL
        process.arguments = ["--output", outputURL.path]
        if let deviceUID = configuration.micDeviceUID, !deviceUID.isEmpty {
            process.arguments?.append(contentsOf: ["--device-uid", deviceUID])
        }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in
            reader.ingestProcessTermination()
            termination.signal()
        }
        reader.attach(to: output.fileHandleForReading)

        do {
            try process.run()
        } catch {
            reader.closeReadHandle()
            throw SawtiHelperCaptureError.helperLaunchFailed
        }

        self.process = process
        inputPipe = input
        eventReader = reader
        self.termination = termination
        ownsOutput = true
        if let errorCode = reader.waitForReady(timeout: 12) {
            terminateHelper(process, termination: termination)
            reader.closeReadHandle()
            self.process = nil
            inputPipe = nil
            eventReader = nil
            self.termination = nil
            removeOwnedOutput(outputURL)
            throw SawtiHelperCaptureError.helperStartupFailed(errorCode)
        }
        helperCaptureLogger.info("microphone_helper_started")
    }

    func stop() -> AudioCaptureResult {
        guard let outputURL = configuration.micOutputURL else {
            return emptyResult()
        }
        guard let process, let inputPipe, let eventReader, let termination else {
            return AudioCaptureResult(
                appAudioFileURL: nil,
                micAudioFileURL: FileManager.default.fileExists(atPath: outputURL.path) ? outputURL : nil,
                actualSampleRate: AudioConstants.targetSampleRate,
                actualChannels: 1,
                micDelay: 0,
            )
        }

        // EOF is the stop command. Avoid writing to a pipe whose helper may
        // already have exited: a broken pipe can deliver SIGPIPE to the app.
        eventReader.requestStop()
        try? inputPipe.fileHandleForWriting.close()
        let reportedStopped = eventReader.waitForStopped(timeout: 8)
        let exited = termination.wait(timeout: .now() + 2) == .success
        if !exited {
            helperFailedToStop = true
            terminateHelper(process, termination: termination)
        }
        if !reportedStopped { helperFailedToStop = true }
        eventReader.closeReadHandle()
        self.process = nil
        self.inputPipe = nil
        self.eventReader = nil
        self.termination = nil
        return AudioCaptureResult(
            appAudioFileURL: nil,
            micAudioFileURL: FileManager.default.fileExists(atPath: outputURL.path) ? outputURL : nil,
            actualSampleRate: AudioConstants.targetSampleRate,
            actualChannels: 1,
            micDelay: 0,
        )
    }

    private func emptyResult() -> AudioCaptureResult {
        AudioCaptureResult(
            appAudioFileURL: nil,
            micAudioFileURL: nil,
            actualSampleRate: AudioConstants.targetSampleRate,
            actualChannels: 1,
            micDelay: 0,
        )
    }

    private func removeOwnedOutput(_ url: URL) {
        guard ownsOutput else { return }
        try? FileManager.default.removeItem(at: url)
        ownsOutput = false
    }

    private func terminateHelper(_ process: Process, termination: DispatchSemaphore) {
        guard process.isRunning else { return }
        process.terminate()
        if termination.wait(timeout: .now() + 2) == .timedOut {
            _ = kill(process.processIdentifier, SIGKILL)
            _ = termination.wait(timeout: .now() + 1)
        }
    }
}

enum SawtiHelperCaptureError: LocalizedError {
    case unsupportedTrackLayout
    case helperUnavailable
    case outputAlreadyExists
    case helperLaunchFailed
    case helperStartupFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedTrackLayout: "The microphone helper only supports microphone-only recordings."
        case .helperUnavailable: "Sawti's microphone capture helper is missing. Rebuild Sawti and try again."
        case .outputAlreadyExists: "Sawti refused to overwrite an existing recording file."
        case .helperLaunchFailed: "Sawti could not start its microphone capture helper."
        case let .helperStartupFailed(code): "Sawti's microphone helper could not start (\(code)). Check microphone permission and try again."
        }
    }
}
