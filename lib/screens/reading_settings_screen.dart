import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../config/api_keys.dart';
import '../config/app_shape.dart';
import '../services/ai_client.dart';
import '../services/app_providers.dart';
import '../widgets/app_surface.dart';

/// 读书版的设置：只有模型配置，别的一概没有。
///
/// ## 为什么不复用主 App 的设置页
///
/// 那一页 2200 多行，里面是主题、背景图、人设、主动说话、MCP 服务器、
/// 语音、备份⋯⋯读书版一个都用不上。整页搬过来，等于把用不着的功能全摆在
/// 他面前，还得挨个解释「这个你别管」。
///
/// 这一页只干一件事：**让他能填上 key 把 app 跑起来**。
class ReadingSettingsScreen extends StatefulWidget {
  const ReadingSettingsScreen({super.key});

  @override
  State<ReadingSettingsScreen> createState() => _ReadingSettingsScreenState();
}

class _ReadingSettingsScreenState extends State<ReadingSettingsScreen> {
  final _keyController = TextEditingController();
  final _endpointController = TextEditingController();
  final _modelController = TextEditingController();

  List<ApiKeyConfig> _configs = const [];
  String? _provider;
  bool _loading = true;
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _keyController.dispose();
    _endpointController.dispose();
    _modelController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final configs = await ApiKeyService.loadKeys();
    if (!mounted) return;
    setState(() {
      _configs = configs;
      _loading = false;
    });
    // 已经填过 key 的优先选中，省得他每次进来都要找自己那一项。
    final filled = configs.firstWhere(
      (c) => (c.apiKey ?? '').isNotEmpty,
      orElse: () => configs.first,
    );
    _select(filled);
  }

  void _select(ApiKeyConfig c) {
    setState(() {
      _provider = c.provider;
      _keyController.text = c.apiKey ?? '';
      _endpointController.text = c.endpoint ?? '';
      _modelController.text = c.model ?? '';
    });
  }

  Future<void> _save() async {
    final provider = _provider;
    if (provider == null) return;
    final config = ApiKeyConfig(
      provider: provider,
      name: _configs.firstWhere((c) => c.provider == provider).name,
      apiKey: _keyController.text.trim(),
      endpoint: _endpointController.text.trim(),
      model: _modelController.text.trim(),
    );
    await ApiKeyService.saveKey(config);

    if (!mounted) return;
    // 存完立刻把客户端换掉，否则要退出重进才生效——他会以为没保存上。
    if (config.apiKey!.isNotEmpty) {
      context.read<AiClientProvider>().setClient(AiClient(config: config));
    }
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已保存'), duration: Duration(seconds: 1)),
    );
  }

  Future<void> _paste(TextEditingController c) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) return;
    setState(() => c.text = text);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('模型设置')),
      body:
          _loading
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                children: [
                  Text(
                    '选一个服务商，填上你自己的 API Key。'
                    'Key 存在这台手机上，不会发到别处。',
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.6,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final c in _configs)
                        ChoiceChip(
                          label: Text(c.name),
                          selected: _provider == c.provider,
                          onSelected: (_) => _select(c),
                        ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  _field(
                    label: 'API Key',
                    controller: _keyController,
                    obscure: _obscure,
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: _obscure ? '显示' : '隐藏',
                          icon: Icon(
                            _obscure
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined,
                            size: 20,
                          ),
                          onPressed: () => setState(() => _obscure = !_obscure),
                        ),
                        IconButton(
                          tooltip: '粘贴',
                          icon: const Icon(Icons.content_paste, size: 18),
                          onPressed: () => _paste(_keyController),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  _field(
                    label: 'API 地址（留空用默认）',
                    controller: _endpointController,
                    hint: 'https://api.deepseek.com/v1',
                  ),
                  const SizedBox(height: 12),
                  _field(
                    label: '模型（留空用默认）',
                    controller: _modelController,
                    hint: 'deepseek-chat',
                  ),
                  const SizedBox(height: 24),
                  FilledButton(onPressed: _save, child: const Text('保存')),
                  const SizedBox(height: 24),
                  AppSurface(
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        '不知道填什么的话：\n\n'
                        '选「自定义」，地址填 https://api.deepseek.com/v1，'
                        '模型填 deepseek-chat，'
                        'Key 去 platform.deepseek.com 注册后自己生成一个。\n\n'
                        '国内直连，不用梯子。',
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.7,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
    );
  }

  Widget _field({
    required String label,
    required TextEditingController controller,
    String? hint,
    bool obscure = false,
    Widget? trailing,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        border: const OutlineInputBorder(),
        suffixIcon: trailing,
      ),
    );
  }
}
