//
//  ModePicker.swift
//  Film Camera
//

import SwiftUI

/// "PHOTO · SUPER 8" mode switcher above the shutter, like the Camera app's.
struct ModePicker: View {
    @Environment(CameraModel.self) private var camera

    var body: some View {
        HStack(spacing: 28) {
            ForEach(CameraModel.CaptureMode.allCases) { mode in
                let isSelected = camera.mode == mode
                Button {
                    Task { await camera.setMode(mode) }
                } label: {
                    Text(mode.title.uppercased())
                        .font(.system(size: 13, weight: .semibold))
                        .tracking(1.2)
                        .foregroundStyle(isSelected ? Color.filmPrimary : .white.opacity(0.75))
                        .padding(.vertical, 6)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .frame(height: 30)
        // Like the Camera app, the mode switcher hides while recording.
        .opacity(camera.isRecording ? 0 : 1)
        .disabled(camera.isRecording)
        .animation(.easeInOut(duration: 0.2), value: camera.isRecording)
        .sensoryFeedback(.selection, trigger: camera.mode)
    }
}
