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

    /// The touch in progress. A cancelled drag skips `onEnded`, but the next
    /// gesture has a new start and is checked again.
    @State private var drag: Drag?
    /// Where the finger holds the knob, unrounded, so the arc and thumb follow
    /// it smoothly. Only whole steps reach `value` and the speaker.
    @State private var dragProgress: Double?

    private var progress: Double {
        dragProgress ?? steppedProgress
    }

    private var steppedProgress: Double {
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
                    .onChanged { gesture in
                        if drag?.start != gesture.startLocation {
                            drag = Drag(
                                start: gesture.startLocation,
                                thumb: thumbPosition(center: center, radius: radius),
                                center: center,
                                radius: radius,
                                tolerance: startHitTolerance,
                            )
                        }

                        updateValue(at: gesture.location, center: center, radius: radius)
                    }
                    .onEnded { _ in
                        drag = nil
                        dragProgress = nil
                    },
            )
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func updateValue(at location: CGPoint, center: CGPoint, radius: CGFloat) {
        guard
            let newProgress = drag?.progress(
                at: location,
                from: progress,
                center: center,
                radius: radius,
                startAngle: startAngle,
                endAngle: endAngle,
            )
        else {
            // A touch that missed the thumb, or one that let go, shows the last whole step.
            dragProgress = nil
            return
        }

        dragProgress = newProgress
        let stepped = Self.value(forProgress: newProgress, range: range)
        if stepped != value {
            value = stepped
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
                clockwise: false,
            )
        }
        .stroke(
            .secondary.opacity(0.22),
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round),
        )
    }

    private func arcFill(center: CGPoint, radius: CGFloat) -> some View {
        Path { path in
            path.addArc(
                center: center,
                radius: radius,
                startAngle: startAngle,
                endAngle: angle(for: progress),
                clockwise: false,
            )
        }
        .stroke(
            .primary,
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round),
        )
    }

    private func thumbPosition(center: CGPoint, radius: CGFloat) -> CGPoint {
        let angle = angle(for: progress).radians

        return CGPoint(
            x: center.x + cos(angle) * radius,
            y: center.y + sin(angle) * radius,
        )
    }

    private func thumb(center: CGPoint, radius: CGFloat) -> some View {
        Circle()
            .fill(.background)
            .stroke(.primary, lineWidth: 3)
            .frame(width: 30, height: 30)
            .position(thumbPosition(center: center, radius: radius))
            .allowsHitTesting(false)
    }
}

// MARK: - Drag geometry

extension VolumeRadialControl {
    /// One touch on the knob. Like UISlider, it only turns the knob if it
    /// began on the thumb, and the thumb keeps its offset from the finger
    /// instead of jumping under it. Passing through the middle of the dial or
    /// across the gap between the ends lets go until the finger lifts, so the
    /// value never jumps.
    struct Drag {
        let start: CGPoint
        /// Angle from the thumb to the finger at touch-down; nil if the touch
        /// missed the thumb or has let go.
        private var grabOffset: Angle?

        var isHolding: Bool {
            grabOffset != nil
        }

        init(start: CGPoint, thumb: CGPoint, center: CGPoint, radius: CGFloat, tolerance: CGFloat) {
            self.start = start
            if VolumeRadialControl.beginsTracking(
                at: start,
                thumb: thumb,
                center: center,
                radius: radius,
                tolerance: tolerance,
            ) {
                grabOffset = .radians(
                    VolumeRadialControl.angle(of: start, around: center).radians
                        - VolumeRadialControl.angle(of: thumb, around: center).radians,
                )
            }
        }

        /// The unrounded progress (0...1 along the sweep) for the finger at
        /// `location`, or nil if the knob stays put.
        mutating func progress(
            at location: CGPoint,
            from current: Double,
            center: CGPoint,
            radius: CGFloat,
            startAngle: Angle,
            endAngle: Angle,
        ) -> Double? {
            guard let grabOffset else { return nil }

            // Near the middle a tiny movement swings the angle right round.
            guard hypot(location.x - center.x, location.y - center.y) >= radius / 2 else {
                self.grabOffset = nil
                return nil
            }

            let fingerAngle = VolumeRadialControl.angle(of: location, around: center)
            let candidate = VolumeRadialControl.progress(
                at: .radians(fingerAngle.radians - grabOffset.radians),
                startAngle: startAngle,
                endAngle: endAngle,
            )
            guard VolumeRadialControl.acceptsDragProgress(candidate, from: current) else {
                self.grabOffset = nil
                return nil
            }

            return candidate
        }
    }

