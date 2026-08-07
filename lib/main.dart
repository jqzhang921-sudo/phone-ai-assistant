import 'package:flutter/material.dart';
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

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
    if (!settings.serverEnabled) return;
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

        return MaterialApp(
          title: '手机 AI 助手',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          themeMode: settings.themeMode,
          home: const HomeShell(),
        );
      },
    );
  }
}
