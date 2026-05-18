import SwiftUI

struct Odometer: View {
    var value: Int

    @State private var displayed: OdometerDisplayState
    @State private var animationTask: Task<Void, Never>?

    init(value: Int) {
        self.value = value
        displayed = OdometerDisplayState(value: value)
    }

    var body: some View {
        HStack(spacing: 0) {
            if displayed.value < 0 {
                Text("-")
            }

            ForEach(displayed.digits) { digit in
                OdometerDigitView(digit: digit.value)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.3), value: displayed.digits.count)
        .monospacedDigit()
        .onChange(of: value) { _, newValue in
            countTowards(newValue)
        }.onDisappear {
            animationTask?.cancel()
        }
    }

    private func countTowards(_ targetValue: Int) {
        animationTask?.cancel()

        var displayedValue = displayed.value

        let delta = abs(targetValue - displayedValue)
        if delta <= 1 {
            displayed = OdometerDisplayState(value: targetValue)
        } else if delta <= 20 {
            let step = targetValue > displayedValue ? 1 : -1
            animationTask = Task {
                while displayedValue != targetValue {
                    displayedValue = displayedValue + step
                    displayed = OdometerDisplayState(value: displayedValue)
                    do {
                        // `sleep` already handles / forwards Task cancellation
                        try await Task.sleep(for: .milliseconds(500) / delta)
                    } catch {
                        return
                    }
                }
            }
        } else {
            // When the delta is large, we just "reset" the odometer to the target value.
            // In this case we take the shortest path to the destination for each widget,
            // not obeying the usual +1 increases and unit-based turnovers.
            let states = OdometerDigitTransition.states(from: displayed, to: targetValue)

            animationTask = Task {
                for state in states {
                    displayed = state
                    do {
                        try await Task.sleep(for: .milliseconds(100))
                    } catch {
                        return
                    }
                }
            }
        }
    }
}

struct OdometerDisplayState: Equatable {
    var digits: [OdometerDigit]
    var value: Int

    init(digits: [OdometerDigit], value: Int) {
        self.digits = digits
        self.value = value
    }

    init(value: Int) {
        self = placeValues(of: value)
    }
}

enum OdometerDigitTransition {
    static func states(from initial: OdometerDisplayState, to targetValue: Int)
        -> [OdometerDisplayState]
    {
        let target = placeValues(of: targetValue)
        var current = initial
        var states: [OdometerDisplayState] = []

        if current.digits.count != target.digits.count {
            current = OdometerDisplayState(
                digits: alignedDigits(current.digits, targetDigitCount: target.digits.count),
                value: current.value,
            )
            states.append(current)
        }

        while current.digits.map(\.value) != target.digits.map(\.value) {
            let nextDigits = zip(current.digits, target.digits).map { currentDigit, targetDigit in
                OdometerDigit(
                    place: targetDigit.place,
                    value: nextDigit(from: currentDigit.value, toward: targetDigit.value),
                )
            }

            current = OdometerDisplayState(
                digits: nextDigits,
                value: value(from: nextDigits, signOf: targetValue),
            )
            states.append(current)
        }

        if current.value != targetValue {
            current = target
            states.append(current)
        }

        return states
    }

    private static func alignedDigits(_ digits: [OdometerDigit], targetDigitCount: Int)
        -> [OdometerDigit]
    {
        if targetDigitCount > digits.count {
            return digits.expandingToCount(targetDigitCount)
        }

        return digits.suffix(targetDigitCount)
    }

    private static func nextDigit(from current: Int, toward target: Int) -> Int {
        let forward = (target - current + 10) % 10
        let backward = (current - target + 10) % 10

        if forward == 0 {
            return current
        }

        if forward <= backward {
            return (current + 1) % 10
        }

        return (current + 9) % 10
    }

    private static func value(from digits: [OdometerDigit], signOf targetValue: Int) -> Int {
        let unsignedValue = digits.reduce(0) { result, digit in
            result * 10 + digit.value
        }

        return targetValue < 0 ? -unsignedValue : unsignedValue
    }
}

extension [OdometerDigit] {
    func expandingToCount(_ targetCount: Int) -> [OdometerDigit] {
        guard let firstPlace = first?.place else {
            return placeValues(of: 0).digits.expandingToCount(targetCount)
        }

        let extra = Swift.max(0, targetCount - count)
        guard extra > 0 else {
            return self
        }

        let leadingEntries = (1 ... extra).reversed().map { offset in
            OdometerDigit(place: firstPlace + offset, value: 0)
        }

        return leadingEntries + self
    }
}

struct OdometerDigit: Equatable, Identifiable {
    let place: Int // 0 = units, 1 = tens, 2 = hundreds...
    let value: Int // 0...9
    var id: Int { place }
}

/// Returns digits ordered most-significant first (for left-to-right HStack).
func placeValues(of n: Int) -> OdometerDisplayState {
    guard n != 0 else {
        return OdometerDisplayState(
            digits: [OdometerDigit(place: 0, value: 0)],
            value: 0,
        )
    }

    var v = abs(n)
    var place = 0
    var result: [OdometerDigit] = []
    while v > 0 {
        result.append(OdometerDigit(place: place, value: v % 10))
        v /= 10
        place += 1
    }

    return OdometerDisplayState(digits: result.reversed(), value: n)
}

private struct OdometerDigitView: View {
    let digit: Int

    var body: some View {
        ZStack {
            ForEach(0 ..< 10) { n in
                Text("\(n)")
                    .visualEffect { effect, proxy in
                        let offset = signedOffset(from: digit, to: n)

                        return
                            effect
                                .rotation3DEffect(.degrees(Double(-offset) * 36), axis: (1, 0, 0))
                                .offset(y: Double(offset) * proxy.size.height)
                                .scaleEffect(offset == 0 ? 1 : 0.5)
                                .opacity(offset == 0 ? 1 : 0)
                    }
            }
        }
        .animation(.snappy(duration: 0.25), value: digit)
    }

    private nonisolated func signedOffset(from a: Int, to b: Int) -> Int {
        let forward = (b - a + 10) % 10
        return forward <= 5 ? forward : forward - 10
    }
}

#if DEBUG

    #Preview("Odometer") {
        @Previewable @State var value = 11

        VStack(alignment: .trailing, spacing: 20) {
            HStack {
                Spacer()

                Odometer(value: value)
                    .font(.system(size: 90, weight: .bold, design: .rounded))
            }

            HStack {
                Button("-25") {
                    value -= 25
                }

                Button("-5") {
                    value -= 5
                }

                Button("-1") {
                    value -= 1
                }

                Button("0") {
                    value = 0
                }

                Button("+1") {
                    value += 1
                }

                Button("+5") {
                    value += 5
                }

                Button("+25") {
                    value += 25
                }
            }

            HStack {
                Button("100") {
                    value = 100
                }

                Button("1000") {
                    value = 1000
                }

                Button("12345") {
                    value = 12345
                }
            }
        }
        .frame(width: 380)
    }

#endif
