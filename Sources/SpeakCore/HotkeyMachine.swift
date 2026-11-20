import Foundation

/// Gesture model for a single dictation key (Fn, Right Option, ...).
///
/// * Hold the key  -> push-to-talk: recording starts on key-down (zero added latency),
///                    text is committed on key-up.
/// * Double-tap    -> hands-free: recording continues until the key is tapped again.
/// * A single short tap that is not followed by a second tap is discarded, so
///   brushing the key never types anything.
/// * Pressing any other key while holding (e.g. Fn+Arrow) cancels: the user was
///   using the key as a modifier, not dictating.
/// * Escape cancels any active recording.
public struct HotkeyMachine: Sendable {
    public enum Action: Equatable, Sendable {
        case start          // begin capturing audio now
        case commit         // stop and insert text
        case cancel         // stop and discard
        case scheduleTapTimeout(TimeInterval) // call `tapTimeout()` after this delay
    }

    public enum State: Equatable, Sendable {
        case idle
        case pressed(since: TimeInterval)       // key down, recording
        case awaitingSecondTap(since: TimeInterval) // short tap released, still recording
        case handsFree                           // locked on
    }

    public var holdThreshold: TimeInterval
    public var doubleTapWindow: TimeInterval
    public private(set) var state: State = .idle

    public init(holdThreshold: TimeInterval = 0.28, doubleTapWindow: TimeInterval = 0.32) {
        self.holdThreshold = holdThreshold
        self.doubleTapWindow = doubleTapWindow
    }

    public mutating func keyDown(at t: TimeInterval) -> [Action] {
        switch state {
        case .idle:
            state = .pressed(since: t)
            return [.start]
        case .awaitingSecondTap:
            state = .handsFree
            return []
        case .handsFree:
            state = .idle
            return [.commit]
        case .pressed:
            return [] // auto-repeat / duplicate flag events
        }
    }

    public mutating func keyUp(at t: TimeInterval) -> [Action] {
        guard case .pressed(let since) = state else { return [] }
        if t - since >= holdThreshold {
            state = .idle
            return [.commit]
        }
        state = .awaitingSecondTap(since: t)
        return [.scheduleTapTimeout(doubleTapWindow)]
    }

    /// Called when the double-tap window elapses.
    public mutating func tapTimeout() -> [Action] {
        guard case .awaitingSecondTap = state else { return [] }
        state = .idle
        return [.cancel]
    }

    /// Any non-hotkey key went down.
    public mutating func otherKeyDown() -> [Action] {
        switch state {
        case .pressed, .awaitingSecondTap:
            state = .idle
            return [.cancel]
        default:
            return []
        }
    }

    public mutating func escape() -> [Action] {
        guard state != .idle else { return [] }
        state = .idle
        return [.cancel]
    }

    /// External stop (e.g. engine error). Resets without emitting actions.
    public mutating func reset() { state = .idle }
}
