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

/// App 一级页面容器：底部导航 + IndexedStack。
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;
  bool _hideNav = false;
  String? _backgroundImagePath;

  @override
  void initState() {
    super.initState();
    _loadBackground();
  }

  Future<void> _loadBackground() async {
    final bgProvider = context.read<BackgroundProvider>();
    final path = await StorageService.getBackgroundImagePath();
    final preset = await StorageService.getBackgroundPreset();
    if (mounted) {
      setState(() {
        _backgroundImagePath = path;
      });
      await bgProvider.update(path, preset);
    }
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
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Container(
        decoration: decoration,
        child: Column(
          children: [
            Expanded(
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
            // 键盘弹起时收掉导航条：它在 Column 里，否则会被顶到键盘正上方，
            // 既挤占了输入区，打字时也用不上。
            if (!_hideNav && MediaQuery.of(context).viewInsets.bottom == 0)
              _buildFloatingNav(scheme),
          ],
        ),
      ),
    );
  }

  BoxDecoration _buildBackgroundDecoration(ColorScheme scheme) {
    if (_backgroundImagePath != null) {
      return BoxDecoration(
        image: DecorationImage(
          image: FileImage(File(_backgroundImagePath!)),
          fit: BoxFit.cover,
        ),
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
    final isDark = scheme.brightness == Brightness.dark;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Container(
          height: 50,
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(AppRadius.pill),
            boxShadow: AppShadow.softenFloating(isDark),
          ),
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
    );
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
            // 选中底用 primaryContainer 淡棕，不用实色主色——
            // 实色太重，会跟页面顶部的棕色元素抢。
            color: selected ? scheme.primaryContainer : Colors.transparent,
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
