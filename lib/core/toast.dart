/// 右下角浮层提示的数据模型。
///
/// 底栏那行小字只有 11px、又和字数统计挤在一起，备份、导入这类
/// 「一次性结果」放在那儿经常看不清。所以这类消息走浮层：
/// 深色卡片、白字、右下角、几秒后自己消失。
library;

enum ToastKind { info, success, error }

class ToastMessage {
  final int id;
  final String text;
  final ToastKind kind;

  const ToastMessage(this.id, this.text, this.kind);
}
