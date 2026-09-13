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

  // ⚠️ 设置必须在 runApp **之前**读出来，用来给 SettingsProvider 开局定调。
  //
  // 原来是在 widget 树的 FutureBuilder 里异步读的，读出来之前先铺一块
  // **写死的浅米色**兜底——于是深色模式下冷启动是「先浅一下、再翻深」，
  // 那块米色就是闪的那一下。主 App 早就改成预读了（main.dart 里同一段），
  // 这边一直漏着。
  //
  // 代价是启动多等一次 SharedPreferences（毫秒级），换**第一帧就是对的**。
  // 读失败也不能让 App 起不来，所以整段包在 try 里。
  AppSettings? bootSettings;
  try {
    bootSettings = await AppSettings.load();
  } catch (e) {
    debugPrint('[reading] 预读设置失败，第一帧按系统深浅走：$e');
  }

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
        ChangeNotifierProvider(
          create: (_) {
            final p = SettingsProvider();
            // 开局就带上预读的值。create 是懒的（第一次被 watch 时才跑），
            // 所以注入发生在第一帧 build 的过程中——那一帧 `settings != null`，
            // 深色/浅色不用等异步读盘，也就没有「先浅一下再翻深」。
            if (bootSettings != null) p.setSettings(bootSettings);
            return p;
          },
        ),
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
      // 和设置页选中的、跟主 App 建客户端时用的是同一个函数，别各挑各的。
      final config = await ApiKeyService.pickActive(configs);
      if (config == null || !mounted) return;
      context.read<AiClientProvider>().setClient(AiClient(config: config));
    } catch (e) {
      debugPrint('[reading] 恢复 API 配置失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    // 设置已经在 main() 里预读、并塞进 SettingsProvider 了，**所以第一帧就是对的**。
    //
    // 原来这里是个 FutureBuilder：读盘期间先铺一块**写死的浅米色**兜底。
    // 深色模式下冷启动就成了「先浅一下、再翻深」——闪的就是那块米色。
    // 主 App 早就改成 runApp 之前预读了（main.dart 里同一段），这边一直漏着。
    //
    // 兜底取默认值（`themeMode` 是 system，跟系统走）而不是写死浅色：
    // 只有预读也失败（见 main 里的 try）才会用到它，那时跟着系统是最不坏的猜法。
    final s = context.watch<SettingsProvider>().settings ?? AppSettings();

    return MaterialApp(
      title: '读书讨论',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightWith(titleSerif: s.titleSerif),
      darkTheme: AppTheme.darkWith(titleSerif: s.titleSerif),
      // 少了这一行，两套主题都建好了却没人用——永远跟着系统走，
      // 设置页里选什么都白选。
      themeMode: s.themeMode,
      home: const ReadingShell(),
    );
  }
}
