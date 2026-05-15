//
//  VolumeControl.swift
//  Louie
//
//  Created by Timm Preetz on 15.05.26.
//

import SwiftUI

struct VolumeRadialControl: View {
    @Binding var value: Int

    let range: ClosedRange<Int>

    var startAngle: Angle = .degrees(135)
    var endAngle: Angle = .degrees(405)

    var lineWidth: CGFloat = 18
    var startHitTolerance: CGFloat = 32

    @State private var isTrackingDrag = false

    private var progress: Double {
        guard range.upperBound > range.lowerBound else { return 0 }

        let clamped = min(max(value, range.lowerBound), range.upperBound)
        return Double(clamped - range.lowerBound)
            / Double(range.upperBound - range.lowerBound)
    }

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            let radius = (size / 2) - lineWidth

            ZStack {
                arcTrack(center: center, radius: radius)
                arcFill(center: center, radius: radius)
                thumb(center: center, radius: radius)

                Text("\(value)")
                    .font(.system(size: size * 0.24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if !isTrackingDrag {
                            guard
                                isNearArc(
                                    drag.location,
                                    center: center,
                                    radius: radius,
                                    tolerance: startHitTolerance
                                )
                            else {
                                return
                            }

                            isTrackingDrag = true
                        }

                        updateValueFromAngle(
                            at: drag.location,
                            center: center
                        )
                    }
                    .onEnded { _ in
                        isTrackingDrag = false
                    }
            )
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func isNearArc(
        _ location: CGPoint,
        center: CGPoint,
        radius: CGFloat,
        tolerance: CGFloat
    ) -> Bool {
        let dx = location.x - center.x
        let dy = location.y - center.y
        let distance = sqrt(dx * dx + dy * dy)

        return abs(distance - radius) <= tolerance
    }

    private func updateValueFromAngle(at location: CGPoint, center: CGPoint) {
        let dx = location.x - center.x
        let dy = location.y - center.y

        var angle = atan2(dy, dx)
        if angle < 0 {
            angle += 2 * .pi
        }

        var start = startAngle.radians.truncatingRemainder(dividingBy: 2 * .pi)
        if start < 0 {
            start += 2 * .pi
        }

        let sweep = endAngle.radians - startAngle.radians

        var relative = angle - start
        if relative < 0 {
            relative += 2 * .pi
        }

        relative = min(max(relative, 0), sweep)

        let newProgress = relative / sweep

        let rawValue =
            Double(range.lowerBound)
            + newProgress * Double(range.upperBound - range.lowerBound)

        value = Int(rawValue.rounded())
    }

    private func angle(for progress: Double) -> Angle {
        let sweep = endAngle.radians - startAngle.radians
        return .radians(startAngle.radians + progress * sweep)
    }

    private func arcTrack(center: CGPoint, radius: CGFloat) -> some View {
        Path { path in
            path.addArc(
                center: center,
                radius: radius,
                startAngle: startAngle,
                endAngle: endAngle,
                clockwise: false
            )
        }
        .stroke(
            .secondary.opacity(0.22),
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
        )
    }

    private func arcFill(center: CGPoint, radius: CGFloat) -> some View {
        Path { path in
            path.addArc(
                center: center,
                radius: radius,
                startAngle: startAngle,
                endAngle: angle(for: progress),
                clockwise: false
            )
        }
        .stroke(
            .primary,
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
        )
    }

    private func thumb(center: CGPoint, radius: CGFloat) -> some View {
        let angle = angle(for: progress).radians

        let point = CGPoint(
            x: center.x + cos(angle) * radius,
            y: center.y + sin(angle) * radius
        )

        return Circle()
            .fill(.background)
            .stroke(.primary, lineWidth: 3)
            .frame(width: 30, height: 30)
            .position(point)
            .allowsHitTesting(false)
    }
}
struct VolumeRadialDisplay: View {
    let value: Int
    let range: ClosedRange<Int>

    var unit: String? = nil

    var startAngle: Angle = .degrees(135)
    var endAngle: Angle = .degrees(405)

    var lineWidth: CGFloat = 5

    private var progress: Double {
        guard range.upperBound > range.lowerBound else { return 0 }

        let clamped = min(max(value, range.lowerBound), range.upperBound)

        return Double(clamped - range.lowerBound)
            / Double(range.upperBound - range.lowerBound)
    }

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let center = CGPoint(
                x: proxy.size.width / 2,
                y: proxy.size.height / 2
            )
            let radius = (size / 2) - lineWidth

            ZStack {
                arcTrack(center: center, radius: radius)
                arcFill(center: center, radius: radius)

                VStack(spacing: -1) {
                    Text("\(value)")
                        .font(.system(size: size * 0.34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)

                    if let unit {
                        Text(unit)
                            .font(.system(size: size * 0.13, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        if let unit {
            "\(value) \(unit)"
        } else {
            "\(value)"
        }
    }

    private func angle(for progress: Double) -> Angle {
        let sweep = endAngle.radians - startAngle.radians
        return .radians(startAngle.radians + progress * sweep)
    }

    private func arcTrack(center: CGPoint, radius: CGFloat) -> some View {
        Path { path in
            path.addArc(
                center: center,
                radius: radius,
                startAngle: startAngle,
                endAngle: endAngle,
                clockwise: false
            )
        }
        .stroke(
            .secondary.opacity(0.22),
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
        )
    }

    private func arcFill(center: CGPoint, radius: CGFloat) -> some View {
        Path { path in
            path.addArc(
                center: center,
                radius: radius,
                startAngle: startAngle,
                endAngle: angle(for: progress),
                clockwise: false
            )
        }
        .stroke(
            .primary,
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
        )
    }
}

#if DEBUG
    #Preview {
        @Previewable @State var value = 0

        VolumeRadialControl(value: $value, range: 0...70)
            .frame(width: 220, height: 220)

            .padding()
    }

    #Preview {
        HStack(spacing: 16) {
            VolumeRadialDisplay(value: 0, range: 0...70)
            VolumeRadialDisplay(value: 29, range: 0...70)
            VolumeRadialDisplay(value: 70, range: 0...70)
        }
        .frame(height: 80)
        .padding()
    }
#endif
