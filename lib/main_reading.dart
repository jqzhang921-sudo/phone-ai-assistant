import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'config/api_keys.dart';
import 'config/app_theme.dart';
import 'config/settings.dart';
import 'services/ai_client.dart';
import 'screens/reading_shell.dart';
import 'services/app_providers.dart';
import 'services/storage_service.dart';
import 'services/tts_service.dart';

/// 读书版的入口。
///
/// ## 为什么是第二个 main，而不是第二个仓库
///
/// 两边共用书架、讨论、微信读书导入、AI 客户端、主题、玻璃那一整套。拆仓库
/// 就得同步两份，改一个 bug 要改两遍，迟早跑偏。
///
/// 一个仓库两个入口，构建时用
/// `flutter build apk --release -t lib/main_reading.dart` 挑一个，
/// 产出的是两个独立应用，装在同一台手机上互不干扰（数据也各存各的）。
///
/// ## 这里为什么比主 App 的 main 短这么多
///
/// 主 App 那份要注册后台唤醒、MCP 服务器、TTS、收藏、外部 MCP。读书版一个
/// 都不需要——它只干一件事。**少注册一个 provider，就少一处能出错的地方。**
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

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
      // ⚠️ 这七个一个都不能少。
      //
      // 第一版为了「精简」只留了三个，结果聊天页整块变灰——MessageBubble 会读
      // TtsService，provider 找不到就在 build 里抛异常，而 **release 模式下
      // 抛异常的 widget 渲染成一块纯灰**，不像 debug 那样显示红色报错。
      // 那块灰看着像布局问题，其实是缺依赖。
      //
      // 教训：要精简的是**界面**，不是 provider。少注册一个省不了什么，
      // 但会在真机上炸，而且炸得看不出原因。
      providers: [
        ChangeNotifierProvider(create: (_) => AiClientProvider()),
        ChangeNotifierProvider(create: (_) => BackgroundProvider()),
        ChangeNotifierProvider(create: (_) => SettingsProvider()),
        // 气泡上的朗读按钮
        ChangeNotifierProvider(create: (_) => TtsService()),
        // 气泡上的收藏
        ChangeNotifierProvider(create: (_) => FavoritesProvider()..load()),
        // 聊天页要取工具列表，即便读书版不注册任何工具，容器也得在
        ChangeNotifierProvider(
          create: (_) => McpServerProvider()..markInitialized(),
        ),
        ChangeNotifierProvider(create: (_) => ExternalMcpProvider()),
      ],
      child: const ReadingApp(),
    ),
  );
}

class ReadingApp extends StatefulWidget {
  const ReadingApp({super.key});

  @override
  State<ReadingApp> createState() => _ReadingAppState();
}

class _ReadingAppState extends State<ReadingApp> {
  late final Future<AppSettings> _settings = AppSettings.load();

  @override
  void initState() {
    super.initState();
    _restoreClient();
  }

  /// 启动时把存好的 key 装回去。
  ///
  /// AiClientProvider 只是个容器，自己不会去读存储——主 App 是在设置页保存
  /// 的时候顺手塞进去的。读书版要是不在这儿补一次，就会出现「key 明明填过、
  /// 重启之后又说没配置」，而他只会以为是没存上。
  Future<void> _restoreClient() async {
    try {
      final configs = await ApiKeyService.loadKeys();
      final filled = configs.where((c) => (c.apiKey ?? '').isNotEmpty);
      if (filled.isEmpty || !mounted) return;
      context.read<AiClientProvider>().setClient(
        AiClient(config: filled.first),
      );
    } catch (e) {
      debugPrint('[reading] 恢复 API 配置失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AppSettings>(
      future: _settings,
      builder: (context, snapshot) {
        final settings = snapshot.data;
        if (settings == null) {
          // 主题还没读出来，先给一块底色，别闪白。
          return const ColoredBox(color: Color(0xFFF3F1EC));
        }
        return Consumer<SettingsProvider>(
          builder: (context, sp, _) {
            final s = sp.settings ?? settings;
            return MaterialApp(
              title: '读书讨论',
              debugShowCheckedModeBanner: false,
              theme: AppTheme.lightWith(titleSerif: s.titleSerif),
              darkTheme: AppTheme.darkWith(titleSerif: s.titleSerif),
              home: const ReadingShell(),
            );
          },
        );
      },
    );
  }
}
