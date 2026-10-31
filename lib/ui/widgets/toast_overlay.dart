/// 右下角浮层提示。
///
/// 底栏那行 11px 的小字和字数统计挤在一起，备份结果、导入结果这类
/// 「一次性消息」放在那儿经常看不清——尤其是有两三段拼接文字的时候。
/// 所以这类消息走浮层：深色卡片、白字、右下角、几秒后自己消失，
/// 点一下可以立刻关掉。
///
/// 三个平台共用一套实现，Android 上同样贴在右下角。
library;

import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../core/toast.dart';
import '../theme.dart';

class ToastOverlay extends StatelessWidget {
  final AppState state;

  const ToastOverlay({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final items = state.toasts;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: IgnorePointer(
        ignoring: items.isEmpty,
        // Android 上底部有手势条/导航栏，不避让会被盖住。
        child: SafeArea(
          top: false,
          left: false,
          right: false,
          child: Align(
            alignment: Alignment.bottomRight,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 44),
              child: ConstrainedBox(
                // 太宽会挡住正文，太窄长路径会折成好几行。
                constraints: const BoxConstraints(maxWidth: 320),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (final item in items)
                      _ToastCard(
                        key: ValueKey<int>(item.id),
                        message: item,
                        onDismiss: () => state.dismissToast(item.id),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ToastCard extends StatefulWidget {
  final ToastMessage message;
  final VoidCallback onDismiss;

  const _ToastCard({super.key, required this.message, required this.onDismiss});

  @override
  State<_ToastCard> createState() => _ToastCardState();
}

class _ToastCardState extends State<_ToastCard> {
  bool _shown = false;

  @override
  void initState() {
    super.initState();
    // 进场动画：下一帧再翻 _shown，AnimatedSlide 才有得插值。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _shown = true);
    });
  }

  Color get _barColor => switch (widget.message.kind) {
        ToastKind.success => const Color(0xFF7FBF6A),
        ToastKind.error => const Color(0xFFE07A6A),
        ToastKind.info => Palette.accent,
      };

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    return AnimatedSlide(
      duration: const Duration(milliseconds: 180),
      offset: _shown ? Offset.zero : const Offset(0, 0.25),
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 180),
        opacity: _shown ? 1 : 0,
        child: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: widget.onDismiss,
              borderRadius: BorderRadius.circular(10),
              child: Container(
                decoration: BoxDecoration(
                  // 深色底保证在浅黄背景上一眼能看见，也不再跟正文抢注意力。
                  color: const Color(0xF23B3323),
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x33000000),
                      blurRadius: 12,
                      offset: Offset(0, 4),
                    ),
                  ],
                ),
                // 竖条用 Stack 铺满高度。之前用 IntrinsicHeight + Row，
                // 它按固有宽度测量，会把外面的 maxWidth 撑破。
                child: Stack(
                  children: [
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      width: 3,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: _barColor,
                          borderRadius: const BorderRadius.horizontal(
                            left: Radius.circular(10),
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(15, 9, 14, 10),
                      // 用 Text 而不是 SelectableText：可选文本会自己
                      // 吃掉点击手势，点卡片就关不掉了。
                      child: Text(
                        message.text,
                        style: const TextStyle(
                          fontSize: 12,
                          height: 1.45,
                          color: Color(0xFFFFF8D9),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
