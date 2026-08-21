import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import '../config/app_shape.dart';
import '../services/storage_service.dart';

/// 聊天背景选择器：三档预设 + 从相册选图。
///
/// 原来这一整套长在 `chat_screen` 的 State 里，别的页面想给一个入口，
/// 就得把 `_backgroundImagePath` 那些状态一起搬过去。抽出来之后
/// 抽屉和设置页都能直接调，状态一律从 StorageService 读。
///
/// 返回 true 表示背景被改过——调用方自己决定要刷新什么。
Future<bool> showBackgroundSheet(BuildContext context) async {
  final preset = await StorageService.getBackgroundPreset();
  final hasImage = (await StorageService.getBackgroundImagePath()) != null;
  if (!context.mounted) return false;

  final scheme = Theme.of(context).colorScheme;

  Future<void> pickPreset(BuildContext ctx, String p) async {
    await StorageService.setBackgroundImagePath(null);
    await StorageService.setBackgroundPreset(p);
    if (ctx.mounted) Navigator.of(ctx).pop(true);
  }

  final changed = await showModalBottomSheet<bool>(
    context: context,
    builder:
        (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  '聊天背景',
                  style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const Divider(height: 1),
              _option(
                ctx,
                scheme,
                icon: PhosphorIconsRegular.sparkle,
                label: '跟随主题',
                desc: '深浅由「设置 → 深色模式」决定',
                selected: !hasImage && preset == 'none',
                onTap: () => pickPreset(ctx, 'none'),
              ),
              _option(
                ctx,
                scheme,
                icon: PhosphorIconsRegular.imageSquare,
                label: '自定义图片',
                desc: hasImage ? '当前已设置图片' : '从相册选择一张背景图',
                selected: hasImage,
                onTap: () async {
                  final image = await ImagePicker().pickImage(
                    source: ImageSource.gallery,
                  );
                  if (image == null) {
                    if (ctx.mounted) Navigator.of(ctx).pop(false);
                    return;
                  }
                  await StorageService.setBackgroundImagePath(image.path);
                  if (ctx.mounted) Navigator.of(ctx).pop(true);
                },
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
  );
  return changed ?? false;
}

Widget _option(
  BuildContext ctx,
  ColorScheme scheme, {
  required IconData icon,
  required String label,
  required String desc,
  required bool selected,
  required VoidCallback onTap,
}) {
  return ListTile(
    leading: Icon(
      icon,
      color: selected ? scheme.primary : scheme.onSurfaceVariant,
    ),
    title: Text(
      label,
      style: TextStyle(
        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
      ),
    ),
    subtitle: Text(desc, style: const TextStyle(fontSize: 12)),
    trailing:
        selected ? const Icon(PhosphorIconsRegular.check, size: 20) : null,
    onTap: onTap,
  );
}