    private static func angle(of point: CGPoint, around center: CGPoint) -> Angle {
        .radians(atan2(point.y - center.y, point.x - center.x))
    }

    /// Maps a touch angle to a value. Angles in the gap below the dial go to
    /// the nearer end and its exact middle to the quiet end, so overshooting
    /// zero never lands on the maximum.
    static func value(
        at angle: Angle,
        startAngle: Angle,
        endAngle: Angle,
        range: ClosedRange<Int>,
    ) -> Int {
        value(forProgress: progress(at: angle, startAngle: startAngle, endAngle: endAngle), range: range)
    }

    /// The unrounded position of `angle` along the sweep, from 0 to 1, with the
    /// gap mapped to the nearer end (its exact middle to 0).
    static func progress(at angle: Angle, startAngle: Angle, endAngle: Angle) -> Double {
        let fullTurn = 2 * Double.pi
        let sweep = endAngle.radians - startAngle.radians
        guard sweep > 0 else { return 0 }

        var relative = (angle.radians - startAngle.radians)
            .truncatingRemainder(dividingBy: fullTurn)
        if relative < 0 {
            relative += fullTurn
        }

        if relative > sweep {
            let overshoot = relative - sweep
            let gap = fullTurn - sweep
            relative = overshoot < gap / 2 ? sweep : 0
        }

        return relative / sweep
    }

    /// The whole step a progress rounds to; only these reach the speaker.
    static func value(forProgress progress: Double, range: ClosedRange<Int>) -> Int {
        let span = Double(range.upperBound - range.lowerBound)
        return range.lowerBound + Int((min(max(progress, 0), 1) * span).rounded())
    }

    /// Like UISlider, a drag only starts on the thumb, so a stray touch on the
    /// arc can't jump the volume.
    static func beginsTracking(
        at location: CGPoint,
        thumb: CGPoint,
        center: CGPoint,
        radius: CGFloat,
        tolerance: CGFloat,
    ) -> Bool {
        let distanceFromCenter = hypot(location.x - center.x, location.y - center.y)
        let distanceFromThumb = hypot(location.x - thumb.x, location.y - thumb.y)

        return abs(distanceFromCenter - radius) <= tolerance
            && distanceFromThumb <= tolerance
    }

    /// Rejects a sample that jumps more than half the range: the finger
    /// crossed the gap between the ends rather than turning the knob.
    static func acceptsDragProgress(_ candidate: Double, from current: Double) -> Bool {
        abs(candidate - current) <= 0.5
    }
}

struct VolumeRadialDisplay: View {
    let value: Int
    let range: ClosedRange<Int>

    var unit: String?

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
                y: proxy.size.height / 2,
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
                clockwise: false,
            )
        }
        .stroke(
            .secondary.opacity(0.22),
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round),
        )
    }

    private func arcFill(center: CGPoint, radius: CGFloat) -> some View {
        Path { path in
            path.addArc(
                center: center,
                radius: radius,
                startAngle: startAngle,
                endAngle: angle(for: progress),
                clockwise: false,
            )
        }
        .stroke(
            .primary,
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round),
        )
    }
}

#if DEBUG
    #Preview {
        @Previewable @State var value = 0

        VolumeRadialControl(value: $value, range: 0 ... 70)
            .frame(width: 220, height: 220)
            .padding()
    }

    #Preview {
        HStack(spacing: 16) {
            VolumeRadialDisplay(value: 0, range: 0 ... 70)
            VolumeRadialDisplay(value: 29, range: 0 ... 70)
            VolumeRadialDisplay(value: 70, range: 0 ... 70)
        }
        .frame(height: 80)
        .padding()
    }
#endif
