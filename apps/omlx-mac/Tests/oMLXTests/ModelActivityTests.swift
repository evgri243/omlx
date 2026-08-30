import XCTest
@testable import oMLX

final class ModelActivityTests: XCTestCase {

    private static let activityJSON = """
    {
      "active_models": {
        "models": [
          {
            "id": "model-a",
            "is_loading": false,
            "active_requests": 2,
            "waiting_requests": 0,
            "activities": [],
            "generating": [],
            "prefilling": [
              {"request_id": "cmpl-abc123", "processed": 12400, "total": 20000,
               "speed": 1820.0, "eta": 4.2, "elapsed": 6.8, "detail": null},
              {"request_id": "cmpl-xyz999", "processed": 7100, "total": 40000,
               "speed": 1390.0, "eta": 23.7, "elapsed": 5.1, "detail": null}
            ]
          },
          {
            "id": "model-b",
            "is_loading": false,
            "active_requests": 1,
            "waiting_requests": 1,
            "activities": [],
            "prefilling": [],
            "generating": [
              {"request_id": "cmpl-def456", "elapsed_seconds": 5.7,
               "generated_tokens": 184, "tokens_per_second": 32.5}
            ]
          }
        ],
        "total_active_requests": 3,
        "total_waiting_requests": 1
      }
    }
    """

    private func decodedModel(_ id: String) throws -> StatsDTO.ActiveModelDTO {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let activity = try decoder.decode(ActivityDTO.self, from: Data(Self.activityJSON.utf8))
        return try XCTUnwrap(activity.activeModels.models.first { $0.id == id })
    }

    private func makeModel(
        waitingRequests: Int = 0,
        prefilling: [StatsDTO.PrefillProgressDTO] = [],
        generating: [StatsDTO.GenerationProgressDTO] = [],
        activities: [StatsDTO.NonStreamingActivityDTO] = []
    ) -> StatsDTO.ActiveModelDTO {
        StatsDTO.ActiveModelDTO(
            id: "model-a", estimatedSize: nil, estimatedSizeFormatted: nil,
            pinned: nil, isLoading: false,
            activeRequests: prefilling.count + generating.count + activities.count,
            waitingRequests: waitingRequests, prefilling: prefilling,
            generating: generating, activities: activities
        )
    }

    private func row(_ id: String, detail: String = "12 tok") -> ModelRequestActivity {
        ModelRequestActivity(id: id, phase: .generating, fraction: nil,
                             percentText: nil, detail: detail)
    }

    // MARK: - Wire contract

    func testActivityPayloadDecodes() throws {
        let model = try decodedModel("model-a")

        XCTAssertEqual(model.prefilling?.count, 2)
        XCTAssertEqual(model.prefilling?.first?.processed, 12_400)
        XCTAssertEqual(model.prefilling?.first?.speed, 1_820.0)
        XCTAssertEqual(try decodedModel("model-b").generating?.first?.tokensPerSecond, 32.5)
    }

    // MARK: - Rows

    func testConcurrentPrefillsGetIndependentRows() throws {
        let snapshot = try XCTUnwrap(ModelActivitySnapshot(model: decodedModel("model-a")))

        XCTAssertEqual(snapshot.requests.count, 2)
        XCTAssertEqual(snapshot.badgePhase, .prefill)
        XCTAssertEqual(try XCTUnwrap(snapshot.requests[0].fraction), 0.62, accuracy: 0.001)
        XCTAssertEqual(snapshot.requests[0].percentText, "62%")
        XCTAssertEqual(snapshot.requests[1].percentText, "18%")
        XCTAssertTrue(snapshot.requests[0].detail.contains("12k / 20k tok"),
                      snapshot.requests[0].detail)
        XCTAssertTrue(snapshot.requests[0].detail.contains("1.8k tok/s"),
                      snapshot.requests[0].detail)
        XCTAssertNotEqual(snapshot.requests[0].shortID, snapshot.requests[1].shortID)
    }

    func testGeneratingRowsHaveNoProgressBar() throws {
        let snapshot = try XCTUnwrap(ModelActivitySnapshot(model: decodedModel("model-b")))

        XCTAssertEqual(snapshot.badgePhase, .generating)
        XCTAssertNil(snapshot.requests[0].fraction)
        XCTAssertEqual(snapshot.queued, 1)
        XCTAssertTrue(snapshot.requests[0].detail.contains("184 tok"), snapshot.requests[0].detail)
        XCTAssertTrue(snapshot.requests[0].detail.contains("32.5 tok/s"),
                      snapshot.requests[0].detail)
    }

    func testPrefillWithoutTotalHasNoFraction() {
        let snapshot = ModelActivitySnapshot(model: makeModel(
            prefilling: [.init(requestId: "a", processed: 0, total: 0, speed: nil,
                               eta: nil, elapsed: nil, detail: nil)]
        ))

        XCTAssertNil(snapshot?.requests.first?.fraction)
    }

    func testIdleModelHasNoSnapshot() {
        XCTAssertNil(ModelActivitySnapshot(model: makeModel()))
    }

