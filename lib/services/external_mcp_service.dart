import 'package:shared_preferences/shared_preferences.dart';

class ExternalMcpServer {
  final String id;
  String name;
  String url;
  bool enabled;

  ExternalMcpServer({
    required this.id,
    required this.name,
    required this.url,
    this.enabled = true,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'enabled': enabled,
      };

  factory ExternalMcpServer.fromJson(Map<String, dynamic> json) =>
      ExternalMcpServer(
        id: json['id'],
        name: json['name'] ?? 'MCP Server',
        url: json['url'],
        enabled: json['enabled'] ?? true,
      );
}

class ExternalMcpServerService {
  static const _key = 'external_mcp_servers';

  static Future<List<ExternalMcpServer>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getString(_key);
    if (data == null) return [];
    try {
      final list = (data.split('||').map((s) {
            try {
              final parts = s.split('|');
              return ExternalMcpServer(
                id: parts[0],
                name: parts[1],
                url: parts[2],
                enabled: parts.length > 3 ? parts[3] == '1' : true,
              );
            } catch (_) {
              return null;
            }
          }).whereType<ExternalMcpServer>().toList());
      return list;
    } catch (_) {
      return [];
    }
  }

  static Future<void> save(List<ExternalMcpServer> servers) async {
    final prefs = await SharedPreferences.getInstance();
    final data = servers
        .map((s) =>
            '${s.id}|${s.name}|${s.url}|${s.enabled ? '1' : '0'}')
        .join('||');
    await prefs.setString(_key, data);
  }

  static Future<void> add(ExternalMcpServer server) async {
    final servers = await load();
    servers.add(server);
    await save(servers);
  }

  static Future<void> remove(String id) async {
    final servers = await load();
    servers.removeWhere((s) => s.id == id);
    await save(servers);
  }

  static Future<void> update(ExternalMcpServer server) async {
    final servers = await load();
    final idx = servers.indexWhere((s) => s.id == server.id);
    if (idx >= 0) {
      servers[idx] = server;
      await save(servers);
    }
  }
}
