import Testing

@testable import Louie

struct OdometerTests {
    @Test func placeValuesReturnsDisplayState() {
        #expect(placeValues(of: -420) == state([4, 2, 0], value: -420))
    }

    @Test func largeJumpExpandsBeforeRollingDigits() {
        let states = OdometerDigitTransition.states(
            from: OdometerDisplayState(value: 99),
            to: 100
        )

        #expect(
            states == [
                state([0, 9, 9], value: 99),
                state([1, 0, 0], value: 100),
            ])
    }

    @Test func largeJumpCollapsesBeforeRollingDigits() {
        let states = OdometerDigitTransition.states(
            from: OdometerDisplayState(value: 1234),
            to: 56
        )

        #expect(
            states == [
                state([3, 4], value: 1234),
                state([4, 5], value: 45),
                state([5, 6], value: 56),
            ])
    }

    @Test func eachDigitUsesShortestPath() {
        let states = OdometerDigitTransition.states(
            from: OdometerDisplayState(value: 2),
            to: 8
        )

        #expect(
            states.map(\.digits) == [
                digits([1]),
                digits([0]),
                digits([9]),
                digits([8]),
            ])
    }

    @Test func signCanChangeWhenDigitsAlreadyMatch() {
        let states = OdometerDigitTransition.states(
            from: OdometerDisplayState(value: 25),
            to: -25
        )

        #expect(
            states == [
                state([2, 5], value: -25),
            ])
    }

    @Test func negativeValuesKeepNegativeSignWhileRollingDigits() {
        let states = OdometerDigitTransition.states(
            from: OdometerDisplayState(value: -29),
            to: -31
        )

        #expect(
            states == [
                state([3, 0], value: -30),
                state([3, 1], value: -31),
            ])
    }

    @Test func zeroCrossingUsesTargetSignAfterDigitsAlign() {
        let states = OdometerDigitTransition.states(
            from: OdometerDisplayState(value: -12),
            to: 3
        )

        #expect(
            states == [
                state([2], value: -12),
                state([3], value: 3),
            ])
    }

    private func state(_ values: [Int], value: Int) -> OdometerDisplayState {
        OdometerDisplayState(digits: digits(values), value: value)
    }

    private func digits(_ values: [Int]) -> [OdometerDigit] {
        Array(
            values.reversed().enumerated().map { offset, value in
                OdometerDigit(place: offset, value: value)
            }.reversed())
    }
}
