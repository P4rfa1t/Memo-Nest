/// 设置面板：四个分页（通用 / 私密库 / OneDrive / GitHub）。
///
/// 与 Tk 版一样内嵌在主窗口里，用 IndexedStack 叠放，
/// 切分页只是改 index，不重建控件。
library;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

import '../../app_state.dart';
import '../../core/backup.dart';
import '../../core/onedrive.dart';
import '../../platform/windows_shell.dart';
import '../theme.dart';
import '../widgets/panel_scaffold.dart';

/// 打开外部链接。url_launcher 在 Windows 上偶尔抛 PlatformException
/// （没有默认浏览器、被组策略拦下），这里统一收成 false，交给调用方提示。
Future<bool> launchUrlExt(Uri uri) async {
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } on Object {
    return false;
  }
}

class SettingsPanel extends StatefulWidget {
  final AppState state;
  final VoidCallback onClose;

  const SettingsPanel({super.key, required this.state, required this.onClose});

  @override
  State<SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends State<SettingsPanel> {
  int _tab = 0;

  static const _tabs = ['通用', '私密库', 'OneDrive', 'GitHub'];

  AppState get state => widget.state;

  @override
  Widget build(BuildContext context) {
    return PanelScaffold(
      title: '设置',
      onClose: widget.onClose,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Row(
              children: [
                for (var i = 0; i < _tabs.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: _tabButton(i),
                  ),
              ],
            ),
          ),
          Expanded(
            child: IndexedStack(
              index: _tab,
              sizing: StackFit.expand,
              children: [
                _GeneralTab(state: state),
                _VaultTab(state: state),
                _OneDriveTab(state: state),
                _GitHubTab(state: state),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _tabButton(int index) {
    final selected = _tab == index;
    return GestureDetector(
      onTap: () => setState(() => _tab = index),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFE7CF87) : Palette.strip,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFDCC888)),
        ),
        child: Text(
          _tabs[index],
          style: TextStyle(
            fontSize: 11.5,
            color: Palette.fg,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 通用
// ---------------------------------------------------------------------------
class _GeneralTab extends StatefulWidget {
  final AppState state;

  const _GeneralTab({required this.state});

  @override
  State<_GeneralTab> createState() => _GeneralTabState();
}

class _GeneralTabState extends State<_GeneralTab> {
  AppState get state => widget.state;

  String _note = '';

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
      children: [
        _switchRow('开机自动启动', 'general.autostart',
            hint: '写入当前用户的注册表 Run 项，可在任务管理器的「启动」中查看。'),
        _switchRow('窗口始终置顶', 'general.always_on_top',
            hint: '开启后便签窗口会停留在其他窗口上方。'),
        _switchRow('退出时自动备份', 'general.backup_on_exit',
            hint: '有改动时，退出前会执行一次本地备份。'),
        _numberRow(state, '定时备份（分钟）', 'general.auto_backup_minutes',
            hint: '0 表示关闭定时备份；建议 30～120 分钟。',
            onAfter: state.setAutoBackupMinutes),
        _numberRow(state, '本地保留备份数', 'general.keep_backups',
            hint: 'data/backups 中保留的 zip 数量，旧的会自动清理。'),
        const SizedBox(height: 14),
        Align(
          alignment: Alignment.centerLeft,
          child: _actionButton('创建桌面快捷方式', () {
            try {
              final path = createDesktopShortcut();
              setState(() => _note = '已创建：$path');
            } on WindowsShellError catch (e) {
              setState(() => _note = e.message);
            }
          }),
        ),
        if (_note.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            _note,
            style:
                const TextStyle(fontSize: 11, color: Palette.link, height: 1.6),
          ),
        ],
        const SizedBox(height: 14),
        Text(
          '数据目录：${state.paths.dataDir}',
          style:
              const TextStyle(fontSize: 11, color: Palette.muted, height: 1.6),
        ),
      ],
    );
  }

  Widget _switchRow(String label, String key, {String hint = ''}) {
    final value = state.config.get(key, false) == true;
    return _Row(
      label: label,
      hint: hint,
      trailing: Switch(
        value: value,
        activeThumbColor: Palette.card,
        activeTrackColor: Palette.accent,
        onChanged: (next) {
          if (key == 'general.autostart') {
            try {
              setAutostart(next);
            } on WindowsShellError catch (e) {
              setState(() => _note = e.message);
              return;
            }
          }
          state.config.set(key, next);
          state.config.save();
          if (key == 'general.always_on_top') {
            windowManager.setAlwaysOnTop(next);
          }
          setState(() {});
        },
      ),
    );
  }
}

/// 数字输入框：回车或失焦时提交，持有自己的 controller。
class _NumberField extends StatefulWidget {
  final int initial;
  final ValueChanged<int> onCommit;

  const _NumberField({required this.initial, required this.onCommit});

  @override
  State<_NumberField> createState() => _NumberFieldState();
}

class _NumberFieldState extends State<_NumberField> {
  late final TextEditingController _controller =
      TextEditingController(text: '${widget.initial}');
  late final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _commit();
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _commit() {
    final parsed = int.tryParse(_controller.text.trim());
    if (parsed == null) {
      _controller.text = '${widget.initial}';
      return;
    }
    if (parsed != widget.initial) widget.onCommit(parsed);
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      focusNode: _focus,
      keyboardType: TextInputType.number,
      textAlign: TextAlign.right,
      style: const TextStyle(fontSize: 12.5, color: Palette.fg),
      decoration: const InputDecoration(
        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      ),
      onSubmitted: (_) => _commit(),
    );
  }
}

// ---------------------------------------------------------------------------
// 私密库
// ---------------------------------------------------------------------------
class _VaultTab extends StatefulWidget {
  final AppState state;

  const _VaultTab({required this.state});

  @override
  State<_VaultTab> createState() => _VaultTabState();
}

class _VaultTabState extends State<_VaultTab> {
  final _old = TextEditingController();
  final _next = TextEditingController();
  final _repeat = TextEditingController();
  String _message = '';

  AppState get state => widget.state;

  @override
  void dispose() {
    _old.dispose();
    _next.dispose();
    _repeat.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final exists = state.vault != null && state.vault!.exists();
    final unlocked = state.vault?.unlocked == true;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
      children: [
        _Row(
          label: '加密库状态',
          hint: exists ? (unlocked ? '已解锁' : '已锁定') : '尚未创建',
          trailing: Text(
            exists ? (unlocked ? '🔓' : '🔒') : '—',
            style: const TextStyle(fontSize: 15),
          ),
        ),
        const SizedBox(height: 10),
        if (exists) ...[
          const Text(
            '修改主密码',
            style: TextStyle(
                fontSize: 12.5, fontWeight: FontWeight.w600, color: Palette.fg),
          ),
          const SizedBox(height: 8),
          _passwordField(_old, '当前主密码'),
          const SizedBox(height: 6),
          _passwordField(_next, '新主密码（至少 6 位）'),
          const SizedBox(height: 6),
          _passwordField(_repeat, '再次输入新密码'),
          const SizedBox(height: 10),
          Row(
            children: [
              _actionButton('修改密码', _changePassword),
              const SizedBox(width: 8),
              _actionButton('锁定', () {
                state.lockVault();
                setState(() => _message = '已锁定');
              }, danger: false),
            ],
          ),
        ] else
          const Text(
            '还没有加密库。到主界面切到「私密」标签即可创建。',
            style: TextStyle(fontSize: 12, color: Palette.muted, height: 1.6),
          ),
        if (_message.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(
            _message,
            style: const TextStyle(
                fontSize: 11.5, color: Palette.link, height: 1.5),
          ),
        ],
        const SizedBox(height: 14),
        const Text(
          '主密码用 scrypt(N=2^15) 派生密钥，笔记逐条用 AES-256-GCM 加密；'
          '主密码不会保存在任何地方，忘记后无法找回。',
          style: TextStyle(fontSize: 11, color: Palette.muted, height: 1.65),
        ),
      ],
    );
  }

  Widget _passwordField(TextEditingController controller, String hint) {
    return TextField(
      controller: controller,
      obscureText: true,
      style: const TextStyle(fontSize: 12.5, color: Palette.fg),
      decoration: InputDecoration(hintText: hint),
    );
  }

  void _changePassword() {
    final old = _old.text;
    final next = _next.text;
    final repeat = _repeat.text;
    if (old.isEmpty) {
      setState(() => _message = '请输入当前主密码');
      return;
    }
    if (next.length < 6) {
      setState(() => _message = '新密码至少 6 位');
      return;
    }
    if (next != repeat) {
      setState(() => _message = '两次输入的新密码不一致');
      return;
    }
    try {
      state.changeVaultPassword(old, next);
      _old.clear();
      _next.clear();
      _repeat.clear();
      setState(() => _message = '主密码已修改');
    } on Exception catch (e) {
      setState(() => _message = '$e');
    }
  }
}

// ---------------------------------------------------------------------------
// OneDrive
// ---------------------------------------------------------------------------
class _OneDriveTab extends StatefulWidget {
  final AppState state;

