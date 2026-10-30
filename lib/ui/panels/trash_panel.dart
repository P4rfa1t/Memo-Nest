/// 回收站面板：列出已删除的便签，可恢复或彻底删除。
library;

import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../core/models.dart';
import '../theme.dart';
import '../widgets/panel_scaffold.dart';

class TrashPanel extends StatefulWidget {
  final AppState state;
  final VoidCallback onClose;

  const TrashPanel({super.key, required this.state, required this.onClose});

  @override
  State<TrashPanel> createState() => _TrashPanelState();
}

class _TrashPanelState extends State<TrashPanel> {
  late List<TrashEntry> _entries;

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    _entries = state.trashEntries();
  }

  void _reload() {
    setState(() => _entries = state.trashEntries());
  }

  @override
  Widget build(BuildContext context) {
    return PanelScaffold(
      title: '回收站',
      onClose: widget.onClose,
      maxWidth: 420,
      maxHeight: 520,
      child: _entries.isEmpty
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: 46),
              child: Center(
                child: Text(
                  '回收站是空的',
                  style: TextStyle(fontSize: 12.5, color: Palette.muted),
                ),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 14),
              itemCount: _entries.length,
              separatorBuilder: (_, __) => const SizedBox(height: 6),
              itemBuilder: (context, index) => _buildCard(_entries[index]),
            ),
    );
  }

  Widget _buildCard(TrashEntry entry) {
    return Container(
      padding: const EdgeInsets.fromLTRB(11, 9, 9, 9),
      decoration: BoxDecoration(
        color: Palette.field,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: Palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            entry.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: Palette.fg,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            '${entry.sourceLabel} · ${entry.deletedLabel}',
            style: const TextStyle(fontSize: 10.5, color: Palette.muted),
          ),
          if (entry.tags.isNotEmpty) ...[
            const SizedBox(height: 5),
            Wrap(
              spacing: 5,
              runSpacing: 4,
              children: [
                for (final tag in entry.tags)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Palette.strip,
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Text(
                      tag,
                      style:
                          const TextStyle(fontSize: 10, color: Palette.muted),
                    ),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 7),
          Row(
            children: [
              _smallButton('恢复', () {
                state.restoreTrash(entry);
                _reload();
              }),
              const SizedBox(width: 6),
              _smallButton('彻底删除', () {
                state.deleteTrash(entry);
                _reload();
              }, danger: true),
            ],
          ),
        ],
      ),
    );
  }

  Widget _smallButton(String label, VoidCallback onTap, {bool danger = false}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: Palette.card,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: Palette.border),
        ),
        child: Text(
          label,
          style: TextStyle(
              fontSize: 11, color: danger ? Palette.danger : Palette.fg),
        ),
      ),
    );
  }
}
