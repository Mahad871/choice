import AppKit
import Carbon

func checkGlobalShortcut() {
    _ = NSApplication.shared
    let shortcut = GlobalShortcut()
    var config = ShortcutConfiguration()
    config.enabled = true
    config.shift = true
    config.key = "J"
    assert(shortcut.configure(config) == nil)
    let competing = GlobalShortcut()
    assert(competing.configure(config) != nil, "A conflicting shortcut must be rejected")

    var calls = 0
    shortcut.onInvoke = { calls += 1 }
    var event: EventRef?
    assert(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed),
                       0, 0, &event) == noErr)
    guard let event else { fatalError("Could not create the shortcut event") }
    defer { ReleaseEvent(event) }
    var identifier = EventHotKeyID(signature: 0x4D696343, id: 1)
    assert(SetEventParameter(event, EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &identifier) == noErr)
    assert(SendEventToEventTarget(event, GetApplicationEventTarget()) == noErr)
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    assert(calls == 1, "The registered event must invoke the action exactly once")

    var invalid = config
    invalid.control = false
    invalid.command = false
    assert(shortcut.configure(invalid) != nil)
    assert(shortcut.status == config.displayName, "A rejected edit must preserve the active shortcut")
    var changed = config
    changed.key = "K"
    assert(shortcut.configure(changed) == nil)
    assert(competing.configure(config) == nil, "Changing shortcuts must release the old key")
    changed.enabled = false
    assert(shortcut.configure(changed) == nil)
    assert(shortcut.status == "Off")
    config.enabled = false
    assert(competing.configure(config) == nil)
    assert(SendEventToEventTarget(event, GetApplicationEventTarget()) == OSStatus(eventNotHandledErr))
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    assert(calls == 1, "A disabled shortcut must not invoke its action")
    // The microphone shortcut (id 1) and the window-fill shortcut (id 2) each handle
    // only their own key press.
    let microphone = GlobalShortcut(identifier: 1)
    let fill = GlobalShortcut(identifier: 2)
    var microphoneCalls = 0
    var fillCalls = 0
    microphone.onInvoke = { microphoneCalls += 1 }
    fill.onInvoke = { fillCalls += 1 }
    var microphoneConfig = ShortcutConfiguration(enabled: true, control: true, option: true,
                                                 shift: true, command: false, key: "M")
    assert(microphone.configure(microphoneConfig) == nil)
    var fillConfig = microphoneConfig
    fillConfig.key = "F"
    assert(fill.configure(fillConfig) == nil)
    var fillIdentifier = EventHotKeyID(signature: 0x4D696343, id: 2)
    assert(SetEventParameter(event, EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &fillIdentifier) == noErr)
    assert(SendEventToEventTarget(event, GetApplicationEventTarget()) == noErr)
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    assert(fillCalls == 1 && microphoneCalls == 0, "Only the fill shortcut must respond to its key")
    microphoneConfig.enabled = false
    fillConfig.enabled = false
    microphone.configure(microphoneConfig)
    fill.configure(fillConfig)
    print("Shortcut registration, dispatch, conflicts, and cleanup passed")
}
