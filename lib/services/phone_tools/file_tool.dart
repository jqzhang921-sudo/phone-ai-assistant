import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import '../../models/mcp_tool.dart';

class FileTool {
  static McpTool get definition => McpTool(
        name: 'pick_file',
        description: '从手机存储中选择一个文件',
        inputSchema: {
          'type': 'object',
          'properties': {
            'type': {
              'type': 'string',
              'enum': ['any', 'image', 'video', 'audio', 'document'],
              'description': '文件类型筛选',
            }
          },
        },
        category: '手机工具',
      );

  static Future<Map<String, dynamic>> execute(
      Map<String, dynamic> args) async {
    try {
      final type = args['type'] as String? ?? 'any';
      FileType fileType;
      List<String>? allowedExtensions;

      switch (type) {
        case 'image':
          fileType = FileType.image;
          break;
        case 'video':
          fileType = FileType.video;
          break;
        case 'audio':
          fileType = FileType.audio;
          break;
        case 'document':
          fileType = FileType.custom;
          allowedExtensions = ['pdf', 'doc', 'docx', 'txt', 'md', 'csv'];
          break;
        default:
          fileType = FileType.any;
      }

      final result = await FilePicker.platform.pickFiles(
        type: fileType,
        allowedExtensions: allowedExtensions,
        withData: true,
      );

      if (result == null || result.files.isEmpty) {
        return {'success': false, 'error': '用户取消了选择'};
      }

      final file = result.files.first;
      final bytes = file.bytes;
      if (bytes == null) {
        return {'success': false, 'error': '无法读取文件数据'};
      }

      return {
        'success': true,
        'name': file.name,
        'size': file.size,
        'extension': file.extension,
        'data': base64Encode(bytes),
      };
    } catch (e) {
      return {'success': false, 'error': '选择文件失败: $e'};
    }
  }
}

/// 写入/创建文件工具
class WriteFileTool {
  static late Directory _docDir;

  static Future<void> _ensureDir() async {
    _docDir = await getApplicationDocumentsDirectory();
  }

  static McpTool get definition => McpTool(
        name: 'write_file',
        description: '在手机的 App 私有文档目录下创建或写入文件。path 是文件名如 "test.txt" 或 "notes/日记.txt"。不需要提供完整路径，只需提供相对文件名。可以用来保存笔记、代码、配置文件等',
        inputSchema: {
          'type': 'object',
          'properties': {
            'path': {
              'type': 'string',
              'description': '文件名如 test.txt，或相对路径如 notes/diary.txt',
            },
            'content': {
              'type': 'string',
              'description': '要写入的文件内容（文本）',
            },
            'append': {
              'type': 'boolean',
              'description': '是否追加到文件末尾（false 则覆盖写入）',
            },
          },
          'required': ['path', 'content'],
        },
        category: '文件管理',
      );

  static Future<Map<String, dynamic>> execute(
      Map<String, dynamic> args) async {
    try {
      await _ensureDir();
      final path = args['path'] as String?;
      final content = args['content'] as String?;
      final append = args['append'] as bool? ?? false;

      if (path == null || path.isEmpty) {
        // Auto-generate a filename if not provided
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final generatedName = 'file_$timestamp.txt';
        if (content == null) {
          return {'success': false, 'error': '缺少 content 参数（文件内容）'};
        }
        final file = File('${_docDir.path}/$generatedName');
        await file.parent.create(recursive: true);
        await file.writeAsString(content);
        return {
          'success': true,
          'path': file.path,
          'filename': generatedName,
          'size': await file.length(),
          'note': '未指定文件名，自动生成了 $generatedName',
        };
      }

      // Security: prevent escaping the app directory
      if (path.contains('..')) {
        return {'success': false, 'error': '路径不能包含 ..'};
      }

      final file = File('${_docDir.path}/$path');
      await file.parent.create(recursive: true);
      final writeContent = content ?? '';

      if (append && await file.exists()) {
        await file.writeAsString(writeContent, mode: FileMode.append);
      } else {
        await file.writeAsString(writeContent);
      }

      return {
        'success': true,
        'path': file.path,
        'size': await file.length(),
        'mode': append ? 'append' : 'overwrite',
      };
    } catch (e) {
      return {'success': false, 'error': '写入文件失败: $e'};
    }
  }
}