  const _OneDriveTab({required this.state});

  @override
  State<_OneDriveTab> createState() => _OneDriveTabState();
}

class _OneDriveTabState extends State<_OneDriveTab> {
  late final TextEditingController _folder;
  late final TextEditingController _clientId;
  late final TextEditingController _tenant;

  String _note = '';
  bool _busy = false;
  String _busyLabel = '';
  bool _cancelled = false;

  /// 当前展示给用户的设备代码。
  DeviceCodeInfo? _device;

  AppState get state => widget.state;
  OneDriveService get service => state.oneDrive;

  bool get _graphMode => state.oneDriveMode == 'graph';

  @override
  void initState() {
    super.initState();
    _folder = TextEditingController(
      text: '${state.config.get('onedrive.folder', '')}',
    );
    _clientId = TextEditingController(
      text: '${state.config.get('onedrive.client_id', '')}',
    );
    final tenant = '${state.config.get('onedrive.tenant', 'common')}';
    _tenant = TextEditingController(text: tenant.isEmpty ? 'common' : tenant);
  }

  @override
  void dispose() {
    _cancelled = true;
    _folder.dispose();
    _clientId.dispose();
    _tenant.dispose();
    super.dispose();
  }

  void _commitFolder() {
    state.config.set('onedrive.folder', _folder.text.trim());
    state.config.save();
    setState(() => _note = '');
  }

