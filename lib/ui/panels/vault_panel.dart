/// 私密库面板：创建 / 解锁 / 修改密码三种形态共用一套外壳。
///
/// 字段数量随模式变化：create 用 2 个（密码 + 确认），
/// unlock 用 1 个，password 用 3 个（当前 / 新 / 确认）。
library;

import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../core/hello.dart';
import '../theme.dart';
import '../widgets/panel_scaffold.dart';

class VaultPanel extends StatefulWidget {
  final AppState state;
  final VoidCallback onClose;

  const VaultPanel({super.key, required this.state, required this.onClose});

  @override
  State<VaultPanel> createState() => _VaultPanelState();
}

class _VaultPanelState extends State<VaultPanel> {
  final _fields = <TextEditingController>[
    TextEditingController(),
    TextEditingController(),
    TextEditingController(),
  ];
  final _focus = <FocusNode>[FocusNode(), FocusNode(), FocusNode()];
  String _message = '';
  bool _busy = false;
  /// 系统凭据能不能用（Windows Hello / Android 生物识别，已录入才算）。
  ///
  /// 这里**不看**托管记录在不在：第一次解锁时 `hello.bin` 还没有，
  /// 要是拿它当门槛，按钮就永远不会出现（先有凭据才能解锁，
  /// 要有凭据又得先解锁）。凭据缺失由 `retrieve()` 在点击时给提示。
  /// 默认显示按钮：还没探测完也先给，探测到确实不可用才收起来。
  bool _helloVisible = true;

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus[0].requestFocus();
    });
    _probeHello();
  }

  @override
  void dispose() {
    for (final controller in _fields) {
      controller.dispose();
    }
    for (final node in _focus) {
      node.dispose();
    }
    super.dispose();
  }

  /// 探测这台机器能不能用 Windows Hello。
  Future<void> _probeHello() async {
    var device = false;
    if (state.hello.supported) {
      try {
        device = await state.hello.deviceAvailable();
      } on HelloError {
        device = false;
      } on Exception {
        device = false;
      }
    }
    if (!mounted) return;
    setState(() {
      _helloVisible = device;
    });
  }

  Future<void> _unlockWithHello() async {
    setState(() {
      _busy = true;
      _message = '';
    });
    try {
      await state.unlockVaultWithHello();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = '';
      });
    } on HelloError catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        // 「已取消」是用户主动关掉对话框，不当错误红字显示。
        _message = e.message == '已取消' ? '' : e.message;
      });
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final mode = state.vaultPanelMode;
    final spec = _specFor(mode);

    return PanelScaffold(
      title: spec.title,
      onClose: widget.onClose,
      maxWidth: 360,
      maxHeight: 420,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              spec.description,
              style: const TextStyle(
                  fontSize: 11.5, color: Palette.muted, height: 1.6),
            ),
            const SizedBox(height: 14),
            for (var i = 0; i < spec.fieldCount; i++) ...[
              TextField(
                controller: _fields[i],
                focusNode: _focus[i],
                obscureText: true,
                style: const TextStyle(fontSize: 12.5, color: Palette.fg),
                decoration: InputDecoration(hintText: spec.hints[i]),
                textInputAction: i == spec.fieldCount - 1
                    ? TextInputAction.done
                    : TextInputAction.next,
                onSubmitted: (_) {
                  if (i == spec.fieldCount - 1) {
                    _submit();
                  } else {
                    _focus[i + 1].requestFocus();
                  }
                },
              ),
              const SizedBox(height: 8),
            ],
            if (_message.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                _message,
                style: const TextStyle(
                    fontSize: 11.5, color: Palette.danger, height: 1.5),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _primaryButton(
                    _busy ? '处理中…' : spec.primary,
                    _busy ? null : _submit,
                  ),
                ),
                const SizedBox(width: 8),
                _secondaryButton('取消', widget.onClose),
              ],
            ),
            if (mode == VaultPanelMode.unlock && _helloVisible) ...[
              const SizedBox(height: 8),
              GestureDetector(
                onTap: _busy ? null : _unlockWithHello,
                child: Container(
                  height: 34,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Palette.card,
                    borderRadius: BorderRadius.circular(9),
                    border: Border.all(color: const Color(0xFFDCC888)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.fingerprint,
                          size: 16, color: Palette.fg),
                      const SizedBox(width: 6),
                      Text(
                        _busy
                            ? '等待验证…'
                            : '用 ${state.host.authLabel} 解锁',
                        style: const TextStyle(fontSize: 12.5, color: Palette.fg),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            if (mode == VaultPanelMode.unlock) ...[
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: _busy ? null : _confirmReset,
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(0, 28),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text(
                    '忘记密码？',
                    style: TextStyle(fontSize: 11, color: Palette.link),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _primaryButton(String label, VoidCallback? onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: onTap == null
              ? Palette.strip.withValues(alpha: 0.6)
              : Palette.accent,
          borderRadius: BorderRadius.circular(9),
        ),
        child: Text(
          label,
          style: const TextStyle(
              fontSize: 12.5, color: Palette.fg, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  Widget _secondaryButton(String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Palette.strip,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: const Color(0xFFDCC888)),
        ),
        child: Text(label,
            style: const TextStyle(fontSize: 12.5, color: Palette.fg)),
      ),
    );
  }

  /// 忘记主密码：确认后清空私密库（不可恢复），与 Python 版一致。
  Future<void> _confirmReset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Palette.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('忘记主密码',
            style: TextStyle(fontSize: 15, color: Palette.fg)),
        content: const Text(
          '重置主密码会永久删除私密库里的全部便签和回收站内容，且无法恢复。\n\n'
          '普通便签不受影响。确定继续吗？',
          style: TextStyle(fontSize: 13, color: Palette.fg, height: 1.65),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消', style: TextStyle(color: Palette.muted)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除并重置', style: TextStyle(color: Palette.danger)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      state.resetVault();
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() => _message = '重置失败：$e');
    }
  }

  void _submit() {
    final mode = state.vaultPanelMode;
    final values = _fields.map((c) => c.text).toList();
    final problem = _validate(mode, values);
    if (problem != null) {
      setState(() => _message = problem);
      return;
    }
    setState(() {
      _busy = true;
      _message = '';
    });
    // scrypt 在纯 Dart 里要 1~3 秒，放到下一帧后执行，
    // 让「处理中…」先画出来（真正隔离到 isolate 需要传状态，这里先保证有反馈）。
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        switch (mode) {
          case VaultPanelMode.create:
            await state.createVault(values[0]);
          case VaultPanelMode.unlock:
            await state.unlockVault(values[0]);
          case VaultPanelMode.password:
            state.changeVaultPassword(values[0], values[1]);
          case VaultPanelMode.none:
            break;
        }
        if (!mounted) return;
        for (final controller in _fields) {
          controller.clear();
        }
        setState(() {
          _busy = false;
          _message = '';
        });
      } on Exception catch (e) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _message = '$e';
        });
      }
    });
  }

  String? _validate(VaultPanelMode mode, List<String> values) {
    switch (mode) {
      case VaultPanelMode.create:
        if (values[0].length < 6) return '主密码至少 6 位';
        if (values[0] != values[1]) return '两次输入的密码不一致';
        return null;
      case VaultPanelMode.unlock:
        if (values[0].isEmpty) return '请输入主密码';
        return null;
      case VaultPanelMode.password:
        if (values[0].isEmpty) return '请输入当前主密码';
        if (values[1].length < 6) return '新密码至少 6 位';
        if (values[1] != values[2]) return '两次输入的新密码不一致';
        if (values[0] == values[1]) return '新密码不能与当前密码相同';
        return null;
      case VaultPanelMode.none:
        return null;
    }
  }

  _Spec _specFor(VaultPanelMode mode) {
    switch (mode) {
      case VaultPanelMode.create:
        return const _Spec(
          title: '创建私密笔记库',
          description: '设置一个主密码。私密便签会用这个密码派生出的密钥逐条加密，'
              '密码不会被保存，忘记后无法找回。',
          primary: '创建',
          fieldCount: 2,
          hints: ['主密码（至少 6 位）', '再次输入主密码', ''],
        );
      case VaultPanelMode.password:
        return const _Spec(
          title: '修改主密码',
          description: '输入当前密码与新密码。修改后旧的加密数据会用新密钥重新包裹。',
          primary: '修改',
          fieldCount: 3,
          hints: ['当前主密码', '新主密码（至少 6 位）', '再次输入新密码'],
        );
      case VaultPanelMode.unlock:
      case VaultPanelMode.none:
        return const _Spec(
          title: '解锁私密笔记库',
          description: '输入主密码查看私密便签。关闭面板或退出应用后会自动锁定。',
          primary: '解锁',
          fieldCount: 1,
          hints: ['主密码', '', ''],
        );
    }
  }
}

class _Spec {
  final String title;
  final String description;
  final String primary;
  final int fieldCount;
  final List<String> hints;

  const _Spec({
    required this.title,
    required this.description,
    required this.primary,
    required this.fieldCount,
    required this.hints,
  });
}
