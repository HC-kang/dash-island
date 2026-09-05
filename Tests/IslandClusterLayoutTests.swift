import Foundation

enum IslandClusterLayoutSuite {
    static func run() -> Int {
        print("IslandClusterLayout")
        var f = 0
        f += check("scroll only when over maxVisible") {
            try assertTrue(!IslandClusterLayout.needsHorizontalScroll(slotCount: 5, maxVisible: 5))
            try assertTrue(IslandClusterLayout.needsHorizontalScroll(slotCount: 6, maxVisible: 5))
            try assertTrue(!IslandClusterLayout.needsHorizontalScroll(slotCount: 3, maxVisible: 5))
        }
        f += check("viewport slot count caps at maxVisible") {
            try assertEqual(IslandClusterLayout.viewportSlotCount(slotCount: 8, maxVisible: 5), 5)
            try assertEqual(IslandClusterLayout.viewportSlotCount(slotCount: 3, maxVisible: 5), 3)
        }
        f += check("hang tip starts below cell height (would be clipped by ScrollView)") {
            let cellH = 120.0
            let tipTop = IslandClusterLayout.hangTipTopY(cellHeight: cellH, tipGap: 8)
            try assertTrue(tipTop > cellH, "tip top \(tipTop) should be below cell \(cellH)")
            // Documents the regression: a viewport that clips to cellH hides hang tips.
            try assertTrue(
                IslandClusterLayout.hangTipClippedByCellHeightViewport(cellHeight: cellH, tipGap: 8),
                "hang tips are outside a cell-height clip rect — host must not clip them"
            )
        }
        f += check("mask preserves centered edge tips above and below the island bottom") {
            for count in [3, 5, 6, 8] {
                let bodyWidth = IslandClusterLayout.islandBodyWidth(itemCount: count)
                let blackHeight = 168.0
                let strip = IslandClusterLayout.hangTipMaskRect(
                    bodyWidth: bodyWidth, blackHeight: blackHeight, tooltipHeight: 200
                )
                // First/last slots, plus slots scrolled to the viewport edge.
                for centerX in [0, 64, bodyWidth - 64, bodyWidth] {
                    for tipWidth in [220.0, 288.0] {
                        // Bubble starts 6pt above the body bottom; caret rises another 5pt.
                        let tip = CGRect(
                            x: centerX - tipWidth / 2, y: blackHeight - 11,
                            width: tipWidth, height: 180
                        )
                        try assertTrue(strip.contains(tip), "centered tip must clear the mask: \(tip)")
                    }
                }
                try assertEqual(strip.midX, bodyWidth / 2, accuracy: 0.01)
                try assertEqual(strip.maxY, blackHeight + 200, accuracy: 0.01)
                try assertTrue(!strip.contains(CGPoint(x: -1, y: blackHeight - 29)),
                               "upper gauges must still be clipped to the island")
            }
        }
        f += check("tooltip overlap stops at the top of a short body") {
            let strip = IslandClusterLayout.hangTipMaskRect(
                bodyWidth: 352, blackHeight: 20, tooltipHeight: 200
            )
            try assertEqual(strip.minY, 0, accuracy: 0.01)
            try assertEqual(strip.maxY, 220, accuracy: 0.01)
        }
        f += check("row centers when content fits; origin 0 when overflow") {
            try assertEqual(
                IslandClusterLayout.centeredRowOrigin(contentWidth: 400, availableWidth: 500),
                50,
                accuracy: 0.01
            )
            try assertEqual(
                IslandClusterLayout.centeredRowOrigin(contentWidth: 600, availableWidth: 500),
                0,
                accuracy: 0.01
            )
            try assertTrue(IslandClusterLayout.needsScroll(contentWidth: 600, availableWidth: 500))
            try assertTrue(!IslandClusterLayout.needsScroll(contentWidth: 400, availableWidth: 500))
        }
        f += check("body width uses viewport slots, not full account count") {
            // 6 accounts still size to 5 visible slots.
            let body5 = IslandClusterLayout.islandBodyWidth(
                itemCount: 5,
                padLeading: 14,
                padTrailing: 10,
                addChrome: 16
            )
            let body6 = IslandClusterLayout.islandBodyWidth(
                itemCount: 6,
                padLeading: 14,
                padTrailing: 10,
                addChrome: 16
            )
            try assertEqual(body5, body6, accuracy: 0.01)
            // 5×100 + 4×12 + 14 + 10 + 16 = 588
            try assertEqual(body6, 588, accuracy: 0.01)
        }
        f += check("slot band equals visible row; 6th account forces scroll") {
            let body = IslandClusterLayout.islandBodyWidth(
                itemCount: 6,
                padLeading: 14,
                padTrailing: 10,
                addChrome: 16
            )
            let band = IslandClusterLayout.slotBandWidth(
                bodyWidth: body,
                padLeading: 14,
                padTrailing: 4, // root trailing when add chrome present
                addChrome: 22   // chevron 16 + outer pad 6
            )
            let visibleRow = IslandClusterLayout.rowWidth(slotCount: 5)
            let fullRow = IslandClusterLayout.rowWidth(slotCount: 6)
            try assertEqual(band, visibleRow, accuracy: 0.01)
            try assertTrue(IslandClusterLayout.needsScroll(contentWidth: fullRow, availableWidth: band))
            try assertTrue(!IslandClusterLayout.needsScroll(contentWidth: visibleRow, availableWidth: band))
        }
        return f
    }
}
