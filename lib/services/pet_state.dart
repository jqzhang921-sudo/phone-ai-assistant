import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 浮在 App 里的那只 Mochi。
///
/// 2026-09-20 Cleo 问「悬浮窗小猫可以只在 app 里面出现吗」——可以，而且这样做
/// 反而简单得多：**只在 Nook 自己的界面上浮着，就不是悬浮窗**。悬浮窗指的是浮在
/// 别的 App 上面，那才要 SYSTEM_ALERT_WINDOW 权限、被 ColorOS 管、耗电、挡东西。
/// 浮在自己界面上只是一层普通的界面元素，这三个缺点全都不存在。
///
/// 这里只放**能单独测的那一半**：它现在是什么状态、待机时该摆什么姿势、
/// 拖到屏幕外面怎么拉回来。画它的部分在 `widgets/mochi_pet.dart`。
enum PetMood {
  /// 没事，待着。
  idle,

  /// 它在写回复。
  typing,

  /// 它在看一眼她的屏幕。
  glancing,
}

class PetState {
  /// 当前状态。改它的地方只有 [Capsule.whileReplying] / [whileGlancing]——
  /// 那两段本来就把「正在做这件事」括起来了，小猫搭同一班车，
  /// 不另拉一套开始/结束，省得其中一条忘了收。
  static final mood = ValueNotifier<PetMood>(PetMood.idle);

  /// 现在露没露着。设置里一拨就变，不用等下次启动——所以是可监听的值，
  /// 不只是存进偏好设置。
  static final visibleNow = ValueNotifier<bool>(false);

  /// App 起来时读一次。
  static Future<void> load() async {
    visibleNow.value = await visible();
  }

  static const _kVisible = 'pet_visible';
  static const _kDx = 'pet_dx';
  static const _kDy = 'pet_dy';

  /// 默认**不出现**。
  ///
  /// 这是个会一直挡在屏幕上的东西，不该未经她同意就出现在她每一页上——
  /// 「看一眼屏幕」那条提示的教训就是这个（见 main.dart 里删掉的那段）。
  /// 她在设置里打开它，才开始浮着。
  static Future<bool> visible() async {
    try {
      final sp = await SharedPreferences.getInstance();
      return sp.getBool(_kVisible) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> setVisible(bool v) async {
    visibleNow.value = v;
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_kVisible, v);
  }

  /// 她把它拖到哪儿了。存的是**左上角的逻辑坐标**。
  static Future<Offset?> savedSpot() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final dx = sp.getDouble(_kDx);
      final dy = sp.getDouble(_kDy);
      if (dx == null || dy == null) return null;
      return Offset(dx, dy);
    } catch (_) {
      return null;
    }
  }

  static Future<void> saveSpot(Offset at) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setDouble(_kDx, at.dx);
    await sp.setDouble(_kDy, at.dy);
  }
}

/// 待机时摆什么姿势。纯函数。
///
/// 跟着真实时间走，和开屏那盏灯是同一个主意：这个 App 每条消息都带着时间，
/// 它知道现在几点，是说得通的。
///
/// 用的都是现成的表情图（见 [Sticker]），不另画。
String idleStickerFor(DateTime now) {
  final h = now.hour;
  if (h >= 23 || h < 6) return 'nap'; // 深夜：蜷在垫子上
  if (h < 9) return 'stretch'; // 清早：伸懒腰
  if (h >= 19) return 'lying'; // 晚上：趴着
  return 'sit_up'; // 白天：端正坐着
}

/// 当前状态该画哪张。
String stickerForMood(PetMood mood, DateTime now) => switch (mood) {
  PetMood.typing => 'typing',
  // ⚠️ 这张是「仰头看别处」，借来表示「它正在看你的屏幕」。
  // 没有一张是专门画偷看的；她要是觉得不像，换一个 key 就行。
  PetMood.glancing => 'butterfly',
  PetMood.idle => idleStickerFor(now),
};

