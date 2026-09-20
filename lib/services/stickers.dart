/// Mochi 的表情。
///
/// 2026-09-18 Cleo 拿 GPT 画了一张 Mochi 的立绘（黑色德文猫），想让它成为
/// 「住在手机上的那个小生命」的样子。我给过四个位置的预览，她选了：
/// 通知里用它、做成能发的表情包；**明确不做「自动换头像」**。
///
/// ## 为什么表情不走聊天图片那条路
///
/// 图片消息走 `ChatImages`：存进文件、30 天后被 [ChatImages.sweep] 清掉。
/// 表情是打包进 App 的资源，**永远都在**，也不占她的存储。所以消息上只记一个
/// key（`metadata['sticker']`），画的时候现查资源路径——和语音消息记
/// `metadata['voice']` 是同一个路子。
///
/// ## 这里的文字分两拨看
///
/// [label] 是给她看的（面板上那几个字）；[when] 是给模型看的（什么时候该发）。
/// 两者不能混用：给模型的要写清楚场合，给她的越短越好。
class Sticker {
  const Sticker({
    required this.key,
    required this.label,
    required this.when,
  });

  /// 存进消息里的短名。**改了会让老消息画不出来**，只增不改。
  final String key;

  /// 面板上显示的名字。
  final String label;

  /// 给模型的「什么时候用这张」。
  final String when;

  String get asset => 'assets/stickers/mochi_$key.png';
}

const kStickers = <Sticker>[
  Sticker(key: 'calm', label: '平常', when: '半眯着眼，懒懒的。随口应一句、无可奈何、「嗯」的时候。'),
  Sticker(key: 'wink', label: '高兴', when: '眨眼笑。她说了好消息、你俩说到一块去了、想逗她的时候。'),
  Sticker(key: 'alert', label: '好奇', when: '瞪大眼睛竖着耳朵。听到没想到的事、想追问、被勾起兴趣的时候。'),
  Sticker(key: 'sleepy', label: '困了', when: '侧过脸，眼睛快闭上。深夜、她该睡了、你也没什么精神的时候。'),
  Sticker(key: 'box', label: '躲着', when: '缩在纸箱里探出头。不想说话、心虚、装死、被说中了的时候。'),
  Sticker(key: 'back', label: '不理你', when: '背对着，只留一条尾巴。生闷气、赌气、故意不接话的时候。'),
  Sticker(key: 'sit', label: '坐着', when: '端端正正坐着看你。认真听、等她说下去、陪着的时候。'),
];

Sticker? stickerOf(String? key) {
  if (key == null) return null;
  for (final s in kStickers) {
    if (s.key == key) return s;
  }
  return null;
}

/// 给模型看的清单，拼进工具描述里。
String get stickerMenu =>
    kStickers.map((s) => '- `${s.key}`（${s.label}）：${s.when}').join('\n');
