//
//  ShutterButton.swift
//  Film Camera
//

import SwiftUI

struct ShutterButton: View {
    enum Style {
        case photo
        case record
        case recording
    }

    var style: Style = .photo
    var isBusy: Bool
    var action: () -> Void

    private let recordRed = Color(red: 0.96, green: 0.23, blue: 0.19)

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(.white, lineWidth: 4)
                    .frame(width: 78, height: 78)
                RoundedRectangle(cornerRadius: style == .recording ? 8 : 32, style: .continuous)
                    .fill(style == .photo ? Color.white : recordRed)
                    .frame(width: style == .recording ? 30 : 64, height: style == .recording ? 30 : 64)
                if isBusy {
                    ProgressView()
                        .tint(style == .photo ? .black : .white)
                }
            }
            .animation(.spring(duration: 0.3), value: style)
        }
        .buttonStyle(ShutterPressStyle())
        .disabled(isBusy)
        .accessibilityLabel(accessibilityTitle)
    }

    private var accessibilityTitle: String {
        switch style {
        case .photo: "Take Photo"
        case .record: "Start Recording"
        case .recording: "Stop Recording"
        }
    }
}

private struct ShutterPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}
