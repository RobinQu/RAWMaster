import AppKit
import SwiftUI

/// Shared geometry keeps the initial FIT image clear of every persistent editing control.
/// Free zoom still uses the full-bleed canvas and may deliberately extend beneath the chrome.
enum EditingLayout {
    static let sidebarWidth: CGFloat = 304
    static let outerPadding: CGFloat = 12
    static let topInset: CGFloat = 24
    static let bottomInset: CGFloat = 88
    static var fitInsets: NSEdgeInsets {
        .init(top: topInset, left: sidebarWidth + outerPadding * 2,
              bottom: bottomInset, right: sidebarWidth + outerPadding * 2)
    }
    static var comparisonFitInsets: NSEdgeInsets { fitInsets }
}

/// Full-bleed darkroom with stable tool columns and one compact canvas command bar.
struct EditingWorkspace: View {
    @ObservedObject var editing: EditingController

    var body: some View {
        ZStack {
            BrowserView()
            HStack(alignment: .top, spacing: 0) {
                EditingLeftSidebar(editing: editing)
                    .floatingSelectionSurface()
                Spacer(minLength: 0)
                NativeEditingInspector(editing: editing)
                    .frame(width: EditingLayout.sidebarWidth)
                    .floatingSelectionSurface()
            }
            .padding(.horizontal, EditingLayout.outerPadding)
            .padding(.top, 12)
            .padding(.bottom, 12)
            .disabled(editing.quickPromptAdopting)
        }
        .background(editing.darkroomBackground.color)
        .accessibilityIdentifier("editing.darkroom")
    }
}
