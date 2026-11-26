import Foundation
import PolicyEngine
import Testing
@testable import PulseUI

struct CurveDraftTests {
    func userCurve(_ preset: FanCurveSpec = FanCurvePresets.balanced) -> CurveDraft {
        var spec = preset
        spec.name = "mine"
        spec.label = "Mine"
        return CurveDraft(spec)
    }

    /// Every edit must leave a curve the daemon accepts.
    func expectValid(_ draft: CurveDraft, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(draft.validationError == nil, "\(draft.validationError ?? "")", sourceLocation: sourceLocation)
    }

    @Test func handlesAreClamped() throws {
        var draft = userCurve()
        #expect(!draft.isDirty)

        draft.moveHandle(.start, celsius: 65, percent: 10)
        #expect(draft.handle(.start)! == (65, 10))
        #expect(draft.isDirty)

        // Start cannot pass end - 2 °C, nor go below 30 °C; min cannot exceed max.
        draft.moveHandle(.start, celsius: 120, percent: 150)
        #expect(draft.handle(.start)!.celsius == 98)
        #expect(draft.handle(.start)!.percent == 100)
        draft.moveHandle(.start, celsius: -10, percent: -5)
        #expect(draft.handle(.start)! == (30, 0))

        // End cannot pass start + 2 °C, nor 110 °C; max cannot go below min.
        draft.moveHandle(.start, celsius: 60, percent: 40)
        draft.moveHandle(.end, celsius: 10, percent: 20)
        #expect(draft.handle(.end)! == (62, 40))
        draft.moveHandle(.end, celsius: 500, percent: 90)
        #expect(draft.handle(.end)! == (110, 90))
        expectValid(draft)

        draft.moveHandle(.end, celsius: .nan, percent: 50)
        #expect(draft.handle(.end)! == (110, 90), "non-finite input is ignored")
    }

    @Test func kindSteepnessAndStepsKeepTheRamp() {
        var draft = userCurve()
        draft.setKind(.exponential)
        #expect(draft.spec.shape?.kind == .exponential)
        #expect(draft.spec.shape?.steepness == FanCurveShapeKind.exponential.defaultSteepness)
        #expect(draft.handle(.start)! == (70, 0))
        #expect(draft.handle(.end)! == (100, 100))
        draft.setSteepness(99)
        #expect(draft.spec.shape?.steepness == FanCurveShape.maximumSteepness)
        draft.setSteepness(4.26)
        #expect(draft.spec.shape?.steepness == 4.3)
        draft.setKind(.steps)
        draft.setStepCount(0)
        #expect(draft.spec.shape?.stepCount == 1)
        draft.setStepCount(50)
        #expect(draft.spec.shape?.stepCount == FanCurveShape.maximumStepCount)
        expectValid(draft)
    }

    @Test func convertingToPointsFollowsTheShape() throws {
        for preset in FanCurvePresets.all {
            var draft = userCurve(preset)
            let shape = try #require(draft.spec.shape)
            draft.convertToPoints()
            #expect(draft.isPoints)
            #expect((2...CurveDraft.maximumPoints).contains(draft.spec.points.count))
            expectValid(draft)
            var worst = 0.0
            for celsius in stride(from: 30.0, through: 110.0, by: 0.25) {
                worst = max(worst, abs(draft.percent(at: celsius) - shape.fraction(at: celsius) * 100))
            }
            #expect(worst < 2, "\(preset.name): \(worst)% off")
        }
    }

    @Test func convertingStepsKeepsThePlateaus() throws {
        var draft = userCurve()
        draft.setKind(.steps)
        draft.setStepCount(4)
        draft.convertToPoints()
        #expect(draft.spec.points.count == 9)
        expectValid(draft)
        // Middle of each plateau: 70–77.5 °C → 0 %, 77.5–85 → 25 %, …
        #expect(draft.percent(at: 74) == 0)
        #expect(draft.percent(at: 81) == 25)
        #expect(draft.percent(at: 88) == 50)
        #expect(draft.percent(at: 96) == 75)
        #expect(draft.percent(at: 105) == 100)
    }

