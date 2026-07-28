import SwiftUI

/// Exclamation eye when something is blocked on you, badged eye when work is
/// ready for review, plain eye otherwise. Count covers blocked + ready.
struct MenuBarLabel: View {
    var needsYouCount: Int
    var readyCount: Int

    var body: some View {
        if needsYouCount > 0 {
            Label("\(needsYouCount + readyCount)", systemImage: "eye.trianglebadge.exclamationmark")
                .labelStyle(.titleAndIcon)
        } else if readyCount > 0 {
            Label("\(readyCount)", systemImage: "eye.circle")
                .labelStyle(.titleAndIcon)
        } else {
            Image(systemName: "eye")
        }
    }
}
