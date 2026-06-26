// GoLand 风格的 commit 图形轨道:从 commit 的 parent 关系算出每行的 lane
// 布局(分叉/合并彩线),再由 [GraphRail] 逐行用 Widget 渲染。
//
// 设计要点(单遍 active-lanes 扫描):自顶向下维护一个可变 `lanes` 数组,
// 每个 lane 记录它正在等待的下一个 commit hash。第 i 行扫描完后的状态,
// 正是第 i+1 行扫描前的状态——因此第 i 行底沿的锚点 lane 与第 i+1 行顶沿
// 的锚点 lane 天然一致,跨行连线无缝衔接。
//
// 渲染用纯 Widget(Stack/Positioned/ColoredBox/Transform.rotate)而非 CustomPaint:
// 本机 macOS/Impeller 下该 painter 的描边类 canvas 绘制不可靠(drawPath/drawLine
// 都不上屏,只有 drawCircle 能),改走 Flutter 标准渲染管线后连线稳定可见。
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../local/git.dart';
import '../../theme.dart';

/// 一条连线相对单元格(每格 width × rowH,圆点在垂直中点)的形态:
/// - [pass]   顶沿 lane → 底沿 lane(无关分支竖线;同 lane 即直竖线)
/// - [toDot]  顶沿 lane → 圆点(上半段:上方分支汇入本 commit)
/// - [fromDot] 圆点 → 底沿 lane(下半段:本 commit 流向某个 parent)
/// - [stub]   圆点 → 短尾(parent 在抓取窗口外/已被过滤,线在此截断,不再占用 lane)
enum EdgeKind { pass, toDot, fromDot, stub }

class GraphEdge {
  final int fromLane; // 顶沿锚点 lane(toDot 用;pass 的起点)
  final int toLane; // 底沿锚点 lane(fromDot 用;pass 的终点)
  final Color color;
  final EdgeKind kind;
  const GraphEdge(this.fromLane, this.toLane, this.color, this.kind);
}

class GraphRow {
  final int dotLane; // 圆点所在 lane
  final Color dotColor;
  final bool isMerge; // 多 parent => 空心环
  final List<GraphEdge> edges;
  const GraphRow({
    required this.dotLane,
    required this.dotColor,
    required this.isMerge,
    required this.edges,
  });
}

class GraphLayout {
  final List<GraphRow> rows;
  final int laneCount; // 全局统一 lane 数 => 所有行 rail 等宽
  const GraphLayout(this.rows, this.laneCount);
}

/// lane 调色板:复用主题色(accent/ok/warning/danger/accentBright)+ 7 个补充色,
/// 共 12 色循环(与 kMaxLanes 对齐,12 条并行 lane 互不撞色);复用 `CcColors` 避免
/// 与主题漂移。补充色在深色面板上挑了相互区分度较高的色相。
const List<Color> kLanePalette = [
  CcColors.accent, // 蓝
  CcColors.ok, // 绿
  CcColors.warning, // 琥珀
  CcColors.danger, // 红
  Color(0xFFB281EB), // 紫
  Color(0xFF4FC1B0), // 青
  CcColors.accentBright, // 亮蓝
  Color(0xFFF178B6), // 粉
  Color(0xFFE8924A), // 橙
  Color(0xFFA6CC59), // 黄绿
  Color(0xFFD06BC9), // 品红
  Color(0xFF7E83E0), // 靛蓝
];

const int kMaxLanes = 12; // rail 渲染上限,超出的 lane clamp 到最后一列
const double kLaneWidth = 14.0; // 每条 lane 的水平间距(略宽,连线更舒展、更易看见)

