import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
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
  String _backgroundPreset = 'none';

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
        _backgroundPreset = preset;
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

  BoxDecoration? _buildBackgroundDecoration(ColorScheme scheme) {
    if (_backgroundImagePath != null) {
      return BoxDecoration(
        image: DecorationImage(
          image: FileImage(File(_backgroundImagePath!)),
          fit: BoxFit.cover,
        ),
      );
    }
    switch (_backgroundPreset) {
      case 'dark':
        return const BoxDecoration(color: Color(0xFF121212));
      case 'light':
        // 原来是 #F6F3EA：蓝通道比红低 12，满屏铺开明显发黄，且亮度偏高会刺眼。
        // 收窄到差 8、整体压暗两档——仍是暖调，但不再抢眼。
        return const BoxDecoration(color: Color(0xFFEFEDE7));
      default:
        return null;
    }
  }

  Widget _buildFloatingNav(ColorScheme scheme) {
    final isDark = scheme.brightness == Brightness.dark;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
        child: Container(
          height: 58,
          decoration: BoxDecoration(
            color:
                isDark
                    ? Colors.black.withValues(alpha: 0.72)
                    : Colors.white.withValues(alpha: 0.86),
            borderRadius: BorderRadius.circular(AppRadius.pill),
            border: Border.all(
              color:
                  isDark
                      ? Colors.white.withValues(alpha: 0.10)
                      : Colors.black.withValues(alpha: 0.08),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.10),
                blurRadius: 18,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            children: [
              _navItem(
                0,
                PhosphorIconsRegular.house,
                PhosphorIconsRegular.house,
                '主页',
                scheme,
              ),
              _navItem(
                1,
                PhosphorIconsRegular.bookOpen,
                PhosphorIconsRegular.bookOpen,
                '书架',
                scheme,
              ),
              _navItem(
                2,
                PhosphorIconsRegular.tree,
                PhosphorIconsRegular.tree,
                '栖息',
                scheme,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _navItem(
    int index,
    IconData icon,
    IconData selectedIcon,
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
            color: selected ? scheme.inverseSurface : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.pill),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                selected ? selectedIcon : icon,
                size: 20,
                color:
                    selected
                        ? scheme.onInverseSurface
                        : scheme.onSurfaceVariant,
              ),
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color:
                      selected
                          ? scheme.onInverseSurface
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
