import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../config/app_shape.dart';
import '../services/app_providers.dart';
import '../services/shared_text.dart';
import '../services/storage_service.dart';
import '../widgets/app_surface.dart';
import 'bookshelf_screen.dart';
import 'reading_home_screen.dart';
import 'reading_notes_screen.dart';
import 'shared_text_sheet.dart';

/// 读书版的一级容器：底部导航 + IndexedStack。
///
/// ## 为什么另起一个壳，而不是给 HomeShell 加参数
///
/// 两边的三个 tab 完全不同（主页/书架/栖息 vs 会话/书架/随笔），中间那个
/// 虽然都叫书架，但读书版进去之后的下一步也不一样。用一个 Shell 带开关，
/// 结果一定是每个方法里都在 `if (reading)`，两套逻辑缠在一起，改一边坏一边。
///
/// 分成两个壳，共用的是**下面那些页面和服务**，不是这层路由。这层本来就该
/// 各写各的。
class ReadingShell extends StatefulWidget {
  const ReadingShell({super.key});

  @override
  State<ReadingShell> createState() => _ReadingShellState();
}

class _ReadingShellState extends State<ReadingShell>
    with WidgetsBindingObserver {
  int _index = 0;

  /// 同一段别弹两次。
  ///
  /// 原生那边「取走即清」，但推送和回前台的取有可能撞在一起（分享时 App 正好
  /// 在后台，onNewIntent 推一次、resume 又取一次）。加一道锁比在原生那边猜
  /// 时序可靠。
  bool _showingShare = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadBackground();
    // 冷启动：分享的 intent 在 Dart 起来之前就到了，存在原生那边等着取。
    _takeShare();
    // 已经开着的时候又分享进来一条。
    SharedTextChannel.listen(_present);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 回到前台再取一次。
  ///
  /// 分享时 App 在后台的话，系统是把它拉到前台后才送 intent 的，那一下
  /// 未必落在哪个回调里。多取一次不会有副作用（没有就返回 null），
  /// 但少取一次的症状是「分享过去了，打开却什么都没有」。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _takeShare();
  }

  Future<void> _takeShare() async {
    final shared = await SharedTextChannel.take();
    if (shared != null) _present(shared);
  }

  Future<void> _present(SharedReading shared) async {
    if (!mounted || _showingShare) return;
    _showingShare = true;
    try {
      await showSharedTextSheet(context, shared);
    } finally {
      _showingShare = false;
    }
  }

  /// 背景图跟主 App 共用同一份存储。
  ///
  /// 两个入口装在同一台手机上是两个独立应用，各有各的沙盒，所以这里读到的
  /// 是读书版自己的设置，不会串。共用的只是代码。
  Future<void> _loadBackground() async {
    final bg = context.read<BackgroundProvider>();
    final path = await StorageService.getBackgroundImagePath();
    final preset = await StorageService.getBackgroundPreset();
    if (!mounted) return;
    await bg.update(path, preset);
  }

  void _select(int index) {
    if (!mounted || index == _index) return;
    HapticFeedback.selectionClick();
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _index = index);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Container(
        decoration: _backgroundDecoration(scheme),
        child: Column(
          children: [
            Expanded(
              child: IndexedStack(
                index: _index,
                children: const [
                  ReadingHomeScreen(),
                  BookshelfScreen(),
                  ReadingNotesScreen(),
                ],
              ),
            ),
            // 键盘弹起时收掉：同 HomeShell，它在 Column 里，不收会被顶到
            // 键盘正上方，白占一条。
            if (MediaQuery.of(context).viewInsets.bottom == 0)
              _floatingNav(scheme),
          ],
        ),
      ),
    );
  }

  BoxDecoration _backgroundDecoration(ColorScheme scheme) {
    final path = context.watch<BackgroundProvider>().path;
    if (path != null) {
      return BoxDecoration(
        image: DecorationImage(image: FileImage(File(path)), fit: BoxFit.cover),
      );
    }
    // 必须真的上色：Scaffold 是 transparent，这里返回空等于露出底下的纯黑。
    return BoxDecoration(color: scheme.surface);
  }

  Widget _floatingNav(ColorScheme scheme) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: SizedBox(
          height: 50,
          child: AppSurface(
            borderRadius: AppRadius.pillAll,
            floating: true,
            child: Row(
              children: [
                _navItem(0, 'star', 15, '讨论', scheme),
                _navItem(1, 'books', 16, '书架', scheme),
                _navItem(2, 'waves', 15, '随笔', scheme),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Color _selectedTint(ColorScheme scheme) {
    final accent = context.watch<BackgroundProvider>().backgroundAccent;
    if (accent == null) return scheme.primaryContainer;
    return accent.withValues(alpha: 0.26);
  }

  Widget _navItem(
    int index,
    String asset,
    double iconHeight,
    String label,
    ColorScheme scheme,
  ) {
    final selected = _index == index;
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.pill),
        onTap: () => _select(index),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          margin: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            color: selected ? _selectedTint(scheme) : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.pill),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Image.asset(
                'assets/icons/$asset.png',
                height: iconHeight,
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
              ),
              const SizedBox(height: 3),
              Text(
                label,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color:
                      selected
                          ? scheme.onPrimaryContainer
                          : scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
