import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/app_shape.dart';
import '../services/chat_images.dart';

/// 气泡里图片能占的宽度：气泡最宽 262，左右各留 13 的内边距。
///
/// 和 `MessageBubble._maxBubbleWidth` 是一对，改那边要跟着改这里——
/// 卡片、按钮、网格都是按这个数排的，宽了会溢出。
const double kChatImageContentWidth = 262 - 13 * 2;

/// 老数据里内联 base64 图 → 字节。带上限。
///
/// ## 为什么非缓存不可
///
/// [MemoryImage] 的缓存键是**字节对象本身**（比的是 `bytes` 的 identity）。
/// 在 build 里直接 `base64Decode(...)`，每次重建都得到一个全新的
/// `Uint8List`，也就是**一个新键**——于是每重建一次，就往 Flutter 的全局
/// 图片缓存里塞一张**永远不会被命中的新图**。带图的对话多滚几轮，几十 MB
/// 就这么静静地堆进去了。
///
/// 同一个字符串解出来的字节保持同一个对象，键才稳定。上限防的是另一个
/// 方向：字节本身也别无限涨，淘汰掉的代价只是下次重解一遍。
///
/// 新发的图已经是文件了（见 [ChatImages]），这里只剩备份恢复回来的老数据会走。
const int _inlineBytesMax = 4 * 1024 * 1024;
final Map<String, Uint8List> _inlineBytes = {};
int _inlineBytesTotal = 0;

Uint8List _decodeInline(String base64Text) {
  final hit = _inlineBytes.remove(base64Text);
  if (hit != null) {
    // 放回队尾：刚渲染过的不该是下一个被淘汰的。
    _inlineBytes[base64Text] = hit;
    return hit;
  }
  final bytes = base64Decode(base64Text);
  _inlineBytes[base64Text] = bytes;
  _inlineBytesTotal += bytes.length;
  while (_inlineBytesTotal > _inlineBytesMax && _inlineBytes.isNotEmpty) {
    final oldest = _inlineBytes.keys.first;
    _inlineBytesTotal -= _inlineBytes.remove(oldest)!.length;
  }
  return bytes;
}

/// 一张聊天图片的 [ImageProvider]。已清理、文件没了、数据坏了都返回 null。
///
/// [cacheWidth] 给气泡里的小图用：卡片最宽也就一两百逻辑像素，按原图
/// 1920 解码是白占内存。全屏看图时不传，要原图。
ImageProvider? chatImageProvider(String image, {int? cacheWidth}) {
  final ImageProvider base;
  if (ChatImages.isCleared(image)) return null;
  if (ChatImages.isFileRef(image)) {
    final file = ChatImages.fileOf(image);
    if (file == null) return null;
    base = FileImage(file);
  } else {
    try {
      base = MemoryImage(_decodeInline(image));
    } catch (_) {
      return null;
    }
  }
  return cacheWidth == null ? base : ResizeImage(base, width: cacheWidth);
}

/// 气泡里的图。
///
/// - 一张：按原比例显示，点开看大图
/// - 两张及以上：**叠成一摞卡片**，左右拖着翻，旁边一个「展开 N」
///   （Cleo 2026-09-14 拿微信的截图来要的）。展开后就地铺成网格，按钮变「收起」
///
/// 点任意一张都进全屏（[ChatImageViewer]），能双指放大、左右滑。
class ChatImageGallery extends StatefulWidget {
  const ChatImageGallery({
    super.key,
    required this.images,
    this.alignEnd = false,
  });

  final List<String> images;

  /// 用户那侧（靠右）。「展开」按钮放在朝屏幕中间的那一边，
  /// 和卡片露出来的边错开。
  final bool alignEnd;

  @override
  State<ChatImageGallery> createState() => _ChatImageGalleryState();
}

class _ChatImageGalleryState extends State<ChatImageGallery> {
  bool _expanded = false;

