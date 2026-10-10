import CoreGraphics
import Foundation
import Testing
@testable import ActivityCore

@Suite("Treemap")
struct TreemapTests {
    let bounds = CGRect(x: 10, y: 20, width: 600, height: 400)

    @Test func fillsTheAreaProportionally() {
        let weights: [Double] = [6, 6, 4, 3, 2, 2, 1]
        let rects = Treemap.layout(weights, in: bounds)
        #expect(rects.count == weights.count)
        let total = rects.reduce(0.0) { $0 + Double($1.width * $1.height) }
        #expect(abs(total - Double(bounds.width * bounds.height)) < 0.5)
        let scale = Double(bounds.width * bounds.height) / weights.reduce(0, +)
        for (rect, weight) in zip(rects, weights) {
            #expect(abs(Double(rect.width * rect.height) - weight * scale) < 1)
            #expect(bounds.insetBy(dx: -0.001, dy: -0.001).contains(rect))
        }
    }

    @Test func rectanglesDoNotOverlap() {
        let weights = (1 ... 40).map { 1000.0 / Double($0) }
        let rects = Treemap.layout(weights, in: bounds)
        for i in rects.indices {
            for j in rects.indices where j > i {
                let overlap = rects[i].intersection(rects[j])
                #expect(overlap.isNull || overlap.width * overlap.height < 0.01)
            }
        }
    }

    @Test func keepsOrderAndPutsTheLargestFirst() {
        let weights: [Double] = [50, 30, 20]
        let rects = Treemap.layout(weights, in: bounds)
        // Largest tile starts in the top-left corner; areas follow the weights.
        #expect(rects[0].origin == bounds.origin)
        #expect(rects[0].width * rects[0].height > rects[1].width * rects[1].height)
        #expect(rects[1].width * rects[1].height > rects[2].width * rects[2].height)
    }

    @Test func squarifiesInsteadOfSlicing() {
        let rects = Treemap.layout([1, 1, 1, 1], in: CGRect(x: 0, y: 0, width: 200, height: 200))
        for rect in rects {
            #expect(abs(rect.width - 100) < 0.01 && abs(rect.height - 100) < 0.01)
        }
    }

    @Test func zeroWeightsAndEmptyInput() {
        #expect(Treemap.layout([], in: bounds).isEmpty)
        let rects = Treemap.layout([5, 0, 5], in: bounds)
        #expect(rects[1].width * rects[1].height == 0)
        #expect(abs(Double(rects[0].width * rects[0].height + rects[2].width * rects[2].height) - Double(bounds.width * bounds.height)) < 0.5)
        #expect(Treemap.layout([0, 0], in: bounds).allSatisfy { $0.width == 0 })
    }
}
