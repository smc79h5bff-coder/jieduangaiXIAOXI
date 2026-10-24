import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../import/presentation/providers/import_providers.dart';
import '../../../parser/application/document_parser.dart';
import '../../../viewer/presentation/diff_viewer_screen.dart';

/// 单个文件允许参与查重的最大字节数。超过的直接跳过，避免长时间占用。
const int _maxCheckBytes = 100 * 1024 * 1024;

const EdgeInsets _inset = EdgeInsets.all(4);
const EdgeInsets _titlePad = EdgeInsets.fromLTRB(12, 8, 12, 0);
const EdgeInsets _contentPad = EdgeInsets.fromLTRB(8, 4, 8, 4);
const EdgeInsets _actionsPad = EdgeInsets.fromLTRB(4, 0, 4, 4);

/// 查重输入项（由搜索结果页传入）。
class DuplicateCandidate {
  const DuplicateCandidate({
    required this.path,
    required this.name,
    required this.size,
  });

  final String path;
  final String name;
  final int size;
}

class _DupFile {
  _DupFile(this.candidate, this.hash);

  final DuplicateCandidate candidate;
  final String hash;

  /// 默认不勾选，由用户手动选择要删除的文件。
  bool selected = false;

  /// 是否被标记为「对比对象」，与上面的删除勾选互不影响。
  bool markedForCompare = false;
}

class _DupGroup {
  _DupGroup({required this.size, required this.hash, required this.files});

  final int size;
  final String hash;
  final List<_DupFile> files;

  bool get allSelected => files.every((f) => f.selected);
}

/// 收集分块哈希算完后的摘要。
class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

/// 在 isolate 里流式计算 MD5，避免把整个文件读进内存。
///
/// 返回 `实际读取字节数|十六进制摘要`。调用方必须核对字节数，
/// 否则读取不完整/为空时摘要会退化成一个固定值，把不同内容误判成重复。
Future<String> _md5FileWorker(String path) async {
  final output = _DigestSink();
  final input = md5.startChunkedConversion(output);
  var bytes = 0;
  await for (final chunk in File(path).openRead()) {
    bytes += chunk.length;
    input.add(chunk);
  }
  input.close();
  final digest = output.value;
  if (digest == null) {
    throw FileSystemException('MD5 计算未产生结果', path);
  }
  return '$bytes|$digest';
}

String _fmtBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}

String _errText(Object e) {
  return e
      .toString()
      .replaceFirst('FileSystemException: ', '')
      .replaceFirst('PathAccessException: ', '')
      .replaceFirst('PathNotFoundException: ', '');
}

/// 搜索结果查重弹窗。
///
/// 判定标准只有一条：文件大小相同，且全量 MD5 相同。
/// 文件夹、超大文件、符号链接、读取失败的文件都不参与。
///
/// 结果按组展示，默认全部不勾选；用户勾选哪个就永久删除哪个。
/// 关闭时返回已删除文件的路径集合，未删除则为空集合。
class DuplicateFinderDialog extends ConsumerStatefulWidget {
  const DuplicateFinderDialog({
    super.key,
    required this.candidates,
  });

  final List<DuplicateCandidate> candidates;

  @override
  ConsumerState<DuplicateFinderDialog> createState() =>
      _DuplicateFinderDialogState();
}