  void _commitGraph() {
    state.config.set('onedrive.client_id', _clientId.text.trim());
    final tenant = _tenant.text.trim();
    state.config.set('onedrive.tenant', tenant.isEmpty ? 'common' : tenant);
    state.config.save();
  }

  void _detect() {
    final dir = detectOneDriveDir();
    if (dir == null) {
      setState(() => _note = '没有找到 OneDrive 文件夹，请手动填写。');
      return;
    }
    _folder.text = dir.path;
    _commitFolder();
    setState(() => _note = '已填入：${dir.path}');
  }

  /// 把状态切到「忙」，标题写进 [_busyLabel]，跑 [task]。
  ///
  /// 所有 Graph 操作都要 await，直接 setState 到忙态再 await 才不会让界面
  /// 看起来卡死——设备代码登录最多要等 15 分钟。
  Future<void> _run(String label, Future<String> Function() task) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _busyLabel = label;
      _note = '';
    });
    String message;
    try {
      message = await task();
    } on GraphError catch (e) {
      message = e.message;
    } on BackupError catch (e) {
      message = e.message;
    } on Object catch (e) {
      message = '出错了：$e';
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _busyLabel = '';
      _note = message;
    });
  }

  Future<String> _syncNow() async {
    _commitFolder();
    _commitGraph();
    if (_graphMode) {
      final snapshot = state.backup.createSnapshot(label: 'onedrive');
      return service.sync(snapshot: snapshot);
    }
    return state.backup.mirrorToFolder() ?? 'OneDrive 未启用或未填写文件夹。';
  }

  /// 设备代码登录：先拿码显示出来，用户来点「打开浏览器」，
  /// 后台继续轮询；成功后顺手把账号名写进状态栏。
  Future<String> _login() async {
    _commitGraph();
    _cancelled = false;
    final name = await service.loginDeviceFlow(
      onCode: (info) {
        if (!mounted) return;
        setState(() => _device = info);
      },
      shouldStop: () => _cancelled || !mounted,
    );
    if (mounted) setState(() => _device = null);
    return '已登录：$name';
  }

  void _cancelLogin() {
    _cancelled = true;
    setState(() {
      _busy = false;
      _busyLabel = '';
      _device = null;
      _note = '已取消登录';
    });
  }

  Future<void> _openBrowser() async {
    final info = _device;
    if (info == null) return;
    final uri = Uri.tryParse(info.verificationUri);
    if (uri == null) {
      setState(() => _note = '微软返回的验证地址无效');
      return;
    }
    final ok = await launchUrlExt(uri);
    if (!mounted) return;
    setState(() => _note = ok
        ? '已在浏览器打开，输入代码 ${info.userCode} 完成授权。'
        : '打开浏览器失败，请手动访问 ${info.verificationUri}');
  }

  Future<void> _logout() async {
    service.logout();
    setState(() {
      _device = null;
      _note = '已退出 Microsoft 账号';
    });
  }

  @override
  Widget build(BuildContext context) {
    final enabled = state.config.get('onedrive.enabled', false) == true;
    final mirror = state.config.get('onedrive.mirror_notes', true) == true;
    final loggedIn = service.isLoggedIn;
    final accountName = service.account;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
      children: [
        _Row(
          label: '启用 OneDrive 备份',
          hint: _graphMode
              ? '登录 Microsoft 账号后直接上传到云端，不经过本地 OneDrive 客户端。'
              : '把备份复制到 OneDrive 同步文件夹，不需要登录。',
          trailing: Switch(
            value: enabled,
            activeThumbColor: Palette.card,
            activeTrackColor: Palette.accent,
            onChanged: (next) {
              state.config.set('onedrive.enabled', next);
              state.config.save();
              setState(() {});
            },
          ),
        ),
        _Row(
          label: '同时镜像明文笔记',
          hint: '在子目录的 notes 里放一份可直接浏览的 .md；私密库始终只上传密文。',
          trailing: Switch(
            value: mirror,
            activeThumbColor: Palette.card,
            activeTrackColor: Palette.accent,
            onChanged: (next) {
              state.config.set('onedrive.mirror_notes', next);
              state.config.save();
              setState(() {});
            },
          ),
        ),
        _numberRow(state, '云端保留备份数', 'onedrive.keep_backups',
            hint: '子目录里保留的 memo-backup-*.zip 数量。'),
        const SizedBox(height: 12),

        // ---------- 模式切换 ----------
        const Text(
          '同步方式',
          style: TextStyle(
              fontSize: 12.5, fontWeight: FontWeight.w600, color: Palette.fg),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            _modeChip('folder', '本地文件夹', '复制到 OneDrive 同步目录'),
            const SizedBox(width: 8),
            _modeChip('graph', '账号登录', '直接上传到云端'),
          ],
        ),
        const SizedBox(height: 14),

        if (_graphMode) ..._graphSections(loggedIn, accountName),
        if (!_graphMode) ..._folderSections(),

        const SizedBox(height: 8),
        Text(
          '子目录默认是「${state.config.get('onedrive.subfolder', 'MemoNest备份')}」。',
          style:
              const TextStyle(fontSize: 11, color: Palette.muted, height: 1.6),
        ),
        if (_busy) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                    strokeWidth: 1.6, color: Palette.muted),
              ),
              const SizedBox(width: 8),
              Text(
                _busyLabel,
                style: const TextStyle(fontSize: 11, color: Palette.muted),
              ),
            ],
          ),
        ],
        if (_note.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            _note,
            style:
                const TextStyle(fontSize: 11, color: Palette.link, height: 1.6),
          ),
        ],
      ],
    );
  }

  Widget _modeChip(String mode, String label, String hint) {
    final active = state.oneDriveMode == mode;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          state.setOneDriveMode(mode);
          setState(() => _note = '');
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 110),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: active ? const Color(0xFFE7CF87) : Palette.strip,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: active ? const Color(0xFFC9A94A) : const Color(0xFFDCC888),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  color: Palette.fg,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                hint,
                style: const TextStyle(
                    fontSize: 10, color: Palette.muted, height: 1.4),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _folderSections() {
    return [
      const Text(
        'OneDrive 文件夹',
        style: TextStyle(
            fontSize: 12.5, fontWeight: FontWeight.w600, color: Palette.fg),
      ),
      const SizedBox(height: 6),
      TextField(
        controller: _folder,
        style: const TextStyle(fontSize: 12.5, color: Palette.fg),
        decoration: const InputDecoration(hintText: r'例如 C:\Users\你\OneDrive'),
        onSubmitted: (_) => _commitFolder(),
        onTapOutside: (_) => _commitFolder(),
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _actionButton('自动检测', _detect),
          _actionButton('立即同步', () => _run('正在复制到文件夹…', _syncNow)),
        ],
      ),
      const SizedBox(height: 8),
      const Text(
        '留空则自动探测 OneDrive 目录；探测不到时需要手动填写。',
        style: TextStyle(fontSize: 11, color: Palette.muted, height: 1.6),
      ),
    ];
  }

  List<Widget> _graphSections(bool loggedIn, String accountName) {
    final device = _device;
    return [
      const Text(
        'Azure 应用 ID',
        style: TextStyle(
            fontSize: 12.5, fontWeight: FontWeight.w600, color: Palette.fg),
      ),
      const SizedBox(height: 6),
      TextField(
        controller: _clientId,
        style: const TextStyle(fontSize: 12.5, color: Palette.fg),
        decoration: const InputDecoration(
          hintText: '应用程序(客户端) ID，形如 00000000-0000-…',
        ),
        onSubmitted: (_) => _commitGraph(),
        onTapOutside: (_) => _commitGraph(),
      ),
      const SizedBox(height: 4),
      const Text(
        '在 Azure 门户免费注册一个应用即可，类型选「移动和桌面应用程序」，'
        '并开启「允许公共客户端流」。ID 会保存在本地 config.json。',
        style: TextStyle(fontSize: 11, color: Palette.muted, height: 1.6),
      ),
      const SizedBox(height: 10),
      const Text(
        '租户',
        style: TextStyle(
            fontSize: 12.5, fontWeight: FontWeight.w600, color: Palette.fg),
      ),
      const SizedBox(height: 6),
      TextField(
        controller: _tenant,
        style: const TextStyle(fontSize: 12.5, color: Palette.fg),
        decoration: const InputDecoration(hintText: 'common'),
        onSubmitted: (_) => _commitGraph(),
        onTapOutside: (_) => _commitGraph(),
      ),
      const SizedBox(height: 4),
      const Text(
        '个人账号保持 common；组织账号可填租户 ID 或域名。',
        style: TextStyle(fontSize: 11, color: Palette.muted, height: 1.6),
      ),
      const SizedBox(height: 14),

      // ---------- 登录状态 ----------
      Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: Palette.field,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Palette.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  loggedIn ? Icons.check_circle_outline : Icons.person_outline,
                  size: 15,
                  color: loggedIn ? const Color(0xFF7A8C3F) : Palette.muted,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    loggedIn
                        ? '已登录${accountName.isEmpty ? '' : '：$accountName'}'
                        : '未登录 Microsoft 账号',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: loggedIn ? Palette.fg : Palette.muted,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (device != null) ...[
              const Text(
                '在浏览器里输入下面的代码完成授权：',
                style: TextStyle(fontSize: 11, color: Palette.muted),
              ),
              const SizedBox(height: 6),
              SelectableText(
                device.userCode,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 3,
                  color: Palette.fg,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _actionButton('打开浏览器', _openBrowser),
                  _actionButton('取消', _cancelLogin, danger: true),
                ],
              ),
            ] else if (_busy) ...[
              Text(
                _busyLabel,
                style: const TextStyle(fontSize: 11, color: Palette.muted),
              ),
            ] else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _actionButton(
                    loggedIn ? '重新登录' : '登录 Microsoft 账号',
                    () => _run('正在等待浏览器授权…', _login),
                  ),
                  if (loggedIn) _actionButton('退出登录', _logout, danger: true),
                  if (loggedIn)
                    _actionButton(
                        '立即同步', () => _run('正在上传到 OneDrive…', _syncNow)),
                ],
              ),
          ],
        ),
      ),
    ];
  }
}

