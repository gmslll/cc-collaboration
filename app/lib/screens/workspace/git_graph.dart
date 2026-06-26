// GoLand 风格的 commit 图形轨道:从 commit 的 parent 关系算出每行的 lane
// 布局(分叉/合并彩线),再由 [GraphRailPainter] 逐行绘制。
//
// 设计要点(单遍 active-lanes 扫描):自顶向下维护一个可变 `lanes` 数组,
// 每个 lane 记录它正在等待的下一个 commit hash。第 i 行扫描完后的状态,
// 正是第 i+1 行扫描前的状态——因此第 i 行底沿的锚点 lane 与第 i+1 行顶沿
// 的锚点 lane 天然一致,跨行连线无缝衔接。
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

/// lane 调色板:复用主题色(accent/ok/warning/danger/accentBright)+ 3 个补充色,
/// 共 8 色循环;复用 `CcColors` 避免与主题漂移。
const List<Color> kLanePalette = [
  CcColors.accent, // 蓝
  CcColors.ok, // 绿
  CcColors.warning, // 琥珀
  CcColors.danger, // 红
  Color(0xFFB281EB), // 紫
  Color(0xFF4FC1B0), // 青
  CcColors.accentBright, // 亮蓝
  Color(0xFFF178B6), // 粉
];

const int kMaxLanes = 8; // rail 渲染上限,超出的 lane clamp 到最后一列
const double kLaneWidth = 11.0; // 每条 lane 的水平间距(紧凑,贴近 GoLand)

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

/// 绘制单行的图形轨道切片(配合定高的 ListView 行)。
class GraphRailPainter extends CustomPainter {
  final GraphRow row;
  final int laneCount;
  final double laneWidth;
  final double dotRadius;

  const GraphRailPainter({
    required this.row,
    required this.laneCount,
    this.laneWidth = kLaneWidth,
    this.dotRadius = 3.0,
  });

  double _x(int lane) {
    final l = lane >= laneCount ? laneCount - 1 : (lane < 0 ? 0 : lane);
    return laneWidth / 2 + l * laneWidth;
  }

  // 连线宽度。用「填充缎带」而非描边绘制:macOS/Impeller 会丢弃本 painter 里的
  // PaintingStyle.stroke 描边,但填充(圆点/路径)能稳定上屏。
  static const double _lineWidth = 2.4;

  @override
  void paint(Canvas canvas, Size size) {
    final h = size.height;
    final mid = h / 2;

    // pass < toDot < stub < fromDot,圆点最后压在最上。
    for (final phase in const [
      EdgeKind.pass,
      EdgeKind.toDot,
      EdgeKind.stub,
      EdgeKind.fromDot,
    ]) {
      for (final e in row.edges) {
        if (e.kind != phase) continue;
        switch (e.kind) {
          case EdgeKind.pass:
            final a = _x(e.fromLane);
            final b = _x(e.toLane);
            _fillRibbon(canvas, Offset(a, 0), Offset(a, mid), Offset(b, mid),
                Offset(b, h), e.color);
          case EdgeKind.toDot:
            final a = _x(e.fromLane);
            final b = _x(row.dotLane);
            final m = mid / 2;
            _fillRibbon(canvas, Offset(a, 0), Offset(a, m), Offset(b, m),
                Offset(b, mid), e.color);
          case EdgeKind.fromDot:
            final a = _x(row.dotLane);
            final b = _x(e.toLane);
            final m = (mid + h) / 2;
            _fillRibbon(canvas, Offset(a, mid), Offset(a, m), Offset(b, m),
                Offset(b, h), e.color);
          case EdgeKind.stub:
            // 短尾:从圆点向下走半程即止,表示线索延伸到窗口外。
            final a = _x(row.dotLane);
            final end = mid + (h - mid) * 0.6;
            _fillRibbon(canvas, Offset(a, mid), Offset(a, mid), Offset(a, end),
                Offset(a, end), e.color);
        }
      }
    }

    // 圆点(填充)压在最上。
    final cx = _x(row.dotLane);
    canvas.drawCircle(
      Offset(cx, mid),
      row.isMerge ? dotRadius + 0.5 : dotRadius,
      Paint()
        ..color = row.dotColor
        ..isAntiAlias = true,
    );
  }

  // _fillRibbon 把三次贝塞尔 (p0,c1,c2,p3) 当作 [_lineWidth] 宽的「填充缎带」画
  // 出来(逐点法向偏移成闭合多边形 + 两端圆头),全程只用填充,绕开 Impeller 的
  // 描边不渲染问题;圆头让相邻行/圆点处衔接顺滑。
  void _fillRibbon(
    Canvas canvas,
    Offset p0,
    Offset c1,
    Offset c2,
    Offset p3,
    Color color,
  ) {
    const steps = 10;
    final pts = <Offset>[];
    for (var i = 0; i <= steps; i++) {
      final t = i / steps;
      final u = 1 - t;
      pts.add(
        Offset(
          u * u * u * p0.dx +
              3 * u * u * t * c1.dx +
              3 * u * t * t * c2.dx +
              t * t * t * p3.dx,
          u * u * u * p0.dy +
              3 * u * u * t * c1.dy +
              3 * u * t * t * c2.dy +
              t * t * t * p3.dy,
        ),
      );
    }
    final half = _lineWidth / 2;
    final left = <Offset>[];
    final right = <Offset>[];
    for (var i = 0; i < pts.length; i++) {
      Offset dir;
      if (i == 0) {
        dir = pts[1] - pts[0];
      } else if (i == pts.length - 1) {
        dir = pts[i] - pts[i - 1];
      } else {
        dir = pts[i + 1] - pts[i - 1];
      }
      final len = dir.distance;
      dir = len == 0 ? const Offset(0, 1) : dir / len;
      final perp = Offset(-dir.dy, dir.dx) * half;
      left.add(pts[i] + perp);
      right.add(pts[i] - perp);
    }
    final path = Path()..moveTo(left.first.dx, left.first.dy);
    for (final p in left.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    for (var i = right.length - 1; i >= 0; i--) {
      path.lineTo(right[i].dx, right[i].dy);
    }
    path.close();
    final paint = Paint()
      ..color = color
      ..isAntiAlias = true;
    canvas.drawPath(path, paint);
    canvas.drawCircle(pts.first, half, paint);
    canvas.drawCircle(pts.last, half, paint);
  }

  @override
  bool shouldRepaint(GraphRailPainter old) =>
      !identical(old.row, row) ||
      old.laneCount != laneCount ||
      old.laneWidth != laneWidth;
}
