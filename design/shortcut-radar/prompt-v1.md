# 快捷键雷达：后台概念图 v1

状态：ImageGen 概念预览，尚未接入客户端。图中数据仅用于展示交互层级，不代表本机扫描结果。

生成方式：内置 ImageGen。参考当前 SettingsCaptureBoard.png 与 SettingsLayoutBoard.png 的纸白、铅笔轮廓与蜡笔色。

交互意图：上方组合键／用途搜索，左侧按已知占用数量排列，右侧查看应用、用途、范围及证据。重复使用不直接判定为冲突；作用范围未知时明确标记。检测按需运行，结果有界缓存，不设计空闲全量轮询。

## 生成提示词

```text
Use case: ui-mockup
Asset type: high fidelity concept PNG of the new "快捷键雷达" module inside our existing native macos-x utility. This is a DESIGN PREVIEW, not a live screen.
Input images: two reference images at supplied paths are STYLE REFERENCES ONLY (our current screenshot settings board and window-layout board). Preserve their refined white paper, graphite outlines, colored-pencil/crayon strokes and friendly hand-drawn macOS character. Design a new layout appropriate for shortcut discovery.
Primary request: A polished, usable Chinese desktop app module page. Flat front-facing screenshot, landscape 3:2, visually based on a 960×640 pt window, complete page fits one window, no scrolling needed to see primary controls. Crisp readable Chinese text, no perspective or laptop.
Style: bright near-white warm paper (#fdfcf9), extremely subtle fine paper grain, delicate pencil-gray rounded contours, restrained blue, lilac, soft coral and pale yellow crayon accents. Clear native-like body typography, friendly handwritten Chinese headings. Avoid dark bold borders or muddy grey backgrounds. Match the references. Real usable UI, minimal illustration.
Composition:
A thin header: small coral/yellow/sage traffic-light circles at top left, a quiet back chevron next to them, centered title "快捷键雷达", small pencil download arrow at top right. A fine pencil divider beneath.
Below header, one generous wide search field with small magnifier left, placeholder "按组合键，或搜索用途", and an outlined keyboard key icon on the right within the field. Separate modest button "检测一次" to its right. Under the search small low-contrast metadata "运行中的应用 · 按需检测".
Main workspace occupies the remaining page in two clearly aligned columns, approximately 38% left and 62% right, separated by a delicate pencil vertical line, with sensible 24px gutters and balanced spacing. Do not pack the entire UI into nested cards.
LEFT column title "拥挤排行", secondary tiny sorting indicator "占用数 ↓". Three small pill filters "全部" (selected pale blue), "全局", "应用内". Below three large clean clickable rows, each showing actual drawn keycaps and a restrained little crayon usage bar. First row selected with thin blue outline and very pale blue paper fill: keycaps "⌃" "⇧" "R", text "2 处使用", short coral crayon bar. Second row: keycaps "⌥" "⌘" "←", text "1 处使用", shorter lilac crayon bar. Third row: keycap "F3", text "1 处使用", shorter sage crayon bar. This is a small useful rank list, not a fake heatmap, not a complex radar circle, not a large statistic dashboard.
RIGHT column title "这个组合键做什么". Under title a nicely spaced row of large separate paper keycaps "⌃" "+" "⇧" "+" "R", and small secondary label "Control + Shift + R". One concise soft coral pencil note underneath: "发现重复用途，作用范围待核对". Below exactly two spacious source rows divided by fine pencil rules. First has a small blue folded-wing app icon, title "飞书", subtitle "录屏", and a subtle outlined badge "待核对". Second has a small blue lightning app icon, title "钉钉", subtitle "录屏", and badge "待核对". A pale yellow, low-emphasis annotation below them says "同一组合键，可能在不同场景生效". Lower down a quiet legend of three small dots and text "确认占用" in muted coral, "可能冲突" in muted amber, "归属未知" in graphite. Place legend on one line with clean spacing. No arbitrary unrelated switches, charts, percentages, permissions dialogs or large hero illustration.
A thin footer pencil line then small unobtrusive text at bottom left "概念预览 · 示例数据", at bottom right "↑↓ 选择 · Enter 查看". The screenshot must make it obvious that the search is primary, ranking rows are selectable and selecting one reveals its application uses. All text within frame, excellent alignment, balanced density, calm and premium. No giant empty lower half, no heavy drop shadows, no floating decorative arrows, no neon, no glassmorphism, no web admin sidebar. Do not add features not listed.
```
