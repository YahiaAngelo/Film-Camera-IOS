//
//  ZoomControl.swift
//  Film Camera
//

import SwiftUI

/// Lens buttons ("0.5 · 1× · 2") in a Liquid Glass capsule.
struct ZoomControl: View {
    @Environment(CameraModel.self) private var camera
    @Namespace private var glass

    var body: some View {
        if let info = camera.deviceInfo, info.zoomStops.count > 1 {
            let stops = info.zoomStops
            let active = activeStop(in: stops)

            GlassEffectContainer(spacing: 4) {
                HStack(spacing: 4) {
                    ForEach(stops, id: \.self) { stop in
                        let isActive = stop == active
                        Button {
                            camera.setZoom(stop)
                        } label: {
                            Text(label(for: stop, isActive: isActive, multiplier: info.displayMultiplier))
                                .font(.system(size: isActive ? 13 : 11, weight: .semibold).monospacedDigit())
                                .foregroundStyle(isActive ? Color.filmPrimary : .white)
                                .frame(width: isActive ? 40 : 32, height: isActive ? 40 : 32)
                                .contentShape(.circle)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .circle)
                        .glassEffectID(stop, in: glass)
                    }
                }
            }
            .animation(.spring(duration: 0.3), value: active)
        }
    }

    /// The highest lens stop at or below the current zoom.
    private func activeStop(in stops: [CGFloat]) -> CGFloat {
        stops.last { $0 <= camera.zoomFactor + 0.01 } ?? stops[0]
    }

    private func label(for stop: CGFloat, isActive: Bool, multiplier: CGFloat) -> String {
        let value = isActive ? camera.displayZoom : stop * multiplier
        let text = value < 1 || value.truncatingRemainder(dividingBy: 1) > 0.05
            ? String(format: "%.1f", value).replacingOccurrences(of: "0.", with: ".")
            : String(format: "%.0f", value)
        return isActive ? "\(text)×" : text
    }
}
