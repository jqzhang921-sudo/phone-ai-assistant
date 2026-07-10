import 'dart:convert';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import '../models/conversation.dart';

class StorageService {
  static late Directory _dir;

  static Future<void> init() async {
    _dir = await getApplicationDocumentsDirectory();
  }

  static String get _convDir => '${_dir.path}/conversations';

  static Future<void> saveConversation(Conversation conv) async {
    final dir = Directory(_convDir);
    if (!await dir.exists()) await dir.create(recursive: true);
    final file = File('$_convDir/${conv.id}.json');
    await file.writeAsString(jsonEncode(conv.toJson()));
  }

  static Future<Conversation?> loadConversation(String id) async {
    try {
      final file = File('$_convDir/$id.json');
      if (!await file.exists()) return null;
      final data = await file.readAsString();
      return Conversation.fromJson(jsonDecode(data));
    } catch (_) {
      return null;
    }
  }

  static Future<List<Conversation>> listConversations() async {
    final dir = Directory(_convDir);
    if (!await dir.exists()) return [];
    final files = await dir.list().toList();
    files.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    final convs = <Conversation>[];
    for (final file in files) {
      if (file.path.endsWith('.json')) {
        final conv = await loadConversation(
            file.uri.pathSegments.last.replaceAll('.json', ''));
        if (conv != null) convs.add(conv);
      }
    }
    return convs;
  }

  static Future<void> deleteConversation(String id) async {
    final file = File('$_convDir/$id.json');
    if (await file.exists()) await file.delete();
  }
}