  void _open(int index) {
    HapticFeedback.selectionClick();
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: false,
        transitionDuration: const Duration(milliseconds: 180),
        reverseTransitionDuration: const Duration(milliseconds: 160),
        pageBuilder:
            (context, animation, secondaryAnimation) =>
                ChatImageViewer(images: widget.images, initialIndex: index),
        transitionsBuilder:
            (context, animation, secondaryAnimation, child) =>
                FadeTransition(opacity: animation, child: child),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final images = widget.images;
    if (images.length == 1) {
      return _SingleImage(images.first, onTap: () => _open(0));
    }
    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: _expanded ? _grid() : _stack(),
    );
  }

  Widget _stack() {
    final pill = Flexible(
      // 字体放大时宁可把按钮缩一点，也不能让整行溢出红条。
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: _Pill(
          label: '展开 ${widget.images.length}',
          onTap: () => setState(() => _expanded = true),
        ),
      ),
    );
    final stack = _CardStack(images: widget.images, onOpen: _open);
    return SizedBox(
      width: kChatImageContentWidth,
      child: Row(
        mainAxisAlignment:
            widget.alignEnd ? MainAxisAlignment.end : MainAxisAlignment.start,
        children:
            widget.alignEnd
                ? [pill, const SizedBox(width: 8), stack]
                : [stack, const SizedBox(width: 8), pill],
      ),
    );
  }

  Widget _grid() {
    final n = widget.images.length;
    // 两张、四张排两列，看着是一块整的；其余三列。
    final columns = (n == 2 || n == 4) ? 2 : 3;
    const gap = 4.0;
    final side = (kChatImageContentWidth - gap * (columns - 1)) / columns;
    return SizedBox(
      width: kChatImageContentWidth,
      child: Column(
        crossAxisAlignment:
            widget.alignEnd ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (var i = 0; i < n; i++)
                GestureDetector(
                  onTap: () => _open(i),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                    child: _ImageTile(
                      widget.images[i],
                      width: side,
                      height: side,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          _Pill(label: '收起', onTap: () => setState(() => _expanded = false)),
        ],
      ),
    );
  }
}

/// 一摞卡片，**按发送顺序排**：看过的叠在左边，没看的叠在右边。
///
/// 往左划翻到下一张，往右划翻回上一张。**到最后一张再往左就划不动了**
/// （只留一点阻尼回弹），到第一张往右也一样。
///
/// ## 为什么不循环
///
/// 2026-09-14 第一版是循环的：翻走的那张塞回最底下，一直划会转回第一张。
/// Cleo 拿微信对比说，微信划到头就停——**这样才看得出发照片的顺序**。
/// 循环起来，翻几下就分不清哪张是第一张了。
///
/// 同一天更早还改过一次：整张飞出屏幕，她说「图片扔出去了」。现在翻页时
/// 卡片只往外甩出 [_swing] 那么远，就收回到左边那一摞后面。
///
/// ## 怎么摆
///
/// 只有一个连续的数 [_pos]：现在翻到第几张，拖到一半时是小数。每张卡按
/// `r = 下标 - _pos` 摆：r = 0 在最上面，r > 0 往右露边，r < 0 往左露边，
/// 每深一层挪 [_peek]、缩 6%，最多露两层。r 从 0 走到 -1 的路上多一段往外甩
/// 的弧线（sin），像把卡片从上面抽走、再塞到左边那摞后面。
///
/// 手指拖动直接改 [_pos]，所以卡片始终跟手；松手再动画到最近的整数。
class _CardStack extends StatefulWidget {
  const _CardStack({required this.images, required this.onOpen});

  final List<String> images;
  final void Function(int index) onOpen;

  @override
  State<_CardStack> createState() => _CardStackState();
}

