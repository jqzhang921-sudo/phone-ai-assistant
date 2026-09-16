import 'package:flutter/painting.dart';

/// 退到后台时，把图片缓存交还给系统。
///
/// ## 为什么
///
/// 2026-09-16 实测：ColorOS 杀掉 Nook 的那几次（`dumpsys activity exit-info`
/// 里的 `o-kill`），都发生在它**在后台、状态是空进程、占 300~480MB** 的时候。
/// 而它一退到后台，图片缓存里那些壁纸、聊天图、截图还原样留着——于是它以一个
/// 四百多兆的空进程躺在那儿，正好是清理程序最想挑的目标。
///
/// 杀进程的连锁反应不只是「App 没了」：无障碍服务活在同一个进程里，进程一死，
/// 系统就把「看一眼屏幕」记进 Crashed services，而且**不会自己接回来**，
/// 只能她手动去关一次再开（见 [GlanceHealth]）。所以后台体量是那件事的上游。
///
/// ## 为什么连 live 的也放
///
/// [ImageCache.clear] 只丢「缓存着但没人用」的那部分。退到后台时，界面还挂在
/// 树上，那些图对缓存来说仍然是 live 的——只清前者基本省不下东西。
/// [ImageCache.clearLiveImages] 连它们一起丢，回到前台时重新解码。
///
/// 代价是回来那一下要重解，图可能闪一下。**这是故意换的**：在后台省下几十兆，
/// 换回前台时的一次重解。她要是觉得闪得明显，再改成「后台待够一会儿才放」。
///
/// 只在真的退到后台时调（paused / detached），不要在 inactive 时调——
/// 下拉通知栏、来个电话都会触发 inactive，那时人马上就回来。
void freeImageCacheForBackground(ImageCache cache) {
  cache.clear();
  cache.clearLiveImages();
}
