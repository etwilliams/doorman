import SwiftUI

struct RootView: View {
    let model: AppModel

    var body: some View {
        ZStack(alignment: .top) {
            switch model.screen {
            case .picker: PickerView(model: model)
            case .settings: SettingsView(model: model)
            }
            TitleStrip()
        }
        .foregroundStyle(Theme.fg)
        .font(.system(size: 13))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Content runs under the transparent title bar; the views inset
        // themselves by its height, so the system's safe area would double it.
        .ignoresSafeArea()
    }
}

/// Sits under the transparent title bar, centered so it clears the traffic lights.
private struct TitleStrip: View {
    var body: some View {
        HStack(spacing: 5) {
            DoorMark(color: Theme.muted)
                .frame(width: 13, height: 13)
                .opacity(0.9)
            Text("Doorman")
                .font(.system(size: 11.5, weight: .semibold))
                .kerning(0.1)
        }
        .foregroundStyle(Theme.muted)
        .frame(maxWidth: .infinity)
        .frame(height: 28)
        .allowsHitTesting(false)
    }
}