class _CardStackState extends State<_CardStack>
    with SingleTickerProviderStateMixin {
  // 2026-09-14 从 150×200 → 140×187 → 120×160：图挪出气泡以后，一大摞卡片
  // 单独立在那儿显得很占地方，Cleo 说「整体可以再小一点点」。
  static const _cardWidth = 120.0;
  static const _cardHeight = 160.0;
  static const _peek = 6.0;
  static const _maxDepth = 2;

  /// 手指拖多远算翻过一整张。
  static const _span = _cardWidth * 0.9;

  /// 翻页路上卡片往外甩出去最远多少。
  static const _swing = _cardWidth * 0.45;

  /// 松手时甩得这么快，不够半张也算翻。
  static const _flipVelocity = 500.0;

  /// 到头以后最多还能多拖出去几分之一张——给个「到底了」的手感，不是真能翻。
  static const _overscroll = 0.12;

  double _pos = 0;
  double _dragStartPos = 0;
  double _dragDx = 0;

  late final AnimationController _ctrl = AnimationController(vsync: this);
  Animation<double> _anim = const AlwaysStoppedAnimation(0);

  int get _last => widget.images.length - 1;
  int get _current => _pos.round().clamp(0, _last);

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(() => setState(() => _pos = _anim.value));
  }

  @override
  void didUpdateWidget(covariant _CardStack old) {
    super.didUpdateWidget(old);
    if (old.images.length != widget.images.length) _pos = 0;
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// 两头之外只跟手 1/4，并且封顶 [_overscroll]。
  double _resist(double p) {
    if (p < 0) return -math.min(-p * 0.25, _overscroll);
    if (p > _last) return _last + math.min((p - _last) * 0.25, _overscroll);
    return p;
  }

  void _onDragStart(DragStartDetails d) {
    _ctrl.stop();
    _dragStartPos = _pos;
    _dragDx = 0;
  }

  void _onDragUpdate(DragUpdateDetails d) {
    _dragDx += d.delta.dx;
    // 往左拖 = 往后翻，所以是减。
    setState(() => _pos = _resist(_dragStartPos - _dragDx / _span));
  }

  void _onDragEnd(DragEndDetails d) {
    final v = d.velocity.pixelsPerSecond.dx;
    final from = _dragStartPos.round();
    var target = _pos.round();
    if (v < -_flipVelocity) target = _pos.floor() + 1;
    if (v > _flipVelocity) target = _pos.ceil() - 1;
    // 一次只翻一张，而且不出头。
    target = target.clamp(from - 1, from + 1).clamp(0, _last);
    if (target != from) HapticFeedback.selectionClick();

    _anim = Tween(
      begin: _pos,
      end: target.toDouble(),
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));
    _ctrl.duration = const Duration(milliseconds: 260);
    _ctrl.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.images.length;
    // 离当前张越远越先画，近的压在上面。
    final painted = [
      for (var i = 0; i < n; i++)
        if ((i - _pos).abs() < _maxDepth + 1) i,
    ]..sort((a, b) => (b - _pos).abs().compareTo((a - _pos).abs()));

    return Semantics(
      label: '第 ${_current + 1} 张，共 $n 张',
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => widget.onOpen(_current),
        onHorizontalDragStart: _onDragStart,
        onHorizontalDragUpdate: _onDragUpdate,
        onHorizontalDragEnd: _onDragEnd,
        child: SizedBox(
          // 左右各留两层露边的位置，翻到哪一张整摞都不挪窝。
          width: _cardWidth + _peek * _maxDepth * 2,
          height: _cardHeight,
          child: Stack(
            clipBehavior: Clip.none,
            children: [for (final i in painted) _card(i)],
          ),
        ),
      ),
    );
  }

  Widget _card(int i) {
    final r = i - _pos;
    final a = r.abs();
    final depth = math.min(a, _maxDepth.toDouble());
    // 只有「离开最上面、去左边」的那一段往外甩。从右边顶上来的那张直接滑过来。
    final swing = (r < 0 && a < 1) ? math.sin(a * math.pi) : 0.0;
    final side = r < 0 ? -1.0 : 1.0;
    return Positioned(
      left: _peek * _maxDepth + side * _peek * depth - swing * _swing,
      top: 0,
      child: Transform.rotate(
        angle: -swing * 0.18,
        alignment: Alignment.bottomCenter,
        child: Transform.scale(
          scale: 1 - depth * 0.06,
          alignment: r < 0 ? Alignment.centerLeft : Alignment.centerRight,
          child: _framed(i),
        ),
      ),
    );
  }

  Widget _framed(int index) {
    const border = 1.5;
    return Container(
      width: _cardWidth,
      height: _cardHeight,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.75),
          width: border,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.sm - border),
        child: _ImageTile(
          widget.images[index],
          width: _cardWidth,
          height: _cardHeight,
        ),
      ),
    );
  }
}

/// 单张：按原比例，最宽占满气泡、最高 280。
class _SingleImage extends StatelessWidget {
  const _SingleImage(this.image, {required this.onTap});

  final String image;
  final VoidCallback onTap;

  static const _maxHeight = 280.0;

