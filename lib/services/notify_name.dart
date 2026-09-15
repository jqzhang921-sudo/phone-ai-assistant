import 'package:shared_preferences/shared_preferences.dart';

import '../config/settings.dart';

/// 通知里怎么称呼它。
///
/// 2026-09-16 Cleo：「不是很喜欢用它这个称为，可以换成自己的备注吗，收到信息的时候」。
/// 原来通知标题是设置里「它的名字」，没填就写死「它说」「它回你了」——
/// 像微信给联系人改备注那样，她要能自己定这一行写什么。
///
/// 和「它的名字」分开存：那个会进人设、模型自己也会用；备注只是她这边通知上看的称呼，
/// 改了不该影响它怎么介绍自己。
class NotifyName {
  static const _key = 'notify_display_name';

  static Future<String> remark() async {
    try {
      final sp = await SharedPreferences.getInstance();
      return sp.getString(_key)?.trim() ?? '';
    } catch (_) {
      return '';
    }
  }

  static Future<void> setRemark(String value) async {
    final sp = await SharedPreferences.getInstance();
    final v = value.trim();
    if (v.isEmpty) {
      await sp.remove(_key);
    } else {
      await sp.setString(_key, v);
    }
  }

  /// 通知标题：她填的备注 → 设置里它的名字 → [fallback]。
  static Future<String> resolve(String fallback) async {
    final r = await remark();
    if (r.isNotEmpty) return r;
    try {
      final name = (await AppSettings.load()).aiName.trim();
      if (name.isNotEmpty) return name;
    } catch (_) {}
    return fallback;
  }
}
