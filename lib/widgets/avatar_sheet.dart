import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../services/avatar_store.dart';

/// 换头像的底部菜单：从相册选一张 / 换回上一张 / 恢复默认。
///
/// 它的头像（按对话记，[key] 是对话 id）和你自己的头像
/// （[AvatarStore.userKey]，全局一张）用的是同一个菜单。
Future<void> showAvatarSheet(BuildContext context, String key) async {
  final store = AvatarStore.instance;
  await store.load(key);
  if (!context.mounted) return;
  final custom = store.hasCustom(key);

  final choice = await showModalBottomSheet<String>(
    context: context,
    builder:
        (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(PhosphorIconsRegular.image),
                title: const Text('从相册选一张'),
                onTap: () => Navigator.pop(ctx, 'pick'),
              ),
              ListTile(
                leading: const Icon(PhosphorIconsRegular.arrowCounterClockwise),
                title: const Text('换回上一张'),
                enabled: custom,
                onTap: () => Navigator.pop(ctx, 'revert'),
              ),
              ListTile(
                leading: const Icon(PhosphorIconsRegular.arrowsClockwise),
                title: const Text('恢复默认'),
                enabled: custom,
                onTap: () => Navigator.pop(ctx, 'reset'),
              ),
            ],
          ),
        ),
  );

  switch (choice) {
    case 'pick':
      final shot = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1024,
        maxHeight: 1024,
      );
      if (shot == null) return;
      await store.setFromBytes(key, await shot.readAsBytes());
    case 'revert':
      await store.revert(key);
    case 'reset':
      await store.reset(key);
  }
}