class _DuplicateFinderDialogState
    extends ConsumerState<DuplicateFinderDialog> {
  bool _scanning = true;
  bool _cancelRequested = false;
  int _checked = 0;
  int _total = 0;

  List<_DupGroup> _groups = const [];
  int _skipped = 0;

  bool _processing = false;
  int _processDone = 0;
  int _processTotal = 0;

  final Set<String> _removed = <String>{};

  @override
  void initState() {
    super.initState();
    _scan();
  }

  int get _dupFileCount {
    var n = 0;
    for (final g in _groups) {
      n += g.files.length;
    }
    return n;
  }

  int get _selectedCount {
    var n = 0;
    for (final g in _groups) {
      for (final f in g.files) {
        if (f.selected) n++;
      }
    }
    return n;
  }

  int get _selectedBytes {
    var bytes = 0;
    for (final g in _groups) {
      for (final f in g.files) {
        if (f.selected) bytes += g.size;
      }
    }
    return bytes;
  }

  /// 有任意一组被全选时不允许执行：整组删光的损失无法挽回。
  bool get _hasFullySelectedGroup {
    for (final g in _groups) {
      if (g.allSelected) return true;
    }
    return false;
  }

  List<_DupFile> get _compareMarks => [
        for (final g in _groups)
          for (final f in g.files)
            if (f.markedForCompare) f,
      ];

  void _toggleCompareMark(_DupFile file) {
    if (_processing) return;
    setState(() {
      if (file.markedForCompare) {
        file.markedForCompare = false;
        return;
      }
      final marked = _compareMarks;
      // 最多两个：再标记第三个时顶掉最早标记的那个。
      if (marked.length >= 2) marked.first.markedForCompare = false;
      file.markedForCompare = true;
    });
  }

  /// 打开项目里已有的对比页（与文件浏览器底部「对比」按钮同一条路径）。
  Future<void> _openCompare() async {
    final marks = _compareMarks;
    if (marks.length != 2) return;
    final left = marks[0].candidate;
    final right = marks[1].candidate;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    try {
      final leftBytes = await File(left.path).readAsBytes();
      final leftParsed = await DocumentParser.parse(
        fileName: left.name,
        bytes: leftBytes,
      );
      final rightBytes = await File(right.path).readAsBytes();
      final rightParsed = await DocumentParser.parse(
        fileName: right.name,
        bytes: rightBytes,
      );

      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();

      ref.read(originalRawTextProvider.notifier).state = leftParsed.plainText;
      ref.read(modifiedRawTextProvider.notifier).state = rightParsed.plainText;
      ref.read(originalFileNameProvider.notifier).state = leftParsed.fileName;
      ref.read(modifiedFileNameProvider.notifier).state = rightParsed.fileName;
      ref.read(originalEncodingProvider.notifier).state = 'UTF-8';
      ref.read(modifiedEncodingProvider.notifier).state = 'UTF-8';
      ref.read(originalFilePathProvider.notifier).state = left.path;
      ref.read(modifiedFilePathProvider.notifier).state = right.path;
      ref.read(importRevisionProvider.notifier).state++;
      ref.read(editedOriginalProvider.notifier).state = null;
      ref.read(editedModifiedProvider.notifier).state = null;

      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => const DiffViewerScreen(),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      await showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          insetPadding: _inset,
          titlePadding: _titlePad,
          contentPadding: _contentPad,
          actionsPadding: _actionsPad,
          title: const Text('打不开对比页'),
          content: Text('读取文件失败：${_errText(e)}'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    }
  }

  Future<void> _scan() async {
    final candidates = <DuplicateCandidate>[];
    var skipped = 0;

    for (final c in widget.candidates) {
      if (c.size > _maxCheckBytes) {
        skipped++;
      } else {
        candidates.add(c);
      }
    }

    if (!mounted) return;
    setState(() {
      _scanning = true;
      _skipped = skipped;
      _checked = 0;
      _total = candidates.length;
    });

    // 先按大小分组，大小唯一的文件不用算 MD5。
    final bySize = <int, List<DuplicateCandidate>>{};
    for (final c in candidates) {
      bySize.putIfAbsent(c.size, () => <DuplicateCandidate>[]).add(c);
    }
    final needHash = <String>{};
    for (final list in bySize.values) {
      if (list.length < 2) continue;
      for (final c in list) {
        needHash.add(c.path);
      }
    }

    final byHash = <String, List<_DupFile>>{};
    var checked = 0;
    for (final c in candidates) {
      if (_cancelRequested || !mounted) return;
      checked++;

      if (needHash.contains(c.path)) {
        try {
          if (FileSystemEntity.isLinkSync(c.path)) {
            skipped++;
          } else if (!File(c.path).existsSync()) {
            skipped++;
          } else {
            final raw = await compute(_md5FileWorker, c.path);
            final sep = raw.indexOf('|');
            final readBytes = int.parse(raw.substring(0, sep));
            final hash = raw.substring(sep + 1);
            if (readBytes != c.size) {
              // 字节数和搜索结果记录的大小对不上：读到的不是完整文件，
              // 直接跳过，绝不能拿去分组。
              skipped++;
            } else {
              byHash
                  .putIfAbsent(hash, () => <_DupFile>[])
                  .add(_DupFile(c, hash));
            }
          }
        } catch (_) {
          // 权限不足 / 文件被占用 / 读取中途失败：跳过，不中断整体流程。
          skipped++;
        }

        if (!mounted) return;
        setState(() {
          _checked = checked;
          _skipped = skipped;
        });
      }
    }

    if (!mounted || _cancelRequested) return;
    setState(() {
      _checked = candidates.length;
      _skipped = skipped;
    });

    final groups = <_DupGroup>[];
    for (final list in byHash.values) {
      if (list.length < 2) continue;
      // 只是展示顺序：路径短的在前，长度相同时按字典序，保证结果稳定。
      list.sort((a, b) {
        final len = a.candidate.path.length.compareTo(b.candidate.path.length);
        if (len != 0) return len;
        return a.candidate.path.compareTo(b.candidate.path);
      });
      groups.add(
        _DupGroup(
          size: list.first.candidate.size,
          hash: list.first.hash,
          files: list,
        ),
      );
    }
    groups.sort((a, b) {
      final n = b.files.length.compareTo(a.files.length);
      if (n != 0) return n;
      return b.size.compareTo(a.size);
    });

    setState(() {
      _scanning = false;
      _groups = groups;
    });
  }

  void _toggleDelete(_DupFile file, bool selected) {
    if (_processing) return;
    setState(() => file.selected = selected);
  }

  void _cancel() {
    _cancelRequested = true;
    Navigator.of(context).pop(const <String>{});
  }

  Future<void> _process() async {
    final selected = <_DupFile>[];
    for (final g in _groups) {
      for (final f in g.files) {
        if (f.selected) selected.add(f);
      }
    }
    if (selected.isEmpty || _hasFullySelectedGroup) return;

    final count = selected.length;
    final bytes = _selectedBytes;

    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (c) => AlertDialog(
        insetPadding: _inset,
        titlePadding: _titlePad,
        contentPadding: _contentPad,
        actionsPadding: _actionsPad,
        title: const Text('确认删除？'),
        content: Text(
          '将永久删除 $count 个文件，释放 ${_fmtBytes(bytes)}。\n'
          '删除后无法恢复。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() {
      _processing = true;
      _processDone = 0;
      _processTotal = count;
    });

    final failures = <String>[];

    for (final f in selected) {
      final src = f.candidate.path;
      try {
        await File(src).delete();
        _removed.add(src);
        f.selected = false;
      } catch (e) {
        failures.add('$src：${_errText(e)}');
      } finally {
        if (mounted) setState(() => _processDone++);
      }
    }

    var freed = 0;
    for (final f in selected) {
      if (_removed.contains(f.candidate.path)) freed += f.candidate.size;
    }

    if (!mounted) return;
    setState(() {
      _processing = false;
      // 删完以后重新判断哪些组还剩下多余副本。
      _groups = _groups
          .map(
            (g) => _DupGroup(
              size: g.size,
              hash: g.hash,
              files: g.files
                  .where((f) => !_removed.contains(f.candidate.path))
                  .toList(),
            ),
          )
          .where((g) => g.files.length > 1)
          .toList();
    });
    await _showDone(freed, failures);
    if (!mounted) return;
    Navigator.of(context).pop(Set<String>.from(_removed));
  }

  Future<void> _showDone(int freedBytes, List<String> failures) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (c) => AlertDialog(
        insetPadding: _inset,
        titlePadding: _titlePad,
        contentPadding: _contentPad,
        actionsPadding: _actionsPad,
        title: const Text('完成'),
        content: SizedBox(
          width: double.maxFinite,
          height: MediaQuery.of(c).size.height * 0.5,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '已删除 ${_removed.length} 个文件，释放 ${_fmtBytes(freedBytes)}。',
                ),
                if (failures.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    '${failures.length} 个文件删除失败：',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  for (final f in failures)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        '· $f',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // 处理过程中不允许返回，否则文件已经动过、页面却拿不到结果。
      canPop: !_processing,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _cancelRequested = true;
      },
      child: AlertDialog(
        insetPadding: _inset,
        titlePadding: _titlePad,
        contentPadding: _contentPad,
        actionsPadding: _actionsPad,
        title: Text(_scanning ? '查找重复文件' : '重复文件'),
        content: SizedBox(
          width: double.maxFinite,
          height: MediaQuery.of(context).size.height * 0.72,
          child: _buildContent(),
        ),
        actions: _buildActions(),
      ),
    );
  }

  Widget _buildContent() {
    if (_scanning) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            const Text('正在查找重复文件…'),
            const SizedBox(height: 8),
            Text(
              '已检查 $_checked/$_total',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      );
    }

    if (_groups.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle_outline, size: 40),
            const SizedBox(height: 12),
            const Text('没有发现重复文件'),
            if (_skipped > 0) ...[
              const SizedBox(height: 8),
              Text(
                '已跳过 $_skipped 个文件（超过 100MB / 无法读取 / 符号链接）',
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      );
    }

    final s = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '发现 ${_groups.length} 组重复文件',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 2),
              Text(
                '共 $_dupFileCount 个文件完全相同（大小 + MD5 一致）',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (_skipped > 0)
                Text(
                  '已跳过 $_skipped 个文件（超过 100MB / 无法读取 / 符号链接）',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Expanded(
          child: ListView.builder(
            itemCount: _groups.length,
            itemBuilder: (ctx, i) => _buildGroupCard(i),
          ),
        ),
        const Divider(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _selectedCount == 0
                    ? '勾选要删除的文件，未勾选的不受影响'
                    : '已选 $_selectedCount 个 · 释放 ${_fmtBytes(_selectedBytes)}',
                style: TextStyle(
                  fontSize: 12,
                  color: s.onSurface.withValues(alpha: 0.7),
                ),
              ),
              if (_compareMarks.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    _compareMarks.length == 2
                        ? '已标记 2 个用于对比'
                        : '已标记 1 个用于对比，再标记 1 个',
                    style: TextStyle(fontSize: 12, color: s.primary),
                  ),
                ),
              if (_hasFullySelectedGroup)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    '每一组至少要保留 1 个文件',
                    style: TextStyle(fontSize: 12, color: s.error),
                  ),
                ),
              if (_processing) ...[
                const SizedBox(height: 6),
                LinearProgressIndicator(
                  value: _processTotal == 0
                      ? null
                      : _processDone / _processTotal,
                ),
                const SizedBox(height: 2),
                Text(
                  '正在删除 $_processDone/$_processTotal',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  List<Widget> _buildActions() {
    if (_scanning) {
      return [
        TextButton(onPressed: _cancel, child: const Text('取消')),
      ];
    }
    final canDelete = !_processing &&
        _selectedCount > 0 &&
        !_hasFullySelectedGroup;
    return [
      TextButton(
        onPressed: _processing
            ? null
            : () => Navigator.of(context).pop(const <String>{}),
        child: const Text('取消'),
      ),
      TextButton.icon(
        onPressed:
            !_processing && _compareMarks.length == 2 ? _openCompare : null,
        icon: const Icon(Icons.compare_arrows, size: 16),
        label: const Text('对比'),
      ),
      FilledButton(
        onPressed: canDelete ? _process : null,
        child: const Text('删除所选…'),
      ),
    ];
  }

  Widget _buildGroupCard(int index) {
    final group = _groups[index];
    final s = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
      decoration: BoxDecoration(
        border: Border.all(color: s.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: s.surfaceContainerHighest,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(7)),
            ),
            child: Text(
              '组 ${index + 1} · ${group.files.length} 份 · '
              '${_fmtBytes(group.size)} · MD5 ${group.hash}',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
          for (final f in group.files) _buildFileRow(f),
        ],
      ),
    );
  }

  Widget _buildFileRow(_DupFile file) {
    final s = Theme.of(context).colorScheme;
    return InkWell(
      onTap: _processing ? null : () => _toggleDelete(file, !file.selected),
      child: Padding(
        padding: const EdgeInsets.only(left: 2, right: 2, top: 1, bottom: 1),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Checkbox(
              value: file.selected,
              visualDensity: VisualDensity.compact,
              onChanged:
                  _processing ? null : (v) => _toggleDelete(file, v ?? false),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Text(
                  file.candidate.path,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: IconButton(
                iconSize: 20,
                tooltip: file.markedForCompare ? '取消对比标记' : '标记对比',
                color: file.markedForCompare ? s.primary : null,
                visualDensity: VisualDensity.compact,
                onPressed:
                    _processing ? null : () => _toggleCompareMark(file),
                icon: Icon(
                  file.markedForCompare
                      ? Icons.radio_button_checked
                      : Icons.compare_arrows,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