// ---------------------------------------------------------------------------
// GitHub
// ---------------------------------------------------------------------------
class _GitHubTab extends StatefulWidget {
  final AppState state;

  const _GitHubTab({required this.state});

  @override
  State<_GitHubTab> createState() => _GitHubTabState();
}

class _GitHubTabState extends State<_GitHubTab> {
  late final TextEditingController _repo;
  late final TextEditingController _token;

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    _repo =
        TextEditingController(text: '${state.config.get('github.repo', '')}');
    _token =
        TextEditingController(text: '${state.config.get('github.token', '')}');
  }

  @override
  void dispose() {
    _repo.dispose();
    _token.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = state.config.get('github.enabled', false) == true;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
      children: [
        _Row(
          label: '启用 GitHub 备份',
          hint: '把笔记推送到一个私有仓库，多设备同步。',
          trailing: Switch(
            value: enabled,
            activeThumbColor: Palette.card,
            activeTrackColor: Palette.accent,
            onChanged: (next) {
              state.config.set('github.enabled', next);
              state.config.save();
              setState(() {});
            },
          ),
        ),
        const SizedBox(height: 10),
        const Text(
          '仓库',
          style: TextStyle(
              fontSize: 12.5, fontWeight: FontWeight.w600, color: Palette.fg),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: _repo,
          style: const TextStyle(fontSize: 12.5, color: Palette.fg),
          decoration: const InputDecoration(hintText: 'owner/repo'),
          onSubmitted: (value) {
            state.config.set('github.repo', value.trim());
            state.config.save();
            setState(() {});
          },
        ),
        const SizedBox(height: 10),
        const Text(
          '访问令牌',
          style: TextStyle(
              fontSize: 12.5, fontWeight: FontWeight.w600, color: Palette.fg),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: _token,
          obscureText: true,
          style: const TextStyle(fontSize: 12.5, color: Palette.fg),
          decoration: const InputDecoration(hintText: 'ghp_… 需要 repo 权限'),
          onSubmitted: (value) {
            state.config.set('github.token', value.trim());
            state.config.save();
            setState(() {});
          },
        ),
        const SizedBox(height: 10),
        const Text(
          '令牌保存在本地 config.json，不会上传到任何地方。',
          style: TextStyle(fontSize: 11, color: Palette.muted, height: 1.6),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 共用小部件
// ---------------------------------------------------------------------------
/// 设置页通用的浅色小按钮。danger 为真时用警示色文字。
Widget _actionButton(String label, VoidCallback onTap, {bool danger = false}) {
  return GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
      decoration: BoxDecoration(
        color: Palette.strip,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFDCC888)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11.5,
          color: danger ? Palette.danger : Palette.fg,
        ),
      ),
    ),
  );
}

/// 一行「标签 + 数字输入」，输入框自带 controller，重建时不会跳光标。
Widget _numberRow(
  AppState state,
  String label,
  String key, {
  String hint = '',
  void Function(int value)? onAfter,
}) {
  return _Row(
    label: label,
    hint: hint,
    trailing: SizedBox(
      width: 72,
      child: _NumberField(
        initial: (state.config.get(key, 0) as num?)?.toInt() ?? 0,
        onCommit: (parsed) {
          state.config.set(key, parsed);
          state.config.save();
          onAfter?.call(parsed);
        },
      ),
    ),
  );
}

class _Row extends StatelessWidget {
  final String label;
  final String hint;
  final Widget? trailing;

  const _Row({required this.label, this.hint = '', this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(fontSize: 12.5, color: Palette.fg),
                ),
                if (hint.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      hint,
                      style: const TextStyle(
                          fontSize: 10.5, color: Palette.muted, height: 1.55),
                    ),
                  ),
              ],
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}
