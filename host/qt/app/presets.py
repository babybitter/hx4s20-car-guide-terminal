"""Declarative, idempotent effect presets; no implicit playback toggle."""

PRESETS = {
    "黑场淡变": {"commands": ("X0", "E1", "T0"), "expected": {"X": 0, "E": 1, "T": 0}, "description": "旧式转场 · 黑场淡出与淡入"},
    "横擦": {"commands": ("X0", "E1", "T1"), "expected": {"X": 0, "E": 1, "T": 1}, "description": "旧式转场 · 横向擦除"},
    "竖擦": {"commands": ("X0", "E1", "T2"), "expected": {"X": 0, "E": 1, "T": 2}, "description": "旧式转场 · 纵向擦除"},
    "棋盘遮罩": {"commands": ("X0", "E1", "T3"), "expected": {"X": 0, "E": 1, "T": 3}, "description": "旧式转场 · 棋盘遮罩"},
    "双图混合": {"commands": ("E1", "X1"), "expected": {"E": 1, "X": 1}, "description": "高级转场 · 双图交叉混合"},
    "向左滑动": {"commands": ("E1", "X2"), "expected": {"E": 1, "X": 2}, "description": "高级转场 · 水平滑动"},
    "向上滑动": {"commands": ("E1", "X3"), "expected": {"E": 1, "X": 3}, "description": "高级转场 · 垂直滑动"},
    "效果旁路": {"commands": ("X0", "E0"), "expected": {"X": 0, "E": 0}, "description": "关闭效果链，恢复旁路"},
}