    func testQueuedOnlyModelIsBusyWithoutRows() {
        let snapshot = ModelActivitySnapshot(model: makeModel(waitingRequests: 3))

        XCTAssertEqual(snapshot?.requests.isEmpty, true)
        XCTAssertEqual(snapshot?.queued, 3)
        XCTAssertEqual(snapshot?.badgePhase, .queued)
    }

    // MARK: - Linger

    func testFinishedRowIsHeldThenRetired() {
        var linger = ActivityLinger(duration: 2.5)
        XCTAssertEqual(linger.merge(live: [row("a")], for: "m", now: 100).map(\.phase),
                       [.generating])

        let held = linger.merge(live: [], for: "m", now: 101)
        XCTAssertEqual(held.map(\.id), ["a"])
        XCTAssertEqual(held.first?.phase, .finished)
        XCTAssertEqual(held.first?.detail, "12 tok")

        XCTAssertEqual(linger.merge(live: [], for: "m", now: 103.4).count, 1)
        XCTAssertTrue(linger.merge(live: [], for: "m", now: 103.6).isEmpty)
    }

    func testPhaseChangeDoesNotLinger() {
        var linger = ActivityLinger(duration: 2.5)
        let prefill = ModelRequestActivity(id: "a", phase: .prefill, fraction: 0.5,
                                           percentText: "50%", detail: "10 / 20 tok")
        _ = linger.merge(live: [prefill], for: "m", now: 100)

        let after = linger.merge(live: [row("a")], for: "m", now: 101)
        XCTAssertEqual(after.map(\.id), ["a"])
        XCTAssertEqual(after.first?.phase, .generating)
    }

    func testLingeringRowSortsBelowLiveOnes() {
        var linger = ActivityLinger(duration: 2.5)
        _ = linger.merge(live: [row("a"), row("b")], for: "m", now: 100)

        let merged = linger.merge(live: [row("b")], for: "m", now: 101)
        XCTAssertEqual(merged.map(\.id), ["b", "a"])
        XCTAssertEqual(merged.map(\.phase), [.generating, .finished])
    }

    func testUnloadedModelDropsHeldRows() {
        var linger = ActivityLinger(duration: 2.5)
        _ = linger.merge(live: [row("a")], for: "m", now: 100)
        linger.retain(models: [])

        XCTAssertTrue(linger.merge(live: [], for: "m", now: 101).isEmpty)
    }

    func testLingeringRowDoesNotCountAsBusy() throws {
        let snapshot = try XCTUnwrap(
            ModelActivitySnapshot(requests: [row("a").finished], queued: 0)
        )

        XCTAssertFalse(snapshot.isBusy)
        XCTAssertEqual(snapshot.badgePhase, .queued)
    }

    // MARK: - Speed smoothing

    func testSmoothedSpeedDampensSwingsAndDrivesEta() throws {
        var smoother = PrefillSpeedSmoother(alpha: 0.35)
        func entry(speed: Double) -> StatsDTO.PrefillProgressDTO {
            .init(requestId: "a", processed: 5_000, total: 20_000,
                  speed: speed, eta: 999, elapsed: 1, detail: nil)
        }

        XCTAssertEqual(smoother.smoothed([entry(speed: 2_000)]).first?.speed, 2_000)

        let dipped = try XCTUnwrap(smoother.smoothed([entry(speed: 1_000)]).first)
        let speed = try XCTUnwrap(dipped.speed)
        XCTAssertLessThan(speed, 2_000)
        XCTAssertGreaterThan(speed, 1_000)
        XCTAssertEqual(try XCTUnwrap(dipped.eta), 15_000 / speed, accuracy: 0.001)
    }

    func testSmootherRetainsOtherModelsAverages() throws {
        var smoother = PrefillSpeedSmoother(alpha: 0.35)
        func entry(_ id: String, speed: Double) -> StatsDTO.PrefillProgressDTO {
            .init(requestId: id, processed: 10_000, total: 20_000,
                  speed: speed, eta: nil, elapsed: 1, detail: nil)
        }
        _ = smoother.smoothed([entry("a", speed: 2_000)])
        _ = smoother.smoothed([entry("b", speed: 400)])
        smoother.retain(ids: ["a", "b"])

        XCTAssertGreaterThan(
            try XCTUnwrap(smoother.smoothed([entry("a", speed: 1_000)]).first?.speed), 1_000
        )
    }

    func testSmootherForgetsFinishedRequests() throws {
        var smoother = PrefillSpeedSmoother(alpha: 0.35)
        let finished = StatsDTO.PrefillProgressDTO(
            requestId: "a", processed: 10, total: 100, speed: 5_000,
            eta: nil, elapsed: 1, detail: nil)
        _ = smoother.smoothed([finished])
        smoother.retain(ids: [])

        let fresh = StatsDTO.PrefillProgressDTO(
            requestId: "a", processed: 10, total: 100, speed: 50,
            eta: nil, elapsed: 1, detail: nil)
        XCTAssertEqual(try XCTUnwrap(smoother.smoothed([fresh]).first?.speed), 50)
    }
}
