import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../config/app_tab.dart';
import '../services/app_providers.dart';
import '../services/storage_service.dart';
import 'chat_screen.dart';
import 'bookshelf_screen.dart';
import 'habitat_screen.dart';
import '../config/app_shape.dart';
import '../widgets/app_surface.dart';

/// App 一级页面容器：底部导航 + IndexedStack。
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;
  bool _hideNav = false;

  @override
  void initState() {
    super.initState();
    _loadBackground();
  }

  /// 把存储里的背景喂给 provider。启动时跑一次；聊天页改完背景也回调这里。
  ///
  /// 不再往本 State 里存一份路径——画背景直接读 provider，见
  /// [_buildBackgroundDecoration]。
  Future<void> _loadBackground() async {
    final bgProvider = context.read<BackgroundProvider>();
    final path = await StorageService.getBackgroundImagePath();
    final preset = await StorageService.getBackgroundPreset();
    if (!mounted) return;
    await bgProvider.update(path, preset);
  }

  /// 切 tab 的唯一入口——底部导航和 [_switchTo] 都走这里。
  ///
  /// IndexedStack 让三个 tab 常驻，聊天页输入框的焦点会一直留着。不主动收掉的话，
  /// 从别的页面 push 再 pop 回来时焦点被还给它，于是在「栖息」页也会莫名弹出键盘。
  void _selectIndex(int index) {
    if (!mounted || index == _index) return;
    // 放在早退之后：重复点当前 Tab 不该震。
    HapticFeedback.selectionClick();
    FocusManager.instance.primaryFocus?.unfocus();
    // 换了页就把上一页的提示收掉。SnackBar 挂在整个 App 的层级上，不属于某一页——
    // 不清的话，在栖息页勾完一件小事，那条「做完了」会跟着她回到主页。
    ScaffoldMessenger.of(context).clearSnackBars();
    setState(() => _index = index);
  }

  void _switchTo(AppTab tab) => _selectIndex(tab.index);

  void _onChatModeChanged(bool inChat) {
    if (mounted && inChat != _hideNav) {
      setState(() => _hideNav = inChat);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final decoration = _buildBackgroundDecoration(scheme);
    // ⚠️ 别在这里加整页模糊。
    //
    // 试过一版：在背景图和内容之间垫一层全屏 BackdropFilter，卡片只留半透明。
    // 它确实治好了滚动闪烁，但代价是**把背景图整个毁了**——糊的不只是卡片
    // 背后那块，是整张图。于是不管选什么背景，最后都是同一片朦胧的雾，
    // 黑底粉兔子那张里兔子完全看不见了。
    //
    // 背景图存在的意义就是要看见它。模糊必须只发生在卡片背后。
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Container(
        decoration: decoration,
        // 用 Stack 而不是 Column：导航条要**真的浮在内容上面**，
        // 内容从它底下滚过去。
        //
        // 原来是 Column，内容被顶在导航条上方——那句「内容真的从它底下滚过去」
        // 的注释一直是假的。玻璃糊的其实是自己的底色，不是滚动的内容。
        //
        // 代价：每个 tab 的滚动列表底部要自己留出导航条那么高的空（约 96），
        // 否则最后一条会被压在下面看不见。书架那份早就留了，
        // 主页和栖息是这次补的。
        child: Stack(
          children: [
            Positioned.fill(
              child: IndexedStack(
                index: _index,
                children: [
                  ChatScreen(
                    onSwitchTab: _switchTo,
                    onBackgroundChanged: _loadBackground,
                    onChatModeChanged: _onChatModeChanged,
                  ),
                  const BookshelfScreen(),
                  HabitatScreen(onSwitchTab: _switchTo),
                ],
              ),
            ),
            // 键盘弹起时收掉：留着会浮在键盘上方挡住输入区。
            if (!_hideNav && MediaQuery.of(context).viewInsets.bottom == 0)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _buildFloatingNav(scheme),
              ),
          ],
        ),
      ),
    );
  }

  /// 背景图只认 [BackgroundProvider] 那一份。
  ///
  /// 原来这里读的是本 State 的 `_backgroundImagePath`，于是同一个状态存了两份：
  /// 一份在这儿负责画，一份在 provider 里负责算前景色。设置页改完背景只更新了
  /// 存储，两份都不知道——图不显示、玻璃也判定「没有背景图」，看起来就是
  /// 「设了背景毫无反应」，重启才好。
  ///
  /// 收口成一份之后，谁改的背景都不重要，provider 一 notify 这里就重画。
  BoxDecoration _buildBackgroundDecoration(ColorScheme scheme) {
    final path = context.watch<BackgroundProvider>().path;
    if (path != null) {
      return BoxDecoration(
        image: DecorationImage(image: FileImage(File(path)), fit: BoxFit.cover),
      );
    }
    // 这两档是「不管主题是深是浅，我就要这个底色」的显式选择，
    // 所以直接取设计 token，不跟 scheme 翻转。
    //
    // ⚠️ 别在这里写死颜色：这层是整屏铺在主题上面的，
    // 写死等于把 ColorScheme.surface 盖掉（之前的 #F3F1EC 就是这么
    // 让奶白底一直没显示出来的）。
    // 没设自定义图片就用主题底色。
    //
    // ⚠️ 这里必须真的画出来：外层 Scaffold 是 backgroundColor: transparent
    // （为了让自定义背景图铺满），返回 null 等于没人上色，露出来的是
    // MaterialApp 底下的纯黑——深色模式的暖黑 #171310 就白设了。
    //
    // 原来还有 dark / light 两档写死的底色，和「深色模式」开关打架：
    // 它只铺在这一层，信 / 日记 / 一隅是独立路由铺不到，选了深色背景
    // 就变成「主页是黑的、内页是白的」。明暗现在统一归主题管。
    return BoxDecoration(color: scheme.surface);
  }

  Widget _buildFloatingNav(ColorScheme scheme) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        // 导航条是玻璃最名副其实的地方：内容真的从它底下滚过去，
        // 糊的是活的东西，不是一块纯色。AppSurface 会自己判断——
        // 玻璃关着或者没贴背景图就退回原来的实心 + 阴影。
        child: SizedBox(
          height: 50,
          child: AppSurface(
            borderRadius: AppRadius.pillAll,
            floating: true,
            child: Row(
              children: [
                // 三个元素长宽比不同，高度按视觉重量对齐，不要都设成同一个数。
                _navItem(0, 'cat', 17, '主页', scheme),
                _navItem(1, 'books', 16, '书架', scheme),
                _navItem(2, 'mountain', 13, '栖息', scheme),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 选中态的淡底。跟 chat_screen 里置顶卡片是同一套逻辑：
  /// 有背景图就借它的色相，没有就用主题的 primaryContainer。
  Color _selectedTint(BuildContext context, ColorScheme scheme) {
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
        onTap: () => _selectIndex(index),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          margin: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            // 选中底用淡底，不用实色主色——实色太重，会跟页面顶部的棕色元素抢。
            //
            // 贴了背景图时色相跟着图走：粉色壁纸上留一块棕色胶囊，是整屏
            // 唯一跑调的东西。没有背景图就回落到 primaryContainer（徽标棕）。
            color:
                selected ? _selectedTint(context, scheme) : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.pill),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Image.asset(
                'assets/icons/$asset.png',
                height: iconHeight,
                // 白色母版按 alpha 整张染色，深浅/选中全交给主题
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
