import AVFoundation
import Foundation
import KuzmemoCore
import Observation

/// The settings window's "check the microphone and recognition": records a few seconds from the real microphone and
/// shows what the current model made of it and how long that took. It creates no memo and touches no calendar data.
@MainActor
@Observable
final class RecognitionTester {
    enum State: Equatable {
        case idle
        case recording(elapsed: Double, of: Double)
        case recognizing
        case done(text: String, audioSeconds: Double, milliseconds: Int)
        case nothingHeard(String)
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var level: Float = 0

    var isBusy: Bool {
        switch state {
        case .recording, .recognizing: true
        default: false
        }
    }

    func run(env: AppEnvironment, seconds: Double = 5) async {
        guard !isBusy else { return }
        guard !env.voice.isRecording else {
            state = .failed(tr("A regular recording is in progress: wait for it to finish."))
            return
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await env.voice.permissions.requestMicrophone()
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            state = .failed(tr("No microphone access. Allow it in System Settings → Privacy & Security → Microphone."))
            return
        }

        let mic = MicCapture()
        let meter = LevelMeter()
        mic.onLevel = { meter.record($0) }
        do { try mic.start() } catch {
            state = .failed(tr("Could not turn on the microphone: %1$@", "\(error)"))
            return
        }
        let started = Date()
        while Date().timeIntervalSince(started) < seconds {
            try? await Task.sleep(for: .milliseconds(50))
            level = max(meter.takePeak(), level * 0.7)
            state = .recording(elapsed: Date().timeIntervalSince(started), of: seconds)
        }
        let samples = mic.stop()
        level = 0
        state = .recognizing

        let began = Date()
        switch await env.voice.recognizeForTest(samples) {
        case let .success(.speech(output)):
            state = .done(text: output.text, audioSeconds: output.audioSeconds, milliseconds: Int(Date().timeIntervalSince(began) * 1000))
        case let .success(.noSpeech(reason)):
            state = .nothingHeard(reason)
        case let .failure(error):
            state = .failed(tr("Could not recognize: %1$@", "\(error)"))
        }
    }
}
