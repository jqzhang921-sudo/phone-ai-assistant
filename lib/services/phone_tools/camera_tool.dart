import 'dart:convert';
import 'package:image_picker/image_picker.dart';
import '../../models/mcp_tool.dart';

class CameraTool {
  static final _picker = ImagePicker();

  static McpTool get definition => McpTool(
        name: 'take_photo',
        description: '使用相机拍照，返回图片数据',
        inputSchema: {
          'type': 'object',
          'properties': {},
        },
        category: '手机工具',
      );

  static Future<Map<String, dynamic>> execute(
      Map<String, dynamic> args) async {
    try {
      final XFile? photo = await _picker.pickImage(
        source: ImageSource.camera,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 85,
      );
      if (photo == null) {
        return {'success': false, 'error': '用户取消了拍照'};
      }
      final bytes = await photo.readAsBytes();
      final base64 = base64Encode(bytes);
      return {
        'success': true,
        'data': base64,
        'mimeType': 'image/jpeg',
        'filename': photo.name,
      };
    } catch (e) {
      return {'success': false, 'error': '拍照失败: $e'};
    }
  }
}

class GalleryTool {
  static final _picker = ImagePicker();

  static McpTool get definition => McpTool(
        name: 'pick_image',
        description: '从相册选择一张图片',
        inputSchema: {
          'type': 'object',
          'properties': {},
        },
        category: '手机工具',
      );

  static Future<Map<String, dynamic>> execute(
      Map<String, dynamic> args) async {
    try {
      final XFile? image = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 85,
      );
      if (image == null) {
        return {'success': false, 'error': '用户取消了选择'};
      }
      final bytes = await image.readAsBytes();
      return {
        'success': true,
        'data': base64Encode(bytes),
        'mimeType': 'image/jpeg',
        'filename': image.name,
      };
    } catch (e) {
      return {'success': false, 'error': '选择图片失败: $e'};
    }
  }
}
