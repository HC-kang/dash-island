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
        return f
    }
}
