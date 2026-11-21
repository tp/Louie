import CoreGraphics
import SwiftUI
import Testing

@testable import Louie

struct VolumeRadialControlTests {
    // The popover knob: 180 pt square, track radius 72, a 270° sweep from 135°.
    private let range = 0 ... 70
    private let center = CGPoint(x: 90, y: 90)
    private let radius: CGFloat = 72

    @Test func gapBelowTheDialMapsToTheNearestEnd() {
        // 1° past zero used to clamp to the far end of the sweep: maximum volume.
        #expect(value(atDegrees: 134) == 0)
        #expect(value(atDegrees: 46) == 70)
    }

    @Test func gapMidpointMapsToTheQuietEnd() {
        #expect(value(atDegrees: 90) == 0)
    }

    @Test func anglesOnTheArcAreUnchanged() {
        #expect(value(atDegrees: 135) == 0)
        #expect(value(atDegrees: 405) == 70)
        #expect(value(atDegrees: 45) == 70)
        #expect(value(atDegrees: 270) == 35)
    }

    @Test func touchOnTheArcAwayFromTheThumbDoesNotBeginTracking() {
        let topOfArc = CGPoint(x: 90, y: 18)
        #expect(!beginsTracking(at: topOfArc))
    }

    @Test func touchOnTheThumbBeginsTracking() {
        #expect(beginsTracking(at: thumbAtZero))
        #expect(beginsTracking(at: CGPoint(x: thumbAtZero.x + 20, y: thumbAtZero.y - 10)))
    }

    @Test func wrapAroundJumpIsRejectedWhileSmallStepsPass() {
        #expect(!VolumeRadialControl.acceptsDragProgress(1, from: 0))
        #expect(!VolumeRadialControl.acceptsDragProgress(0, from: 1))
        #expect(VolumeRadialControl.acceptsDragProgress(1 / 70, from: 0))
        #expect(VolumeRadialControl.acceptsDragProgress(33 / 70, from: 36 / 70))
    }

    @Test func dragFollowsTheFingerBetweenWholeSteps() {
        // The arc and thumb draw this progress, so it must not snap to steps;
        // only the rounded value is sent, and it changes at the half step.
        let step = 270.0 / 70
        var drag = VolumeRadialControl.Drag(
            start: pointOnTrack(degrees: degrees(for: 10)),
            thumb: pointOnTrack(degrees: degrees(for: 10)),
            center: center,
            radius: radius,
            tolerance: 32,
        )
        let partway = progress(of: &drag, at: degrees(for: 10) + 0.4 * step, from: 10.0 / 70)
        let pastHalf = progress(of: &drag, at: degrees(for: 10) + 0.6 * step, from: partway)

        #expect(abs(partway - 10.4 / 70) < 1e-9)
        #expect(VolumeRadialControl.value(forProgress: partway, range: range) == 10)
        #expect(abs(pastHalf - 10.6 / 70) < 1e-9)
        #expect(VolumeRadialControl.value(forProgress: pastHalf, range: range) == 11)
    }

    @Test func turningAlongTheArcFollowsTheFinger() {
        let samples = stride(from: degrees(for: 10), through: degrees(for: 40), by: 1).map(pointOnTrack)
        let turn = drag(from: 10, through: samples)

        #expect(turn.heard == Array(11 ... 40))
        #expect(turn.isHolding)
    }

    @Test(arguments: [1.0, 3.0])
    func pullingStraightDownThroughTheMiddleLetsGo(offset: CGFloat) {
        // With the thumb at the top, a finger pulled down just beside the
        // centre swings the angle right round; every sample now reaches the
        // speaker, so it must not turn the volume up on the way.
        let top = pointOnTrack(degrees: 270)
        let pull = stride(from: top.y, through: 170, by: 2).map { CGPoint(x: center.x + offset, y: $0) }
        let turn = drag(from: 35, through: [top] + pull)

        #expect(turn.heard.filter { $0 > 36 } == [])
        #expect(!turn.isHolding)
    }

    @Test func turningTheWrongWayAcrossTheGapLetsGo() {
        // From zero, round through the gap, over the top and down the far side:
        // the knob lets go in the gap instead of picking up on the arc again.
        let samples = stride(from: 135.0, through: -180, by: -2).map(pointOnTrack)
        let turn = drag(from: 0, through: samples)

        #expect(turn.heard == [])
        #expect(!turn.isHolding)
    }

    @Test func grabbingTheThumbOffCentreKeepsTheValue() {
        // The touch lands 15° (about 4 steps) along the arc from the thumb's
        // centre; only the movement after that changes the value.
        let oneStep = 270.0 / 70
        let turn = drag(from: 0, through: [pointOnTrack(degrees: 150), pointOnTrack(degrees: 150 + oneStep)])

        #expect(turn.heard == [1])
    }

    private var thumbAtZero: CGPoint {
        pointOnTrack(degrees: 135)
    }

    private func degrees(for value: Int) -> Double {
        135 + Double(value) / Double(range.upperBound) * 270
    }

    private func pointOnTrack(degrees: Double) -> CGPoint {
        let angle = Angle.degrees(degrees).radians
        return CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
    }

    private func value(atDegrees degrees: Double) -> Int {
        VolumeRadialControl.value(
            at: .degrees(degrees),
            startAngle: .degrees(135),
            endAngle: .degrees(405),
            range: range,
        )
    }

    private func beginsTracking(at location: CGPoint) -> Bool {
        VolumeRadialControl.beginsTracking(
            at: location,
            thumb: thumbAtZero,
            center: center,
            radius: radius,
            tolerance: 32,
        )
    }

    /// Feeds finger positions to a touch that went down on the first one, as
    /// DragGesture does, and returns each value change the speaker would hear.
    private func drag(from start: Int, through samples: [CGPoint]) -> (heard: [Int], isHolding: Bool) {
        var drag = VolumeRadialControl.Drag(
            start: samples[0],
            thumb: pointOnTrack(degrees: degrees(for: start)),
            center: center,
            radius: radius,
            tolerance: 32,
        )
        var current = start
        var shown = Double(start) / Double(range.upperBound)
        var heard: [Int] = []
        for sample in samples {
            guard
                let next = drag.progress(
                    at: sample,
                    from: shown,
                    center: center,
                    radius: radius,
                    startAngle: .degrees(135),
                    endAngle: .degrees(405),
                )
            else {
                // The view falls back to the last whole step.
                shown = Double(current) / Double(range.upperBound)
                continue
            }

            shown = next
            let stepped = VolumeRadialControl.value(forProgress: next, range: range)
            if stepped != current {
                current = stepped
                heard.append(stepped)
            }
        }
        return (heard, drag.isHolding)
    }

    private func progress(of drag: inout VolumeRadialControl.Drag, at degrees: Double, from current: Double) -> Double {
        drag.progress(
            at: pointOnTrack(degrees: degrees),
            from: current,
            center: center,
            radius: radius,
            startAngle: .degrees(135),
            endAngle: .degrees(405),
        ) ?? .nan
    }
}