/// 在「显示中的列表」(已过滤)上计算图形布局。被过滤掉/超出抓取上限的
/// parent 视为悬空——其 lane 会一直 pass 到列表底部形成竖线 stub。
GraphLayout computeGraphRows(List<GitCommit> commits) {
  // 显示窗口内存在的 commit 集合;不在其中的 parent = 悬空(窗口外/被过滤),
  // 不为其保留 lane,否则会拖出一条贯穿到底的「幽灵竖线」、虚增 rail 宽度。
  final present = <String>{for (final c in commits) c.hash};
  final lanes = <String?>[]; // 各 lane 等待的下一个 hash(null = 空闲)
  final laneColors = <Color?>[];
  final rows = <GraphRow>[];
  var colorCounter = 0;
  var maxLane = 0;

  int firstFree() {
    for (var i = 0; i < lanes.length; i++) {
      if (lanes[i] == null) return i;
    }
    lanes.add(null);
    laneColors.add(null);
    return lanes.length - 1;
  }

  Color newColor() => kLanePalette[colorCounter++ % kLanePalette.length];

  for (final c in commits) {
    final edges = <GraphEdge>[];

    // 1) 已在等待本 commit 的 lane(由其子提交占位);最左者作圆点 lane。
    final waiting = <int>[];
    for (var i = 0; i < lanes.length; i++) {
      if (lanes[i] == c.hash) waiting.add(i);
    }

    final int dotLane;
    final Color dotColor;
    if (waiting.isEmpty) {
      // 没有可见子提交 => 一条新分支头,分配空闲 lane + 新颜色。
      dotLane = firstFree();
      dotColor = newColor();
      laneColors[dotLane] = dotColor;
    } else {
      dotLane = waiting.first;
      dotColor = laneColors[dotLane] ?? newColor();
      laneColors[dotLane] = dotColor;
    }

    // 2) 无关 lane 画 pass 竖线(顶沿 i → 底沿 i)。
    for (var i = 0; i < lanes.length; i++) {
      if (i == dotLane || lanes[i] == null || lanes[i] == c.hash) continue;
      edges.add(GraphEdge(i, i, laneColors[i] ?? dotColor, EdgeKind.pass));
    }

    // 3) 上方分支汇入圆点(顶沿 → 圆点);非圆点 lane 随后释放。
    for (final i in waiting) {
      edges.add(GraphEdge(i, dotLane, laneColors[i] ?? dotColor, EdgeKind.toDot));
    }
    for (final i in waiting) {
      if (i != dotLane) {
        lanes[i] = null;
        laneColors[i] = null;
      }
    }

    // 4) 圆点流向 parent(圆点 → 底沿)。悬空 parent 画短尾截断、不占 lane。
    final parents = c.parents;
    if (parents.isEmpty) {
      // root:lane 在此终止。
      lanes[dotLane] = null;
      laneColors[dotLane] = null;
    } else if (!present.contains(parents[0])) {
      // 第一个 parent 也悬空(窗口最底的 commit):短尾截断,释放 lane。
      edges.add(GraphEdge(dotLane, dotLane, dotColor, EdgeKind.stub));
      lanes[dotLane] = null;
      laneColors[dotLane] = null;
    } else {
      // 第一个 parent 续在圆点 lane,颜色不变。
      lanes[dotLane] = parents[0];
      edges.add(GraphEdge(dotLane, dotLane, dotColor, EdgeKind.fromDot));
      // 其余 parent(merge / octopus):复用或新分配 lane,各画一条扇出线;
      // 悬空的合并 parent 只画短尾,不分配会贯穿到底的 lane。
      for (var k = 1; k < parents.length; k++) {
        final p = parents[k];
        if (!present.contains(p)) {
          edges.add(GraphEdge(dotLane, dotLane, dotColor, EdgeKind.stub));
          continue;
        }
        var pl = -1;
        for (var i = 0; i < lanes.length; i++) {
          if (lanes[i] == p) {
            pl = i;
            break;
          }
        }
        if (pl == -1) {
          pl = firstFree();
          laneColors[pl] = newColor();
          lanes[pl] = p;
        }
        edges.add(
          GraphEdge(dotLane, pl, laneColors[pl] ?? dotColor, EdgeKind.fromDot),
        );
      }
    }

    // 记录本行实际占用的最大 lane 下标。
    var rowMax = dotLane;
    for (var i = 0; i < lanes.length; i++) {
      if (lanes[i] != null && i > rowMax) rowMax = i;
    }
    for (final e in edges) {
      if (e.fromLane > rowMax) rowMax = e.fromLane;
      if (e.toLane > rowMax) rowMax = e.toLane;
    }
    if (rowMax > maxLane) maxLane = rowMax;

    rows.add(
      GraphRow(
        dotLane: dotLane,
        dotColor: dotColor,
        isMerge: parents.length >= 2,
        edges: edges,
      ),
    );
  }

  final laneCount = (maxLane + 1).clamp(1, kMaxLanes);
  return GraphLayout(rows, laneCount);
}

