import 'dart:io';
import 'package:flutter/material.dart';
import '../config/app_tab.dart';
import '../services/storage_service.dart';
import 'chat_screen.dart';
import 'bookshelf_screen.dart';
import 'tools_screen.dart';
import 'settings_screen.dart';

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
    final path = await StorageService.getBackgroundImagePath();
    if (mounted) setState(() => _backgroundImagePath = path);
  }

  void _switchTo(AppTab tab) {
    if (mounted && tab.index != _index) {
      setState(() => _index = tab.index);
    }
  }

  void _onChatModeChanged(bool inChat) {
    if (mounted && inChat != _hideNav) {
      setState(() => _hideNav = inChat);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Container(
        decoration:
            _index == 0 && _backgroundImagePath != null
                ? BoxDecoration(
                  image: DecorationImage(
                    image: FileImage(File(_backgroundImagePath!)),
                    fit: BoxFit.cover,
                  ),
                )
                : null,
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
                  const ToolsScreen(),
                  const SettingsScreen(),
                ],
              ),
            ),
            if (!_hideNav) _buildFloatingNav(scheme),
          ],
        ),
      ),
    );
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
            borderRadius: BorderRadius.circular(29),
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
                Icons.home_outlined,
                Icons.home_rounded,
                '主页',
                scheme,
              ),
              _navItem(
                1,
                Icons.menu_book_outlined,
                Icons.menu_book_rounded,
                '书架',
                scheme,
              ),
              _navItem(
                2,
                Icons.build_outlined,
                Icons.build_rounded,
                '工具',
                scheme,
              ),
              _navItem(
                3,
                Icons.settings_outlined,
                Icons.settings_rounded,
                '设置',
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
        borderRadius: BorderRadius.circular(22),
        onTap: () => setState(() => _index = index),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          margin: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            color: selected ? scheme.inverseSurface : Colors.transparent,
            borderRadius: BorderRadius.circular(22),
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
