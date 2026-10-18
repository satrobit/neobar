import XCTest

final class ScrollReverserDecisionTests: XCTestCase {
    func testEnabledRequiresSettingAndKillSwitch() {
        XCTAssertTrue(ScrollReverserDecision.isEnabled(settingEnabled: true, environment: [:]))
        XCTAssertFalse(ScrollReverserDecision.isEnabled(settingEnabled: false, environment: [:]))
        XCTAssertFalse(
            ScrollReverserDecision.isEnabled(settingEnabled: true, environment: ["DOCK_SCROLL_REVERSER": "0"]),
            "DOCK_SCROLL_REVERSER=0 是杀开关"
        )
        XCTAssertTrue(ScrollReverserDecision.isEnabled(settingEnabled: true, environment: ["DOCK_SCROLL_REVERSER": "1"]))
    }

    func testOnlyDiscreteWheelEventsReverse() {
        XCTAssertTrue(ScrollReverserDecision.shouldReverse(isContinuous: false), "离散滚轮 = 鼠标，反转")
        XCTAssertFalse(
            ScrollReverserDecision.shouldReverse(isContinuous: true),
            "连续事件 = 触控板 / 妙控鼠标 / 平滑滚动，放行；动量阶段只出现在连续事件上，一并覆盖"
        )
    }

    func testReversedNegatesAllSixFieldsAndKeepsZeros() {
        let input = ScrollWheelDeltas(
            axis1: 3, axis2: -2,
            pointAxis1: 30, pointAxis2: -20,
            fixedAxis1: 3.5, fixedAxis2: -2.5
        )
        let output = ScrollReverserDecision.reversed(input)
        XCTAssertEqual(output, ScrollWheelDeltas(
            axis1: -3, axis2: 2,
            pointAxis1: -30, pointAxis2: 20,
            fixedAxis1: -3.5, fixedAxis2: 2.5
        ))

        let zero = ScrollWheelDeltas(axis1: 0, axis2: 0, pointAxis1: 0, pointAxis2: 0, fixedAxis1: 0, fixedAxis2: 0)
        XCTAssertEqual(ScrollReverserDecision.reversed(zero), zero, "零保持零（-0.0 == 0.0）")
    }

    func testInt64MinDoesNotOverflow() {
        let input = ScrollWheelDeltas(
            axis1: .min, axis2: .max,
            pointAxis1: .min, pointAxis2: 1,
            fixedAxis1: 0, fixedAxis2: 0
        )
        let output = ScrollReverserDecision.reversed(input)
        XCTAssertEqual(output.axis1, .max)
        XCTAssertEqual(output.axis2, -Int64.max)
        XCTAssertEqual(output.pointAxis1, .max)
        XCTAssertEqual(output.pointAxis2, -1)
    }
}