    @Test func pointsStayOrderedAndValid() {
        var draft = userCurve()
        draft.convertToPoints(count: 4)
        let before = draft.percentPoints
        #expect(before.count == 4)

        // A point cannot cross its neighbours.
        draft.movePoint(at: 1, celsius: 200, percent: 120)
        let moved = draft.percentPoints
        #expect(moved[1].celsius == moved[2].celsius - CurveDraft.minimumPointGap)
        #expect(moved[1].percent == 100)
        expectValid(draft)

        // Adding: refused next to an existing point, accepted elsewhere.
        #expect(draft.addPoint(celsius: moved[2].celsius + 0.2, percent: 50) == nil)
        let index = draft.addPoint(celsius: 40, percent: 5)
        #expect(index == 0)
        #expect(draft.percentPoints.count == 5)

        // Removing keeps at least two points.
        for _ in 0..<10 { draft.removePoint(at: 0) }
        #expect(draft.percentPoints.count == 2)
        expectValid(draft)

        // Back to a shape spanning the first and last points.
        let first = draft.percentPoints[0], last = draft.percentPoints[1]
        draft.setKind(.linear)
        #expect(!draft.isPoints)
        #expect(draft.handle(.start)!.celsius == first.celsius)
        #expect(draft.handle(.end)!.celsius == last.celsius)
        expectValid(draft)
    }

    @Test func pointEditsNeedAPointCurve() {
        var draft = userCurve()
        #expect(draft.addPoint(celsius: 50, percent: 10) == nil)
        draft.movePoint(at: 0, celsius: 50, percent: 10)
        draft.removePoint(at: 0)
        #expect(!draft.isPoints)
        #expect(!draft.isDirty)
    }

    @Test func handWrittenPointsAreReadInPercent() {
        let spec = FanCurveSpec(name: "old", points: [.init(80, .rpm(3000)), .init(50, .rpm(1000)), .init(95, .maximum)])
        var draft = CurveDraft(spec, range: FanSpeedRange(minimumRPM: 1000, maximumRPM: 5000))
        #expect(draft.percentPoints.map(\.percent) == [0, 50, 100], "sorted, RPM converted with the fan range")
        draft.movePoint(at: 1, celsius: 80, percent: 60)
        #expect(draft.spec.points.allSatisfy { if case .percent = $0.speed { true } else { false } })
        expectValid(draft)
    }

    @Test func sensorsAndAggregation() {
        var draft = userCurve()
        #expect(draft.sensorGroups.isEmpty)
        #expect(draft.aggregation == .hottest)

        draft.setAggregation(.average)
        #expect(draft.spec.weights == ["*": 1])
        draft.setSensorGroups([.gpu, .cpu])
        #expect(draft.spec.sensors == ["Tp*", "Tg*"])
        #expect(draft.spec.weights == ["Tp*": 1, "Tg*": 1], "average follows the selection")
        draft.setAggregation(.hottest)
        #expect(draft.spec.weights.isEmpty)
        expectValid(draft)

        // Hand-written keys are preserved.
        var custom = CurveDraft(FanCurveSpec(name: "c", sensors: ["Tp0E", "Tg*"], shape: FanCurvePresets.balanced.shape))
        #expect(custom.customSensors == ["Tp0E"])
        custom.setSensorGroups([.cpu])
        #expect(custom.spec.sensors == ["Tp*", "Tp0E"])
    }

