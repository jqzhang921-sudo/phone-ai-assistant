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

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AppSettings>(
      future: _settingsFuture,
      builder: (context, snapshot) {
        final settings = snapshot.data ?? AppSettings();
        context.read<SettingsProvider>().setSettings(settings);

        return Consumer<SettingsProvider>(
          builder: (context, sp, _) {
            final s = sp.settings ?? settings;
            final titleSerif = s.titleSerif;
            return MaterialApp(
              title: '手机 AI 助手',
              // 工具是不带 context 的静态函数，但有些工具需要当场问用户
              // （比如读日历）。给它们一个能挂弹框的地方。
              navigatorKey: appNavigatorKey,
              debugShowCheckedModeBanner: false,
              theme: AppTheme.lightWith(titleSerif: titleSerif),
              darkTheme: AppTheme.darkWith(titleSerif: titleSerif),
              themeMode: s.themeMode,
              home: const HomeShell(),
            );
          },
        );
      },
    );
  }
}
