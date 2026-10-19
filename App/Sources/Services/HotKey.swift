#if os(macOS)
import Carbon.HIToolbox
import Foundation

/// A global keyboard shortcut (default ⌘⇧Space) that works without Accessibility permission,
/// using Carbon's RegisterEventHotKey.
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    nonisolated(unsafe) private static var registry: [UInt32: HotKey] = [:]
    nonisolated(unsafe) private static var nextID: UInt32 = 1

    init(keyCode: UInt32 = UInt32(kVK_Space), modifiers: UInt32 = UInt32(cmdKey | shiftKey), action: @escaping () -> Void) {
        self.action = action
        let id = Self.nextID
        Self.nextID += 1
        Self.registry[id] = self
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            DispatchQueue.main.async { HotKey.registry[hotKeyID.id]?.action() }
            return noErr
        }, 1, &spec, nil, &handler)
        RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: OSType(0x5452_5645), id: id), GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}
#endif
