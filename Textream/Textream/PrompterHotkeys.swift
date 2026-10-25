//
//  PrompterHotkeys.swift
//  Textream
//
//  System-wide shortcuts while the prompter is showing, so the speaker can
//  control it from whatever app is recording or presenting:
//    ⌃⌥P  pause / resume
//    ⌃⌥←  back one phrase
//    ⌃⌥→  forward one phrase
//  Carbon hot keys need no Accessibility permission and work in the sandbox.
//  They are registered only while the prompter is on screen, so the keys stay
//  free for other apps the rest of the time.
//

import Carbon.HIToolbox
import OSLog

final class PrompterHotkeys {
    enum Action: UInt32, CaseIterable {
        case togglePause = 1
        case previousPhrase
        case nextPhrase

        var keyCode: UInt32 {
            switch self {
            case .togglePause: return UInt32(kVK_ANSI_P)
            case .previousPhrase: return UInt32(kVK_LeftArrow)
            case .nextPhrase: return UInt32(kVK_RightArrow)
            }
        }

        var label: String {
            switch self {
            case .togglePause: return "⌃⌥P"
            case .previousPhrase: return "⌃⌥←"
            case .nextPhrase: return "⌃⌥→"
            }
        }
    }

    static let shared = PrompterHotkeys()

    private static let signature: OSType = 0x4E_43_48_4B // "NCHK"
    private static let modifiers = UInt32(controlKey | optionKey)
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app.notchcue.mac", category: "Hotkeys")

    private var hotKeys: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?
    private var onAction: ((Action) -> Void)?

    func register(_ onAction: @escaping (Action) -> Void) {
        unregister()
        self.onAction = onAction

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr,
                      hotKeyID.signature == PrompterHotkeys.signature,
                      let action = Action(rawValue: hotKeyID.id) else {
                    return OSStatus(eventNotHandledErr)
                }
                let hotkeys = Unmanaged<PrompterHotkeys>.fromOpaque(userData).takeUnretainedValue()
                // Carbon delivers hot key events on the main thread.
                MainActor.assumeIsolated {
                    hotkeys.onAction?(action)
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard installStatus == noErr else {
            logger.error("Couldn't install the hot key handler: \(installStatus)")
            return
        }

        for action in Action.allCases {
            var hotKey: EventHotKeyRef?
            let status = RegisterEventHotKey(
                action.keyCode,
                Self.modifiers,
                EventHotKeyID(signature: Self.signature, id: action.rawValue),
                GetApplicationEventTarget(),
                0,
                &hotKey
            )
            if status == noErr, let hotKey {
                hotKeys.append(hotKey)
            } else {
                // Another app already owns the combination.
                logger.warning("Couldn't register \(action.label, privacy: .public): \(status)")
            }
        }
    }

    func unregister() {
        for hotKey in hotKeys {
            UnregisterEventHotKey(hotKey)
        }
        hotKeys = []
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
        eventHandler = nil
        onAction = nil
    }
}