/// 点它一下的反应。按顺序轮，不随机——随机会出现连着三次同一张，
/// 看着像坏了。
const petTapReactions = <String>[
  'smile',
  'wave',
  // 2026-09-21 Cleo 挑的那张：冒星星和爱心、最夸张开心的一张。
  // 它在 assets/pet/ 里（小猫专用），不进表情面板——她要的是「点一下的反应」，
  // 而且它和三十六格表的比例不是一路的。
  'happy',
  'shy',
  'startled',
  'sparkle',
  'snack',
];

String petTapReaction(int tapCount) =>
    petTapReactions[tapCount % petTapReactions.length];

/// 拖完之后把它拉回屏幕里。
///
/// 允许露出去一点点（[bleed]），贴边时看着像趴在屏幕边上；但不能整只消失，
/// 否则她再也点不到它。
Offset clampSpot(
  Offset want,
  Size pet,
  Size screen, {
  EdgeInsets safe = EdgeInsets.zero,
  double bleed = 16,
}) {
  final minX = safe.left - bleed;
  final maxX = screen.width - safe.right - pet.width + bleed;
  final minY = safe.top;
  final maxY = screen.height - safe.bottom - pet.height;
  return Offset(
    want.dx.clamp(minX, maxX < minX ? minX : maxX),
    want.dy.clamp(minY, maxY < minY ? minY : maxY),
  );
}


/// 小猫专用的那套图。
///
/// 2026-09-21 Cleo 让 GPT 画了一对**同一张画**的睁眼 / 闭眼（`assets/pet/`）。
/// 和表情包分开放：那套是从三十六格表里切的，比例不一样，混在一起会格格不入；
/// 她历史消息里的 sit_up 也不该被悄悄换掉。
///
/// 约定：`assets/pet/mochi_<key>.png`，闭眼是 `..._blink.png`。
/// **有闭眼帧的姿势才眨**——拿别的姿势顶替看起来是猫跳了一下，比不眨还糟。
/// 她以后补一对，就多一个姿势会眨，不用改代码。
class PetArt {
  static Set<String> _base = {};
  static Set<String> _blink = {};

  static const _dir = 'assets/pet/mochi_';
  static const _png = '.png';
  static const _blinkSuffix = '_blink.png';

  /// App 起来时扫一遍打包进去的资源。失败就当作没有这套图（退回表情包，不报错）。
  static Future<void> load() async {
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      final base = <String>{};
      final blink = <String>{};
      for (final a in manifest.listAssets()) {
        if (!a.startsWith(_dir)) continue;
        if (a.endsWith(_blinkSuffix)) {
          blink.add(a.substring(_dir.length, a.length - _blinkSuffix.length));
        } else if (a.endsWith(_png)) {
          base.add(a.substring(_dir.length, a.length - _png.length));
        }
      }
      _base = base;
      _blink = blink;
    } catch (_) {
      _base = {};
      _blink = {};
    }
  }

  /// 这个姿势有没有小猫专用图；没有就返回 null，调用方退回表情包那张。
  static String? baseAsset(String key) =>
      _base.contains(key) ? '$_dir$key$_png' : null;

  static String? blinkAsset(String key) =>
      _blink.contains(key) ? '$_dir$key$_blinkSuffix' : null;

  static bool canBlink(String key) => _blink.contains(key);

  @visibleForTesting
  static void setForTest({Set<String> base = const {}, Set<String> blink = const {}}) {
    _base = base;
    _blink = blink;
  }
}

/// 两次眨眼之间隔多久。
///
/// 真猫不是节拍器：固定 4 秒眨一下，看久了像秒针。所以按次数在 3~7 秒之间绕，
/// 但**不用随机数**——随机会出现连着两次间隔极短，那看着像抽搐。
Duration blinkGap(int n) => Duration(milliseconds: 3000 + (n * 1300) % 4000);

/// 闭着眼那一下有多长。真猫眨眼约 100~150 毫秒。
const blinkHold = Duration(milliseconds: 130);
