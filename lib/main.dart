import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'config/api_keys.dart';
import 'config/settings.dart';
import 'config/app_theme.dart';
import 'screens/home_shell.dart';
import 'services/ai_client.dart';
import 'services/app_providers.dart';
import 'services/storage_service.dart';
import 'services/external_mcp_service.dart';
import 'services/tts_service.dart';

/// 让没有 context 的工具也能弹框问用户。
///
/// 注意：MCP server 也会从电脑那边调同一批工具，那时人不在手机前面，
/// 弹框不会有人点——所以调用方必须给超时，超时按「拒绝」处理。
final appNavigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 绘制到屏幕边缘，并让系统状态栏/导航栏透明。
  //
  // 不开这个的话，底部手势条那一条由系统用不透明色填充，背景图会被截断在
  // 它上面——于是「悬浮」的导航胶囊其实是坐在一块灰底板上，一换背景就露馅。
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
    ),
  );

  await StorageService.init();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AiClientProvider()),
        ChangeNotifierProvider(
          create: (_) => McpServerProvider()..markInitialized(),
        ),
        ChangeNotifierProvider(create: (_) => ExternalMcpProvider()),
        ChangeNotifierProvider(create: (_) => TtsService()),
        ChangeNotifierProvider(create: (_) => BackgroundProvider()),
        ChangeNotifierProvider(create: (_) => SettingsProvider()),
        ChangeNotifierProvider(create: (_) => FavoritesProvider()..load()),
      ],
      child: const PhoneAiApp(),
    ),
  );
}

class PhoneAiApp extends StatefulWidget {
  const PhoneAiApp({super.key});

  @override
  State<PhoneAiApp> createState() => _PhoneAiAppState();
}

class _PhoneAiAppState extends State<PhoneAiApp> {
  late Future<AppSettings> _settingsFuture;

  @override
  void initState() {
    super.initState();
    _settingsFuture = AppSettings.load();
    _loadSavedApiKeys();
    _connectExternalMcpServers();
    _autoStartMcpServer();
  }

  Future<void> _autoStartMcpServer() async {
    final settings = await _settingsFuture;
    if (!settings.serverEnabled || !mounted) return;
    final provider = context.read<McpServerProvider>();
    await provider.server.start(settings.webSocketPort);
    provider.markInitialized(); // notify UI
  }

  Future<void> _loadSavedApiKeys() async {
    final configs = await ApiKeyService.loadKeys();
    for (final config in configs) {
      if (config.apiKey != null && config.apiKey!.isNotEmpty) {
        if (mounted) {
          context.read<AiClientProvider>().setClient(AiClient(config: config));
          break;
        }
      }
    }
  }

  Future<void> _connectExternalMcpServers() async {
    final servers = await ExternalMcpServerService.load();
    for (final server in servers.where((s) => s.enabled)) {
      if (mounted) {
        await context.read<ExternalMcpProvider>().connectTo(server);
      }
    }
  }

  /// 这一轮该用什么色调建主题。
  ///
  /// 两个色源，**背景图优先**：
  ///
  /// - 贴了背景图 + 开着毛玻璃 → 配色由图决定（设计交付里的互斥规矩）。
  ///   判断条件和 `AppSurface` 画不画玻璃那几条对齐——玻璃关着却把整套配色
  ///   旋到粉色，那是第三种状态，谁也没要过。
  /// - 否则 → 用预设主题（默认 [AppThemeId.brown] = 原来那套棕，
  ///   一个像素都不变）。
  AppTone _toneFor(AppSettings s, BackgroundProvider bg) {
    if (s.glassSurface && bg.path != null) {
      // 图是黑白的（解不出色相）——退回棕色同样出戏，改用中性色调。
      final accent = bg.backgroundAccent;
      return accent == null ? AppTone.neutral : AppTone.towards(accent);
    }
    return s.themeId.tone;
  }

  /// 这一轮该用深色还是浅色。
  ///
  /// 玻璃主题下**深浅跟着背景图走，不听 ThemeMode**。
  ///
  /// 不这么做会撕开成两半：`AppSurface` 按背景图决定玻璃是白的还是黑的，
  /// 卡片里的字却按 ThemeMode 取 `scheme.onSurface`。贴一张黑底壁纸就是
  /// 深色玻璃压深色字——栖息页那个「588」大数字整个消失，实测过。
  ///
  /// 页面大标题之所以没事，是因为四个页面各自写了
  /// `bg.darkForeground ?? theme.brightness` 这么一句手接。那正说明问题：
  /// 手接只接得住写过的地方，接不住卡片里成百上千处 `scheme.onSurface`。
  /// 深浅是主题这一层的事，就该在主题这一层定。
  ///
  /// 关掉玻璃开关，ThemeMode 立刻全权说了算。
  ThemeMode _modeFor(AppSettings s, BackgroundProvider bg) {
    if (!s.glassSurface || bg.path == null) return s.themeMode;
    final darkForeground = bg.darkForeground;
    if (darkForeground == null) return s.themeMode;
    // darkForeground = 字要用深色 = 背景偏亮 = 浅色主题
    return darkForeground ? ThemeMode.light : ThemeMode.dark;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AppSettings>(
      future: _settingsFuture,
      builder: (context, snapshot) {
        final settings = snapshot.data ?? AppSettings();
        context.read<SettingsProvider>().setSettings(settings);

        // 背景图也要参与建主题：玻璃主题下整套配色跟着背景色相走。
        return Consumer2<SettingsProvider, BackgroundProvider>(
          builder: (context, sp, bg, _) {
            final s = sp.settings ?? settings;
            final titleSerif = s.titleSerif;
            final tone = _toneFor(s, bg);
            return MaterialApp(
              title: '手机 AI 助手',
              // 工具是不带 context 的静态函数，但有些工具需要当场问用户
              // （比如读日历）。给它们一个能挂弹框的地方。
              navigatorKey: appNavigatorKey,
              debugShowCheckedModeBanner: false,
              theme: AppTheme.lightWith(titleSerif: titleSerif, tone: tone),
              darkTheme: AppTheme.darkWith(titleSerif: titleSerif, tone: tone),
              themeMode: _modeFor(s, bg),
              home: const HomeShell(),
            );
          },
        );
      },
    );
  }
}