/// 用纯 Widget 渲染单行的图形轨道切片(配合定高的 ListView 行)。
///
/// 不用 CustomPaint:本机 Impeller 下该 painter 的描边 canvas 绘制不上屏。改用
/// `Stack` + `Positioned`,竖线/斜线是 `ColoredBox`(斜线再套 `Transform.rotate`)、
/// 圆点是圆形 `DecoratedBox` —— 全部走 Flutter 标准渲染管线,稳定可见。
class GraphRail extends StatelessWidget {
  final GraphRow row;
  final int laneCount;
  final double laneWidth;
  final double rowHeight;
  final double lineWidth;
  final double dotRadius;

  const GraphRail({
    super.key,
    required this.row,
    required this.laneCount,
    this.laneWidth = kLaneWidth,
    this.rowHeight = 30,
    this.lineWidth = 2.2,
    this.dotRadius = 3.5,
  });

  double _x(int lane) => laneWidth / 2 + lane.clamp(0, laneCount - 1) * laneWidth;

  @override
  Widget build(BuildContext context) {
    final h = rowHeight;
    final mid = h / 2;
    final children = <Widget>[];

    // pass=贯穿竖线;toDot=上半段(汇入圆点);fromDot=下半段(流向 parent);
    // stub=圆点下方短尾。同 lane → 竖线;跨 lane → 斜线。
    for (final e in row.edges) {
      switch (e.kind) {
        case EdgeKind.pass:
          children.add(_seg(_x(e.fromLane), 0, _x(e.toLane), h, e.color));
        case EdgeKind.toDot:
          children.add(_seg(_x(e.fromLane), 0, _x(row.dotLane), mid, e.color));
        case EdgeKind.fromDot:
          children.add(_seg(_x(row.dotLane), mid, _x(e.toLane), h, e.color));
        case EdgeKind.stub:
          final a = _x(row.dotLane);
          children.add(_seg(a, mid, a, mid + (h - mid) * 0.6, e.color));
      }
    }

    // 圆点压在最上。
    final cx = _x(row.dotLane);
    final r = row.isMerge ? dotRadius + 0.5 : dotRadius;
    children.add(Positioned(
      left: cx - r,
      top: mid - r,
      width: 2 * r,
      height: 2 * r,
      child: DecoratedBox(
        decoration: BoxDecoration(color: row.dotColor, shape: BoxShape.circle),
      ),
    ));

    return SizedBox(
      width: laneCount * laneWidth,
      height: h,
      child: Stack(clipBehavior: Clip.none, children: children),
    );
  }

  /// 一条从 (x0,y0) 到 (x1,y1) 的线段:竖线用普通 `ColoredBox`,斜线用绕中心
  /// 旋转的 `ColoredBox`。两者都走标准渲染管线,绕开 canvas 描边不上屏的问题。
  Widget _seg(double x0, double y0, double x1, double y1, Color color) {
    if (x0 == x1) {
      return Positioned(
        left: x0 - lineWidth / 2,
        top: math.min(y0, y1),
        width: lineWidth,
        height: (y1 - y0).abs(),
        child: ColoredBox(color: color),
      );
    }
    final dx = x1 - x0;
    final dy = y1 - y0;
    final len = math.sqrt(dx * dx + dy * dy);
    final angle = math.atan2(dy, dx);
    final midX = (x0 + x1) / 2;
    final midY = (y0 + y1) / 2;
    return Positioned(
      left: midX - len / 2,
      top: midY - lineWidth / 2,
      width: len,
      height: lineWidth,
      child: Transform.rotate(angle: angle, child: ColoredBox(color: color)),
    );
  }
}
