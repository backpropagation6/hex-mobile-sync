import AVFAudio
import Foundation
import Speech

/// Microphone and speech recognition authorization.
///
/// The request functions are nonisolated: the system calls their completion
/// handlers on arbitrary queues, so the handlers must not inherit main-actor
/// isolation.
enum Permissions {
    enum Status: Equatable {
        case granted
        case denied
        case undetermined
    }

    static var microphone: Status {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: .granted
        case .denied: .denied
        case .undetermined: .undetermined
        @unknown default: .undetermined
        }
    }

    static var speech: Status {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: .granted
        case .denied, .restricted: .denied
        case .notDetermined: .undetermined
        @unknown default: .undetermined
        }
    }

    /// Requests microphone access if needed. Returns whether it is granted.
    nonisolated static func requestMicrophone() async -> Bool {
        if AVAudioApplication.shared.recordPermission == .granted { return true }
        return await AVAudioApplication.requestRecordPermission()
    }

    /// Requests speech recognition access if needed. Returns whether it is granted.
    nonisolated static func requestSpeech() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .authorized { return true }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}