/// 读取文件工具
class ReadFileTool {
  static late Directory _docDir;

  static Future<void> _ensureDir() async {
    _docDir = await getApplicationDocumentsDirectory();
  }

  static McpTool get definition => McpTool(
        name: 'read_file',
        description: '读取 App 目录下的文件内容',
        inputSchema: {
          'type': 'object',
          'properties': {
            'path': {
              'type': 'string',
              'description': '文件路径（相对于 App 文档目录）',
            },
          },
          'required': ['path'],
        },
        category: '文件管理',
      );

  static Future<Map<String, dynamic>> execute(
      Map<String, dynamic> args) async {
    try {
      await _ensureDir();
      final path = args['path'] as String?;
      if (path == null) return {'success': false, 'error': '缺少 path 参数'};
      if (path.contains('..')) {
        return {'success': false, 'error': '路径不能包含 ..'};
      }

      final file = File('${_docDir.path}/$path');
      if (!await file.exists()) {
        return {'success': false, 'error': '文件不存在: $path'};
      }

      final content = await file.readAsString();
      return {
        'success': true,
        'content': content,
        'size': content.length,
        'path': file.path,
      };
    } catch (e) {
      return {'success': false, 'error': '读取文件失败: $e'};
    }
  }
}

/// 文件列表工具
class ListFilesTool {
  static late Directory _docDir;

  static Future<void> _ensureDir() async {
    _docDir = await getApplicationDocumentsDirectory();
  }

  static McpTool get definition => McpTool(
        name: 'list_files',
        description: '列出 App 目录下的文件和文件夹',
        inputSchema: {
          'type': 'object',
          'properties': {
            'path': {
              'type': 'string',
              'description': '子目录路径（留空列出根目录）',
            },
          },
        },
        category: '文件管理',
      );

  static Future<Map<String, dynamic>> execute(
      Map<String, dynamic> args) async {
    try {
      await _ensureDir();
      final subPath = args['path'] as String? ?? '';
      if (subPath.contains('..')) {
        return {'success': false, 'error': '路径不能包含 ..'};
      }

      final dir = Directory(subPath.isEmpty
          ? _docDir.path
          : '${_docDir.path}/$subPath');

      if (!await dir.exists()) {
        return {'success': false, 'error': '目录不存在: $subPath'};
      }

      final entities = await dir.list().toList();
      final files = <Map<String, dynamic>>[];
      final folders = <String>[];

      for (final e in entities) {
        final stat = await e.stat();
        final name = e.uri.pathSegments.last;
        if (await FileSystemEntity.isDirectory(e.path)) {
          folders.add(name);
        } else {
          files.add({
            'name': name,
            'size': stat.size,
            'modified': stat.modified.toIso8601String(),
          });
        }
      }

      // Sort alphabetically
      folders.sort();
      files.sort((a, b) => a['name'].compareTo(b['name']));

      return {
        'success': true,
        'currentPath': subPath.isEmpty ? '/' : '/$subPath',
        'absolutePath': dir.path,
        'folders': folders,
        'files': files,
      };
    } catch (e) {
      return {'success': false, 'error': '列出文件失败: $e'};
    }
  }
}

class ClipboardTool {
  static McpTool get definition => McpTool(
        name: 'read_clipboard',
        description: '读取手机剪贴板内容',
        inputSchema: {
          'type': 'object',
          'properties': {},
        },
        category: '手机工具',
      );

  static Future<Map<String, dynamic>> execute(
      Map<String, dynamic> args) async {
    return {
      'success': false,
      'error': '剪贴板读取需要通过 Flutter 原生通道实现（开发中）',
    };
  }
}