    @Test func responseSettingsAreClamped() {
        var draft = userCurve()
        draft.setHysteresis(50)
        #expect(draft.spec.hysteresisCelsius == 20)
        draft.setRiseRate(percentPerSecond: 0)
        #expect(draft.spec.riseRate == nil, "0 means immediate")
        draft.setRiseRate(percentPerSecond: 12.34)
        #expect(draft.riseRatePercent == 12.3)
        draft.setFallRate(percentPerSecond: 500)
        #expect(draft.fallRatePercent == 100)
        draft.setSmoothing(seconds: 0)
        #expect(draft.spec.smoothingSeconds == nil)
        draft.setSmoothing(seconds: 999)
        #expect(draft.spec.smoothingSeconds == 120)
        expectValid(draft)

        let rpm = CurveDraft(FanCurveSpec(name: "r", shape: FanCurvePresets.balanced.shape, riseRate: .rpmPerSecond(400)),
                             range: FanSpeedRange(minimumRPM: 1000, maximumRPM: 5000))
        #expect(rpm.riseRatePercent == 10)
    }

    @Test func labelRevertAndRestore() {
        var draft = userCurve()
        draft.setLabel("  Late\nnight ")
        #expect(draft.spec.label == "Late night")
        let edited = draft.spec
        draft.revert()
        #expect(!draft.isDirty)
        draft.restore(edited)
        #expect(draft.spec == edited)
    }

    /// Random edit sequences never produce an invalid curve.
    @Test func randomEditsStayValid() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            var draft = userCurve()
            for _ in 0..<30 {
                let t = Double.random(in: 0...130, using: &generator)
                let p = Double.random(in: -20...140, using: &generator)
                switch Int.random(in: 0..<9, using: &generator) {
                case 0: draft.setKind(FanCurveShapeKind.allCases.randomElement(using: &generator)!)
                case 1: draft.moveHandle(.start, celsius: t, percent: p)
                case 2: draft.moveHandle(.end, celsius: t, percent: p)
                case 3: draft.setSteepness(Double.random(in: -5...40, using: &generator))
                case 4: draft.convertToPoints(count: Int.random(in: 2...14, using: &generator))
                case 5: draft.movePoint(at: Int.random(in: 0..<12, using: &generator), celsius: t, percent: p)
                case 6: draft.addPoint(celsius: t, percent: p)
                case 7: draft.removePoint(at: Int.random(in: 0..<12, using: &generator))
                default: draft.setStepCount(Int.random(in: -3...30, using: &generator))
                }
            }
            if let error = draft.validationError {
                Issue.record("invalid after random edits: \(error)")
                return
            }
        }
    }

    @Test func outlineMatchesTheCurveWithFewVertices() {
        for preset in FanCurvePresets.all + [FanCurveSpec(name: "p", points: [.init(20, .percent(10)), .init(60, .percent(30)), .init(130, .percent(90))])] {
            let draft = CurveDraft(preset)
            let outline = draft.outline
            #expect(outline.first?.celsius == 30)
            #expect(outline.last?.celsius == 110)
            #expect(outline.count < 60, "\(preset.name): \(outline.count) vertices")
            #expect(zip(outline, outline.dropFirst()).allSatisfy { $0.celsius < $1.celsius })
            var worst = 0.0
            for celsius in stride(from: 30.0, through: 110.0, by: 0.25) {
                guard let b = outline.firstIndex(where: { $0.celsius >= celsius }) else { continue }
                let a = max(0, b - 1)
                let (p, q) = (outline[a], outline[b])
                let drawn = q.celsius == p.celsius ? q.percent : p.percent + (q.percent - p.percent) * (celsius - p.celsius) / (q.celsius - p.celsius)
                worst = max(worst, abs(drawn - draft.percent(at: celsius)))
            }
            #expect(worst < 1, "\(preset.name): drawn line is \(worst)% off")
        }
    }

    @Test func idleBehaviourAppliesToCurvesThatReachZero() {
        var draft = userCurve()
        #expect(draft.spec.reachesZero)
        #expect(draft.spec.idle == .system)
        draft.setIdle(.off)
        #expect(draft.spec.idle == .off)
        #expect(draft.isDirty)
        expectValid(draft)
        #expect(!CurveDraft(FanCurvePresets.performance).spec.reachesZero, "10% floor")
        draft.convertToPoints()
        #expect(draft.spec.reachesZero, "points starting at 0%")
        #expect(draft.spec.idle == .off, "kept across conversions")
    }
}
