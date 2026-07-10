import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/mcp_server.dart';
import '../models/mcp_tool.dart';
import '../services/phone_tools/camera_tool.dart';
import '../services/phone_tools/location_tool.dart';
import '../services/phone_tools/sensors_tool.dart';
import 'chat_screen.dart';

class ToolsScreen extends StatelessWidget {
  const ToolsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final server = context.watch<McpServerProvider>().server;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('MCP 工具'),
        actions: [
          Switch(
            value: server.isRunning,
            onChanged: (v) async {
              final provider = context.read<McpServerProvider>();
              if (v) {
                await server.start(8765);
              } else {
                await server.stop();
              }
              provider.markInitialized();
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Server status card
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        server.isRunning ? Icons.check_circle : Icons.circle_outlined,
                        color: server.isRunning ? Colors.green : Colors.grey,
                        size: 16,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        server.isRunning ? 'MCP Server 运行中' : 'MCP Server 已停止',
                        style: theme.textTheme.titleMedium,
                      ),
                    ],
                  ),
                  if (server.isRunning) ...[
                    const SizedBox(height: 8),
                    Text(
                      '客户端连接数: ${server.clientCount}',
                      style: theme.textTheme.bodySmall,
                    ),
                    Text(
                      '端口: 8765',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Tool list
          Text('已注册工具 (${server.registeredTools.length})',
              style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),

          if (server.registeredTools.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: Text(
                    '启动 MCP Server 后，工具会自动注册',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            )
          else
            ...server.registeredTools.map((rt) => _ToolCard(tool: rt.tool)),

          const SizedBox(height: 24),

          // Test tools section
          Text('测试工具', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          _buildTestButton(
            context,
            icon: Icons.camera_alt,
            label: '拍照测试',
            tool: CameraTool.definition,
            executor: CameraTool.execute,
          ),
          _buildTestButton(
            context,
            icon: Icons.location_on,
            label: '定位测试',
            tool: LocationTool.definition,
            executor: LocationTool.execute,
          ),
          _buildTestButton(
            context,
            icon: Icons.sensors,
            label: '传感器测试',
            tool: SensorTool.definition,
            executor: SensorTool.execute,
          ),
        ],
      ),
    );
  }

  Widget _buildTestButton(BuildContext context,
      {required IconData icon,
      required String label,
      required McpTool tool,
      required ToolExecutor executor}) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(icon),
        title: Text(label),
        trailing: const Icon(Icons.play_arrow),
        onTap: () async {
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (_) => const AlertDialog(
              content: Row(
                children: [
                  CircularProgressIndicator(),
                  SizedBox(width: 16),
                  Text('执行中...'),
                ],
              ),
            ),
          );

          final result = await executor({});
          if (context.mounted) {
            Navigator.of(context).pop();
            _showResult(context, label, result);
          }
        },
      ),
    );
  }

  void _showResult(
      BuildContext context, String label, Map<String, dynamic> result) {
    final success = result['success'] == true;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Row(
          children: [
            Icon(
              success ? Icons.check_circle : Icons.error,
              color: success ? Colors.green : Colors.red,
            ),
            const SizedBox(width: 8),
            Text(success ? '$label 成功' : '$label 失败'),
          ],
        ),
        content: SingleChildScrollView(
          child: Text(result.toString()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
}

class _ToolCard extends StatelessWidget {
  final McpTool tool;

  const _ToolCard({required this.tool});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(tool.category,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onPrimaryContainer,
                      )),
                ),
                const SizedBox(width: 8),
                Text(tool.name,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontFamily: 'monospace',
                    )),
              ],
            ),
            if (tool.description.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(tool.description, style: theme.textTheme.bodySmall),
            ],
          ],
        ),
      ),
    );
  }
}