  @override
  Widget build(BuildContext context) {
    final provider = chatImageProvider(image, cacheWidth: 720);
    final radius = BorderRadius.circular(AppRadius.sm);
    if (provider == null) {
      return ClipRRect(
        borderRadius: radius,
        child: const _Cleared(width: kChatImageContentWidth, height: 120),
      );
    }
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: radius,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: kChatImageContentWidth,
            maxHeight: _maxHeight,
          ),
          child: Image(
            image: provider,
            fit: BoxFit.contain,
            // 图还没解出来时尺寸是 0，气泡会先缩成一条再猛地撑开。
            // 先占一块位置。
            frameBuilder:
                (context, child, frame, wasSynchronouslyLoaded) =>
                    frame == null && !wasSynchronouslyLoaded
                        ? const SizedBox(
                          width: kChatImageContentWidth,
                          height: 160,
                        )
                        : child,
            errorBuilder:
                (context, error, stack) =>
                    const _Cleared(width: kChatImageContentWidth, height: 120),
          ),
        ),
      ),
    );
  }
}

/// 固定尺寸、裁满的一格。卡片和网格都用它。
class _ImageTile extends StatelessWidget {
  const _ImageTile(this.image, {required this.width, required this.height});

  final String image;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final provider = chatImageProvider(image, cacheWidth: 720);
    if (provider == null) return _Cleared(width: width, height: height);
    return Image(
      image: provider,
      width: width,
      height: height,
      fit: BoxFit.cover,
      errorBuilder:
          (context, error, stack) => _Cleared(width: width, height: height),
    );
  }
}

class _Cleared extends StatelessWidget {
  const _Cleared({required this.width, required this.height});

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      color: Colors.black.withValues(alpha: 0.06),
      alignment: Alignment.center,
      child: const Text(
        '图片已清理',
        style: TextStyle(fontSize: 12, color: Colors.black45),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(999),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: Text(
          label,
          style: const TextStyle(fontSize: 13, color: Colors.black87),
        ),
      ),
    );
  }
}

/// 全屏看图：左右滑、双指放大，点一下关掉。
///
/// ⚠️ 放大之后要**锁住翻页**。[InteractiveViewer] 平移和 [PageView] 翻页抢的是
/// 同一个横向手势，而翻页的判定距离更短，总是它赢——不锁的话，放大了想往
/// 右挪一点看细节，结果直接翻到下一张。
class ChatImageViewer extends StatefulWidget {
  const ChatImageViewer({
    super.key,
    required this.images,
    this.initialIndex = 0,
  });

  final List<String> images;
  final int initialIndex;

  @override
  State<ChatImageViewer> createState() => _ChatImageViewerState();
}

class _ChatImageViewerState extends State<ChatImageViewer> {
  late final PageController _pages = PageController(
    initialPage: widget.initialIndex,
  );
  late int _index = widget.initialIndex;
  bool _zoomed = false;
  final _transforms = <int, TransformationController>{};

  TransformationController _transformFor(int i) =>
      _transforms.putIfAbsent(i, () {
        final c = TransformationController();
        c.addListener(() {
          final zoomed = c.value.getMaxScaleOnAxis() > 1.01;
          if (i == _index && zoomed != _zoomed) {
            setState(() => _zoomed = zoomed);
          }
        });
        return c;
      });

  @override
  void dispose() {
    _pages.dispose();
    for (final c in _transforms.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.images.length;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            PageView.builder(
              controller: _pages,
              physics: _zoomed ? const NeverScrollableScrollPhysics() : null,
              itemCount: n,
              onPageChanged: (i) {
                // 翻走的那张复原，回来时不是还放大着。
                _transforms[_index]?.value = Matrix4.identity();
                setState(() {
                  _index = i;
                  _zoomed = false;
                });
              },
              itemBuilder: (context, i) {
                final provider = chatImageProvider(widget.images[i]);
                return GestureDetector(
                  onTap: () => Navigator.of(context).pop(),
                  child: InteractiveViewer(
                    transformationController: _transformFor(i),
                    minScale: 1,
                    maxScale: 4,
                    child: Center(
                      child:
                          provider == null
                              ? const Text(
                                '图片已清理',
                                style: TextStyle(color: Colors.white54),
                              )
                              : Image(
                                image: provider,
                                fit: BoxFit.contain,
                                errorBuilder:
                                    (context, error, stack) => const Text(
                                      '图片已清理',
                                      style: TextStyle(color: Colors.white54),
                                    ),
                              ),
                    ),
                  ),
                );
              },
            ),
            if (n > 1)
              Positioned(
                top: MediaQuery.paddingOf(context).top + 12,
                left: 0,
                right: 0,
                child: Center(
                  child: Text(
                    '${_index + 1} / $n',
                    style: const TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
