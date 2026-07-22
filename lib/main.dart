import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'config/api_keys.dart';
import 'config/settings.dart';
import 'screens/chat_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/bookshelf_screen.dart';
import 'screens/tools_screen.dart';
import 'services/ai_client.dart';
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
        ChangeNotifierProvider(create: (_) => McpServerProvider()..markInitialized()),
        ChangeNotifierProvider(create: (_) => ExternalMcpProvider()),
        ChangeNotifierProvider(create: (_) => TtsService()),
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
    try {
      final server = context.read<McpServerProvider>().server;
      await server.start(settings.webSocketPort);
    } catch (_) {}
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
          theme: _buildTheme(Brightness.light),
          darkTheme: _buildTheme(Brightness.dark),
          themeMode: settings.themeMode,
          initialRoute: '/',
          routes: {
            '/': (_) => const ChatScreen(),
            '/bookshelf': (_) => const BookshelfScreen(),
            '/settings': (_) => const SettingsScreen(),
            '/tools': (_) => const ToolsScreen(),
          },
        );
      },
    );
  }

  ThemeData _buildTheme(Brightness brightness) {
    final colorScheme = brightness == Brightness.light
        ? ColorScheme.fromSeed(
            seedColor: const Color(0xFF1FA463),
            brightness: Brightness.light,
          )
        : ColorScheme.fromSeed(
            seedColor: const Color(0xFF4CD98A),
            brightness: Brightness.dark,
          );

    return ThemeData(
      colorScheme: colorScheme,
      useMaterial3: true,
      appBarTheme: AppBarTheme(
        centerTitle: true,
        elevation: 0,
        scrolledUnderElevation: 1,
        backgroundColor: colorScheme.surface,
        foregroundColor: colorScheme.onSurface,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: colorScheme.outlineVariant),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    );
  }
}
