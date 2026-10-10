//
//  AdjustmentsSheet.swift
//  Film Camera
//

import SwiftUI

/// Glass sheet with live image adjustments. At the small detent the camera
/// stays interactive behind it, so changes can be judged in the viewfinder.
struct AdjustmentsSheet: View {
    @Environment(CameraModel.self) private var camera
    @Environment(\.dismiss) private var dismiss

    private static let compact = PresentationDetent.fraction(0.42)
    @State private var detent = AdjustmentsSheet.compact

    var body: some View {
        @Bindable var camera = camera
        NavigationStack {
            List {
                // The Super 8 section only applies in Super 8 mode.
                ForEach(AdjustmentControl.Group.allCases.filter { $0 != .super8 || camera.mode == .super8 }, id: \.self) { group in
                    Section(group.rawValue) {
                        ForEach(AdjustmentControl.all.filter { $0.group == group }) { control in
                            AdjustmentRow(control: control, value: $camera.adjustments[dynamicMember: control.keyPath])
                                .disabled(control.group == .film && camera.selectedFilmID == nil)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Adjust")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset", systemImage: "arrow.counterclockwise") {
                        withAnimation { camera.adjustments = .default }
                    }
                    .disabled(camera.adjustments == .default)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark", role: .confirm) { dismiss() }
                }
            }
        }
        .presentationDetents([Self.compact, .large], selection: $detent)
        .presentationBackgroundInteraction(.enabled(upThrough: Self.compact))
        .presentationContentInteraction(.scrolls)
    }
}

private struct AdjustmentRow: View {
    let control: AdjustmentControl
    @Binding var value: Float

    private var isModified: Bool { abs(value - control.defaultValue) > 0.001 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(control.title, systemImage: control.systemImage)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(control.formatted(value))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(isModified ? Color.filmPrimary : .secondary)
                    .contentTransition(.numericText(value: Double(value)))
            }
            Slider(value: $value, in: control.range, neutralValue: control.isBipolar ? 0 : nil) {
                Text(control.title)
            }
            .labelsHidden()
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
        .onTapGesture(count: 2) {
            withAnimation { value = control.defaultValue }
        }
        .sensoryFeedback(.selection, trigger: value == control.defaultValue) { _, isDefault in isDefault }
        .accessibilityHint("Double-tap to reset")
    }
}
