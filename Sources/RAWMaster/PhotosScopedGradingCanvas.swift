import AppKit
import SwiftUI
import RAWMasterCore

struct PhotosGradingScope: Hashable {
    let context: EditingInteractionContext
    let region: String
}

/// One frozen region/scope and at most one scalar gesture. The Controller is the recipe owner.
@MainActor final class PhotosGradingInteraction {
    let editing: EditingController
    let context: EditingInteractionContext
    let region: DevelopmentGradingRegion
    private(set) var token: EditingGestureToken?
    private var acceptingInput = true
    init(editing: EditingController, context: EditingInteractionContext, region: DevelopmentGradingRegion) {
        self.editing = editing; self.context = context; self.region = region
    }
    var wheel: DevelopmentGradingWheel {
        (editing.developmentLegacyBasis.color ?? .init()).grading[keyPath: region.path]
    }
    func begin() throws {
        guard acceptingInput else { throw EditingDevelopmentSessionError.staleInteraction }
        guard token == nil else { try editing.developmentSession.validateInteraction(context, gesture: token); return }
        token = try editing.developmentSession.beginGesture(.init(group: nil, name: "legacy.grading." + region.key + ".wheel"), context: context)
    }
    func change(_ value: DevelopmentGradingWheel) throws {
        guard acceptingInput else { throw EditingDevelopmentSessionError.staleInteraction }
        try value.validate()
        try editing.developmentSession.validateInteraction(context, gesture: token)
        guard value != wheel else { return }
        try begin()
        try editing.updateDevelopmentLegacy(context: context, control: "legacy.grading." + region.key + ".wheel", gesture: token, nativeEvent: true) { basis in
            var color = basis.color ?? .init(); color.grading[keyPath: self.region.path] = value; basis.color = color
        }
    }
    func finish() throws {
        guard let token else { return }
        do { try editing.developmentSession.endGesture(token, .commit); self.token = nil }
        catch { cancel(); throw error }
    }
    func cancel() {
        guard let token else { return }; self.token = nil
        guard editing.developmentContext == context, editing.developmentSession.activeGesture == token else { return }
        do { try editing.developmentSession.endGesture(token, .cancel) }
        catch { try? editing.developmentSession.suspend(context: context, disposition: .cancel) }
    }
    func undo(redo: Bool) {
        guard acceptingInput else { return }
        // Undo closes this very gesture through the session, then consumes this captured scope.
        let current = token
        editing.undoDevelopment(context: context, redo: redo)
        if current != nil, editing.developmentSession.activeGesture == current { cancel() }
        else { token = nil }
    }
    func revoke() { acceptingInput = false; cancel() }
}

struct PhotosScopedGradingCanvas: NSViewRepresentable {
    let editing: EditingController
    let context: EditingInteractionContext
    let region: DevelopmentGradingRegion
    let wheel: DevelopmentGradingWheel
    func makeNSView(context: Context) -> PhotosScopedGradingControl { PhotosScopedGradingControl(frame: .zero) }
    func updateNSView(_ view: PhotosScopedGradingControl, context: Context) {
        view.bind(editing: editing, context: self.context, region: region, wheel: wheel)
    }
    static func dismantleNSView(_ view: PhotosScopedGradingControl, coordinator: ()) { view.detach() }
}

/// Reuses the existing wheel drawing and hue/radius conversion. Only ownership/key lifecycle differs.
final class PhotosScopedGradingControl: DevelopmentGradingControl {
    private(set) var owner: PhotosGradingInteraction?
    private(set) var keySequenceID: UUID?
    private var keyCode: UInt16?
    private var keyboardDeadline: Task<Void, Never>?
    private var mouseOwner: PhotosGradingInteraction?
    func bind(editing: EditingController, context: EditingInteractionContext, region: DevelopmentGradingRegion, wheel: DevelopmentGradingWheel) {
        if owner?.context != context || owner?.region.key != region.key {
            cancelTracking()
            owner?.revoke()
            owner = PhotosGradingInteraction(editing: editing, context: context, region: region)
        }
        guard let owner else { return }
        self.wheel = wheel
        onChange = { [weak self, owner] value in
            do { try owner.change(value) }
            catch { if self?.owner === owner { self?.cancelTracking() } }
        }
        interaction = { [weak self, owner] active, _ in
            do { if active { try owner.begin() } else { try owner.finish() } }
            catch { if self?.owner === owner { self?.cancelTracking() } }
        }
        undoAction = { [weak self, owner] in
            guard self?.owner === owner else { return }
            self?.clearKeySequence(); owner.undo(redo: false); self?.cancelTracking()
        }
        redoAction = { [weak self, owner] in
            guard self?.owner === owner else { return }
            self?.clearKeySequence(); owner.undo(redo: true); self?.cancelTracking()
        }
        cancelAction = { [weak self, owner] in
            guard self?.owner === owner else { return }
            self?.clearKeySequence(); owner.cancel()
        }
        setAccessibilityLabel(region.rawValue + "分级色轮")
        setAccessibilityValue("色相 \(wheel.hueDegrees.formatted()) 度，饱和度 \(wheel.saturation.formatted())，亮度 \(wheel.luminance.formatted())")
        needsDisplay = true
    }
    func detach() {
        cancelTracking(); owner?.revoke(); owner = nil; onChange = nil; interaction = nil
        undoAction = nil; redoAction = nil; cancelAction = nil
    }
    override func cancelTracking() {
        mouseOwner = nil; clearKeySequence(); owner?.cancel(); super.cancelTracking()
    }
    override func mouseDown(with event: NSEvent) {
        if let id = keySequenceID { finishKeySequence(id) }
        mouseOwner = owner
        super.mouseDown(with: event)
    }
    override func mouseUp(with event: NSEvent) {
        guard let mouseOwner, mouseOwner === owner else { return }
        self.mouseOwner = nil; super.mouseUp(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if consumesUndo(event) || event.keyCode == 53 { super.keyDown(with: event); return }
        guard !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control),
              [123, 124, 125, 126].contains(event.keyCode) else { super.keyDown(with: event); return }
        // A repeat after a region/scope cancellation cannot start a fresh gesture in the new region.
        if event.isARepeat && keyCode == nil { return }
        if mouseOwner != nil { cancelTracking() }
        if let active = keyCode, active != event.keyCode, let id = keySequenceID { finishKeySequence(id) }
        guard owner != nil else { return }
        if keyCode == nil { keyCode = event.keyCode; keySequenceID = UUID() }
        beginInteraction(); super.keyDown(with: event)
        guard let id = keySequenceID else { return }
        keyboardDeadline?.cancel()
        keyboardDeadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            self?.finishKeySequence(id)
        }
    }
    override func keyUp(with event: NSEvent) {
        guard keyCode == event.keyCode, let id = keySequenceID else { super.keyUp(with: event); return }
        finishKeySequence(id)
    }
    /// Both native key-up and the bounded missing-key-up fallback close the original sequence.
    func finishKeySequence(_ id: UUID) {
        guard keySequenceID == id else { return }
        clearKeySequence(); endInteraction()
    }
    private func clearKeySequence() {
        keyboardDeadline?.cancel(); keyboardDeadline = nil; keyCode = nil; keySequenceID = nil
    }
}
