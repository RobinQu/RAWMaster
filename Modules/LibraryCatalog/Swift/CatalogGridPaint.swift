#if os(macOS)
import AppKit
import SwiftUI

/// AppKit drawing boundary, delivered after the visible grid cells in a draw pass have reported.
@MainActor
public final class CatalogGridPaintRecorder {
    public struct Sample: Encodable, Sendable {
        public let startNanoseconds: UInt64
        public let drawNanoseconds: UInt64
        public let milliseconds: Double
        public let visibleCardsDrawn: Int
        public let cardsWithPhotoDrawn: Int
        public let empty: Bool
    }

    private let receive: (Sample) -> Void
    private var startedAt: UInt64 = 0
    private var lastDraw: UInt64 = 0
    private var submitted = false
    private var cards = Set<String>()
    private var images = Set<String>()
    private var empty = false

    public init(receive: @escaping (Sample) -> Void) { self.receive = receive }

    fileprivate func draw(start: UInt64, card: String?, photo: Bool) {
        guard start > 0, start >= startedAt else { return }
        if start != startedAt {
            startedAt = start
            cards.removeAll(keepingCapacity: true)
            images.removeAll(keepingCapacity: true)
            empty = false
            submitted = false
        }
        let changed: Bool
        if let card {
            let newCard = cards.insert(card).inserted
            let newPhoto = photo && images.insert(card).inserted
            changed = newCard || newPhoto
        } else {
            changed = !empty
            empty = true
        }
        guard changed else { return }
        lastDraw = DispatchTime.now().uptimeNanoseconds
        guard !submitted else { return }
        submitted = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.startedAt == start else { return }
            self.submitted = false
            let end = self.lastDraw
            self.receive(Sample(startNanoseconds: start, drawNanoseconds: end,
                milliseconds: Double(end - start) / 1_000_000,
                visibleCardsDrawn: self.cards.count, cardsWithPhotoDrawn: self.images.count,
                empty: self.empty))
        }
    }
}

public struct CatalogGridPaintMark: NSViewRepresentable {
    private let start: UInt64
    private let cardID: String?
    private let photo: Bool
    private let recorder: CatalogGridPaintRecorder

    /// Pass a nil ID only for the completed empty result view.
    public init(start: UInt64, cardID: String?, photo: Bool, recorder: CatalogGridPaintRecorder) {
        self.start = start
        self.cardID = cardID
        self.photo = photo
        self.recorder = recorder
    }

    public final class Marker: NSView {
        fileprivate weak var recorder: CatalogGridPaintRecorder?
        fileprivate var start: UInt64 = 0
        fileprivate var cardID: String?
        fileprivate var photo = false

        public override func hitTest(_ point: NSPoint) -> NSView? { nil }
        public override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard let window, window.isVisible, window.occlusionState.contains(.visible),
                  !isHiddenOrHasHiddenAncestor, !visibleRect.intersection(dirtyRect).isEmpty else { return }
            recorder?.draw(start: start, card: cardID, photo: photo)
        }
        public override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self, name:NSWindow.didChangeOcclusionStateNotification, object:nil)
            if let window {
                NotificationCenter.default.addObserver(self, selector:#selector(checkVisibility),
                    name:NSWindow.didChangeOcclusionStateNotification, object:window)
            }
            needsDisplay = true
        }
        @objc private func checkVisibility() { needsDisplay = true }
    }

    public func makeNSView(context: Context) -> Marker {
        let marker = Marker()
        marker.setAccessibilityElement(false)
        return marker
    }

    public func updateNSView(_ view: Marker, context: Context) {
        guard view.start != start || view.cardID != cardID || view.photo != photo || view.recorder !== recorder else { return }
        view.start = start
        view.cardID = cardID
        view.photo = photo
        view.recorder = recorder
        view.needsDisplay = true
    }
}
#endif
