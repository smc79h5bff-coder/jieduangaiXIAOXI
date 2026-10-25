import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../import/presentation/providers/import_providers.dart';
import '../../preprocessing/application/aho_corasick.dart';
import 'line_list_page.dart';

// ==================== 常量（与旧编辑器保持一致） ====================

const double _kFontSize = 14.0;
const double _kLineHeight = 22.0;
const double _kEditorVPad = 9.0;

const double _kBlockSize = 36.0;
const double _kBlockOffset = 37.0;
const double _kBlockAreaWidth = 76.0;

const double _kGutterWidth = 45.0;

/// 正文最多横向显示 3 屏，超出的文字直接裁掉、禁止再滚。
/// 想改“能滚几屏”，改这个数字即可。
const int _kMaxViewportScreens = 3;

const Color _kSelectedBg = Color(0xFFDCFFFF);
const Color _kCheckColor = Color(0xFF00ABFF);
const Color _kLineNumSelected = Color(0xFF007DFF);
const Color _kLineNumNormal = Color(0xFF9E9E9E);
const Color _kBlockBgNormal = Color(0xFFEDEDED);
const Color _kBlockBorderNormal = Color(0xFFBDBDBD);
const Color _kBlockTextNormal = Color(0xFF424242);
const Color _kConnectorColor = Color(0xFFBDBDBD);

// ==================== 页面 ====================

/// 逐行编辑器：每一行是一个独立的单行输入框。
///
/// 因为每行高度固定、永远不会折行，行号 / 方块 / 高亮不会错位。
/// 长行只横向滚到 3 屏为止，后面的内容裁掉不再显示（内容本身不丢，
/// 删除时仍按完整行匹配）。
class LineByLineEditorPage extends ConsumerStatefulWidget {
  const LineByLineEditorPage({super.key});

  @override
  ConsumerState<LineByLineEditorPage> createState() =>
      _LineByLineEditorPageState();
}

class _LineByLineEditorPageState extends ConsumerState<LineByLineEditorPage> {
  late List<String> _lines;

  final Set<int> _selectedLines = <int>{};
  int? _anchorLine;

  // 只保留一个“正在编辑的行”，避免几千个 controller 同时存在。
  final TextEditingController _activeCtrl = TextEditingController();
  final FocusNode _activeFocus = FocusNode();
  int? _activeLine;
  bool _editMode = false;

  late final ScrollController _vertCtrl;

  Timer? _syncTimer;
  Timer? _shrinkTimer;
  Timer? _backspaceRepeatTimer;

  double _scale = 1.0;
  double _contentWidth = 0.0;
  bool _widthReady = false;

  double get _rowHeight => _kLineHeight * _scale;
  double get _vpad => _kEditorVPad * _scale;
  int get _lineCount => _lines.length;

  @override
  void initState() {
    super.initState();
    final text = ref.read(lineListTextProvider);
    _lines = text.split('\n');
    if (_lines.isEmpty) _lines = <String>[''];
    _vertCtrl = ScrollController()..addListener(_onScroll);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final s = MediaQuery.textScalerOf(context).scale(_kFontSize) / _kFontSize;
    if (!_widthReady || s != _scale) {
      _scale = s;
      _widthReady = true;
      _recalcMaxWidth();
    }
  }

  @override
  void deactivate() {
    _syncNow();
    super.deactivate();
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    _shrinkTimer?.cancel();
    _backspaceRepeatTimer?.cancel();
    _vertCtrl.removeListener(_onScroll);
    _vertCtrl.dispose();
    _activeFocus.dispose();
    _activeCtrl.dispose();
    super.dispose();
  }

  // ==================== 数据同步 ====================

  void _scheduleSync() {
    _syncTimer?.cancel();
    _syncTimer = Timer(const Duration(milliseconds: 300), _syncNow);
  }

  void _syncNow() {
    _syncTimer?.cancel();
    ref.read(lineListTextProvider.notifier).state = _lines.join('\n');
  }

  /// 只保存当前正在编辑那一行，不改 index。
  void _saveActiveText() {
    final i = _activeLine;
    if (i == null || i < 0 || i >= _lines.length) return;
    _lines[i] = _activeCtrl.text;
    final w = _estimateLineWidth(_lines[i]);
    if (w > _contentWidth) _contentWidth = w;
  }

  // ==================== 宽度估算 ====================

  double _estimateLineWidth(String line) {
    if (line.isEmpty) return 0.0;
    final halfW = 0.62 * _kFontSize * _scale;
    final wideW = 1.05 * _kFontSize * _scale;
    final tabW = 8 * halfW;

    // 超长行只算前 3000 个字，剩下按全角外推，避免逐字循环卡顿。
    // 宽度到上限就直接返回，不再往下算（反正 3 屏以外会被裁掉）。
    const maxChars = 3000;
    const widthCap = 12000.0;
    var w = 0.0;
    var count = 0;
    for (final r in line.runes) {
      if (r == 0x09) {
        w += tabW;
      } else if (r >= 0x20 && r <= 0x7E) {
        w += halfW;
      } else {
        w += wideW;
      }
      count++;
      if (w >= widthCap) return widthCap;
      if (count >= maxChars) {
        return w * (line.runes.length / count);
      }
    }
    return w;
  }

  void _recalcMaxWidth() {
    var maxW = 0.0;
    for (final line in _lines) {
      final w = _estimateLineWidth(line);
      if (w > maxW) maxW = w;
    }
    _contentWidth = maxW;
  }

  void _scheduleShrink() {
    _shrinkTimer?.cancel();
    _shrinkTimer = Timer(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      var maxW = 0.0;
      for (final line in _lines) {
        final w = _estimateLineWidth(line);
        if (w > maxW) maxW = w;
      }
      if (maxW + 1 < _contentWidth) {
        setState(() => _contentWidth = maxW);
      }
    });
  }

  // ==================== 行选择 ====================

  void _toggleLine(int i) {
    setState(() {
      if (_selectedLines.contains(i)) {
        _selectedLines.remove(i);
      } else {
        _selectedLines.add(i);
      }
      _anchorLine = i;
    });
  }

  void _rangeSelect(int i) {
    if (_selectedLines.isEmpty) {
      setState(() {
        _selectedLines.add(i);
        _anchorLine = i;
      });
      return;
    }
    final minSel = _selectedLines.reduce((a, b) => a < b ? a : b);
    final maxSel = _selectedLines.reduce((a, b) => a > b ? a : b);

    int lo;
    int hi;
    if (i > maxSel) {
      lo = minSel;
      hi = i;
    } else if (i < minSel) {
      lo = i;
      hi = maxSel;
    } else {
      return;
    }

    setState(() {
      for (var k = lo; k <= hi; k++) {
        _selectedLines.add(k);
      }
      _anchorLine = i;
    });
  }

  void _selectAll() {
    setState(() {
      _selectedLines.clear();
      for (var i = 0; i < _lineCount; i++) {
        _selectedLines.add(i);
      }
      _anchorLine = 0;
    });
  }

  void _exitSelection() {
    setState(() {
      _selectedLines.clear();
      _anchorLine = null;
    });
  }

  void _selectLongLines(int minLen) {
    setState(() {
      _selectedLines.clear();
      _anchorLine = null;
      for (var i = 0; i < _lines.length; i++) {
        if (_lines[i].runes.length > minLen) {
          _selectedLines.add(i);
        }
      }
    });
  }

  Future<void> _promptMinLen() async {
    final ctrl = TextEditingController(
      text: ref.read(lineListMinLenProvider).toString(),
    );
    final result = await showDialog<int>(
      context: context,
      builder: (c) => AlertDialog(
        insetPadding: const EdgeInsets.all(24),
        title: const Text('字数阈值', style: TextStyle(fontSize: 15)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(
            labelText: '选大于多少字的行',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          onSubmitted: (v) {
            final n = int.tryParse(v.trim());
            if (n != null && n >= 0) Navigator.pop(c, n);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final n = int.tryParse(ctrl.text.trim());
              if (n != null && n >= 0) Navigator.pop(c, n);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (result == null || !mounted) return;
    ref.read(lineListMinLenProvider.notifier).state = result;
    _selectLongLines(result);
  }

  // ==================== 编辑模式 ====================

  void _toggleEditMode() {
    if (_editMode) {
      _deactivate();
      setState(() => _editMode = false);
    } else {
      setState(() => _editMode = true);
    }
  }

  void _activate(int i) {
    if (!_editMode || i < 0 || i >= _lines.length) return;
    if (_activeLine == i) {
      // 同一行：如果键盘已经收起来，再点一次就重新聚焦。
      if (!_activeFocus.hasFocus) _activeFocus.requestFocus();
      return;
    }
    // 输入法还在组合（拼音没上屏）时不要切换，避免丢字。
    if (_activeCtrl.value.composing.isValid) return;

    _saveActiveText();
    setState(() {
      _activeLine = i;
      _activeCtrl.value = TextEditingValue(
        text: _lines[i],
        selection: TextSelection.collapsed(offset: _lines[i].length),
      );
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _activeLine == i) _activeFocus.requestFocus();
    });
  }

  void _deactivate() {
    final i = _activeLine;
    if (i == null) return;
    _saveActiveText();
    _activeLine = null;
    _activeFocus.unfocus();
    if (mounted) setState(() {});
    _scheduleSync();
  }

  void _onActiveChanged(String raw) {
    final i = _activeLine;
    if (i == null || i < 0 || i >= _lines.length) return;

    // 单行输入框被粘贴多行时，自动拆成多行。
    if (raw.contains('\n')) {
      final parts = raw.split('\n');
      final newIndex = i + parts.length - 1;
      setState(() {
        _lines[i] = parts.first;
        _lines.insertAll(i + 1, parts.skip(1));
        _selectedLines.clear();
        _anchorLine = null;
        _activeLine = newIndex;
        _activeCtrl.value = TextEditingValue(
          text: parts.last,
          selection: TextSelection.collapsed(offset: parts.last.length),
        );
      });
      _syncNow();
      _scrollToLine(newIndex);
      return;
    }

    _lines[i] = raw;
    final w = _estimateLineWidth(raw);
    if (w > _contentWidth + 1) {
      setState(() => _contentWidth = w);
    } else if (w + 1 < _contentWidth) {
      _scheduleShrink();
    }
    _scheduleSync();
  }

  /// 回车：在光标处把当前行拆成两行，光标落到新行行首。
  void _splitActiveLine() {
    final i = _activeLine;
    if (i == null || i >= _lines.length) return;
    if (_activeCtrl.value.composing.isValid) return;

    final text = _activeCtrl.text;
    final sel = _activeCtrl.selection;
    final rawStart = sel.isValid ? sel.start : text.length;
    final start = rawStart < 0
        ? 0
        : (rawStart > text.length ? text.length : rawStart);
    final rawEnd = sel.isValid && !sel.isCollapsed ? sel.end : start;
    final end =
        rawEnd < 0 ? 0 : (rawEnd > text.length ? text.length : rawEnd);
    final left = text.substring(0, start);
    final right = text.substring(end);

    final newIndex = i + 1;
    setState(() {
      _lines[i] = left;
      _lines.insert(newIndex, right);
      _selectedLines.clear();
      _anchorLine = null;
      _activeLine = newIndex;
      _activeCtrl.value = TextEditingValue(
        text: right,
        selection: const TextSelection.collapsed(offset: 0),
      );
    });
    _syncNow();
    _scrollToLine(newIndex);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _activeLine == newIndex) _activeFocus.requestFocus();
    });
  }

  void _scrollToLine(int i) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_vertCtrl.hasClients) return;
      final target = _vpad + i * _rowHeight - _rowHeight * 2;
      final max = _vertCtrl.position.maxScrollExtent;
      _vertCtrl.jumpTo(target < 0 ? 0.0 : (target > max ? max : target));
    });
  }

  // ==================== 退格 ====================

  /// 退格：删除选中；否则删光标前一个字符；光标在行首时合并到上一行。
  void _backspaceActive() {
    final i = _activeLine;
    if (i == null || i >= _lines.length) {
      _toast('先点一行，再按退格');
      return;
    }
    if (_activeCtrl.value.composing.isValid) return;

    final text = _activeCtrl.text;
    final sel = _activeCtrl.selection;

    if (sel.isValid && !sel.isCollapsed) {
      var start = sel.start;
      var end = sel.end;
      if (start < 0) start = 0;
      if (start > text.length) start = text.length;
      if (end < 0) end = 0;
      if (end > text.length) end = text.length;
      final newText = text.replaceRange(start, end, '');
      _lines[i] = newText;
      _activeCtrl.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: start),
      );
      _scheduleSync();
      return;
    }

    var offset = sel.isValid ? sel.baseOffset : text.length;
    if (offset < 0) offset = 0;
    if (offset > text.length) offset = text.length;
    if (offset > 0) {
      var startOffset = offset - 1;
      // surrogate pair（emoji 等）
      if (startOffset > 0) {
        final code = text.codeUnitAt(startOffset);
        if (code >= 0xDC00 && code <= 0xDFFF) {
          final prev = text.codeUnitAt(startOffset - 1);
          if (prev >= 0xD800 && prev <= 0xDBFF) startOffset -= 1;
        }
      }
      final newText = text.replaceRange(startOffset, offset, '');
      _lines[i] = newText;
      _activeCtrl.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: startOffset),
      );
      _scheduleSync();
      return;
    }

    // 行首退格：合并到上一行，光标停在原来的行尾。
    if (i > 0) {
      final prev = _lines[i - 1];
      final merged = prev + text;
      final caret = prev.length;
      setState(() {
        _lines[i - 1] = merged;
        _lines.removeAt(i);
        _selectedLines.clear();
        _anchorLine = null;
        _activeLine = i - 1;
        _activeCtrl.value = TextEditingValue(
          text: merged,
          selection: TextSelection.collapsed(offset: caret),
        );
      });
      _syncNow();
      _scrollToLine(i - 1);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _activeLine == i - 1) _activeFocus.requestFocus();
      });
    }
  }

  void _startRepeatBackspace() {
    _backspaceActive();
    _backspaceRepeatTimer?.cancel();
    _backspaceRepeatTimer = Timer(const Duration(milliseconds: 400), () {
      _backspaceRepeatTimer =
          Timer.periodic(const Duration(milliseconds: 50), (_) {
        if (!mounted) return;
        _backspaceActive();
      });
    });
  }

  void _stopRepeatBackspace() {
    _backspaceRepeatTimer?.cancel();
    _backspaceRepeatTimer = null;
  }

  // ==================== 工具条操作 ====================

  Future<void> _copySelected() async {
    if (_selectedLines.isEmpty) return;
    final sorted = _selectedLines.toList()..sort();
    final text = sorted
        .where((i) => i >= 0 && i < _lines.length)
        .map((i) => _lines[i])
        .join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已复制 ${sorted.length} 行')),
    );
  }

  Future<void> _copyAll() async {
    _saveActiveText();
    await Clipboard.setData(ClipboardData(text: _lines.join('\n')));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已复制全部 ${_lineCount} 行')),
    );
  }

  void _deleteSelected() {
    if (_selectedLines.isEmpty) return;
    _saveActiveText();
    final remove = _selectedLines.toSet();
    final remaining = <String>[];
    for (var i = 0; i < _lines.length; i++) {
      if (!remove.contains(i)) remaining.add(_lines[i]);
    }
    if (remaining.isEmpty) remaining.add('');
    setState(() {
      _lines = remaining;
      _selectedLines.clear();
      _anchorLine = null;
      if (_activeLine != null) {
        _activeLine = null;
        _activeFocus.unfocus();
      }
    });
    _syncNow();
    _clampVerticalScroll();
  }

  void _clampVerticalScroll() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_vertCtrl.hasClients) return;
      final max = _vertCtrl.position.maxScrollExtent;
      if (_vertCtrl.offset > max) _vertCtrl.jumpTo(max);
    });
  }

  // ==================== 应用 ====================

  void _apply(String side) {
    _saveActiveText();
    final entries = _lines.where((l) => l.isNotEmpty).toList();
    if (entries.isEmpty) {
      _toast('列表里没有可删除的内容');
      return;
    }

    var totalHits = 0;

    if (side == 'left' || side == 'both') {
      final cur = ref.read(preprocessedOriginalProvider);
      if (cur.isNotEmpty) {
        final result = _removeAll(cur, entries);
        totalHits += result.hits;
        if (result.hits > 0) {
          ref.read(editedOriginalProvider.notifier).state = result.text;
        }
      }
    }
    if (side == 'right' || side == 'both') {
      final cur = ref.read(preprocessedModifiedProvider);
      if (cur.isNotEmpty) {
        final result = _removeAll(cur, entries);
        totalHits += result.hits;
        if (result.hits > 0) {
          ref.read(editedModifiedProvider.notifier).state = result.text;
        }
      }
    }

    if (totalHits == 0) {
      _toast('文本里没有出现这些字符串');
      return;
    }

    ref.read(importRevisionProvider.notifier).state++;
    _syncNow();

    if (!mounted) return;
    Navigator.of(context).pop();
  }

  ({String text, int hits}) _removeAll(String text, List<String> entries) {
    if (text.isEmpty || entries.isEmpty) {
      return (text: text, hits: 0);
    }

    final cleaned = entries.where((e) => e.isNotEmpty).toList();
    if (cleaned.isEmpty) return (text: text, hits: 0);

    cleaned.sort((a, b) => b.length.compareTo(a.length));

    final ac = AhoCorasick(
      patterns: cleaned,
      replacements: List<String>.filled(cleaned.length, ''),
      priorities: List<int>.generate(cleaned.length, (i) => i),
    );

    var hits = 0;
    ac.findAllMatches(text, (_, __, ___) {
      hits++;
    });

    return (text: ac.replaceAll(text), hits: hits);
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg)),
    );
  }

  // ==================== UI ====================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: LayoutBuilder(
                builder: (context, box) => _buildEditorArea(box.maxHeight),
              ),
            ),
            _buildToolbar(),
          ],
        ),
      ),
    );
  }

  Widget _buildEditorArea(double maxHeight) {
    final offset = _vertCtrl.hasClients ? _vertCtrl.offset : 0.0;
    return Container(
      margin: const EdgeInsets.fromLTRB(1, 6, 1, 0),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildBlockArea(maxHeight, offset),
          _buildGutter(maxHeight, offset),
          Container(width: 1, color: Colors.grey.shade300),
          Expanded(child: _buildTextColumn(maxHeight)),
        ],
      ),
    );
  }

  int _firstVisible(double offset) {
    final n = ((offset - _vpad) / _rowHeight).floor();
    if (n < 0) return 0;
    if (n > _lineCount - 1) return _lineCount - 1;
    return n;
  }

  int _lastVisible(double offset, double maxHeight) {
    final n = ((offset + maxHeight - _vpad) / _rowHeight).ceil();
    if (n < 0) return 0;
    if (n > _lineCount - 1) return _lineCount - 1;
    return n;
  }

  Widget _buildBlockArea(double maxHeight, double scrollOffset) {
    final first = _firstVisible(scrollOffset);
    final last = _lastVisible(scrollOffset, maxHeight);
    return SizedBox(
      width: _kBlockAreaWidth,
      child: ClipRect(
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            CustomPaint(
              size: Size(_kBlockAreaWidth, maxHeight),
              painter: _RowConnectorPainter(
                first: first,
                last: last,
                rowHeight: _rowHeight,
                vpad: _vpad,
                scrollOffset: scrollOffset,
                selectedLines: _selectedLines,
              ),
            ),
            for (var i = first; i <= last; i++)
              _buildBlock(i, maxHeight, scrollOffset),
          ],
        ),
      ),
    );
  }

  Widget _buildBlock(int i, double maxHeight, double scrollOffset) {
    final top =
        _vpad + i * _rowHeight + _rowHeight / 2 - _kBlockSize / 2 - scrollOffset;
    if (top + _kBlockSize < 0 || top > maxHeight) {
      return const SizedBox.shrink();
    }

    final left = i.isEven ? 0.0 : _kBlockOffset;
    final selected = _selectedLines.contains(i);

    return Positioned(
      left: left,
      top: top,
      width: _kBlockSize,
      height: _kBlockSize,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _toggleLine(i),
        onLongPress: () => _rangeSelect(i),
        child: Container(
          decoration: BoxDecoration(
            color: selected ? _kCheckColor : _kBlockBgNormal,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: selected ? _kCheckColor : _kBlockBorderNormal,
              width: selected ? 2 : 1,
            ),
          ),
          alignment: Alignment.center,
          child: Text(
            '${i + 1}',
            style: TextStyle(
              fontSize: 12,
              fontFamily: 'monospace',
              fontWeight: FontWeight.bold,
              color: selected ? Colors.white : _kBlockTextNormal,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildGutter(double maxHeight, double scrollOffset) {
    final first = _firstVisible(scrollOffset);
    final last = _lastVisible(scrollOffset, maxHeight);
    return SizedBox(
      width: _kGutterWidth,
      child: ColoredBox(
        color: Colors.grey.shade50,
        child: ClipRect(
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              for (var i = first; i <= last; i++)
                _buildGutterRow(i, maxHeight, scrollOffset),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGutterRow(int i, double maxHeight, double scrollOffset) {
    final top = _vpad + i * _rowHeight - scrollOffset;
    if (top + _rowHeight < 0 || top > maxHeight) {
      return const SizedBox.shrink();
    }
    final selected = _selectedLines.contains(i);
    return Positioned(
      top: top,
      left: 0,
      right: 0,
      height: _rowHeight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _toggleLine(i),
        onLongPress: () => _rangeSelect(i),
        child: ColoredBox(
          color: selected ? _kSelectedBg : Colors.transparent,
          child: Padding(
            padding: const EdgeInsets.only(left: 0, right: 1),
            child: Row(
              children: [
                _buildCheckbox(selected),
                const SizedBox(width: 1),
                Expanded(
                  child: Text(
                    '${i + 1}',
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color:
                          selected ? _kLineNumSelected : _kLineNumNormal,
                      fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCheckbox(bool selected) {
    return SizedBox(
      width: 14,
      height: 14,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: selected ? _kCheckColor : Colors.transparent,
          border: Border.all(
            color: selected ? _kCheckColor : Colors.grey.shade400,
            width: 1.5,
          ),
          borderRadius: BorderRadius.circular(2),
        ),
        child: selected
            ? const Icon(Icons.check, size: 10, color: Colors.white)
            : null,
      ),
    );
  }

  // ---------- 逐行编辑区 ----------

  Widget _buildTextColumn(double maxHeight) {
    return LayoutBuilder(
      builder: (context, c) {
        final viewportW = c.maxWidth;
        final need = _contentWidth + 16;
        final hardMax = viewportW * _kMaxViewportScreens;
        final targetW =
            need < viewportW ? viewportW : (need > hardMax ? hardMax : need);

        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: targetW,
            height: maxHeight,
            child: ListView.builder(
              controller: _vertCtrl,
              padding: EdgeInsets.only(top: _vpad),
              itemExtent: _rowHeight,
              itemCount: _lineCount,
              itemBuilder: (context, i) => _buildTextRow(i),
            ),
          ),
        );
      },
    );
  }

  Widget _buildTextRow(int i) {
    final selected = _selectedLines.contains(i);
    final isActive = _editMode && _activeLine == i;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (_editMode) {
          _activate(i);
        } else {
          _toggleLine(i);
        }
      },
      onLongPress: () => _rangeSelect(i),
      child: Container(
        color: selected ? _kSelectedBg : Colors.transparent,
        padding: const EdgeInsets.only(left: 1, right: 4),
        alignment: Alignment.centerLeft,
        child: isActive ? _buildActiveField() : _buildPlainText(i),
      ),
    );
  }

  Widget _buildPlainText(int i) {
    return Text(
      _lines[i],
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.clip,
      style: TextStyle(
        fontSize: _kFontSize,
        fontFamily: 'monospace',
        height: _kLineHeight / _kFontSize,
      ),
    );
  }

  Widget _buildActiveField() {
    return SizedBox(
      height: _rowHeight,
      child: TextField(
        controller: _activeCtrl,
        focusNode: _activeFocus,
        maxLines: 1,
        style: const TextStyle(
          fontSize: _kFontSize,
          fontFamily: 'monospace',
        ),
        strutStyle: const StrutStyle(
          fontSize: _kFontSize,
          height: _kLineHeight / _kFontSize,
          forceStrutHeight: true,
        ),
        decoration: const InputDecoration(
          isDense: true,
          border: InputBorder.none,
          contentPadding: EdgeInsets.zero,
        ),
        textAlignVertical: TextAlignVertical.center,
        cursorWidth: 2.0,
        cursorColor: Colors.blue,
        textInputAction: TextInputAction.next,
        onChanged: _onActiveChanged,
        onSubmitted: (_) => _splitActiveLine(),
      ),
    );
  }

  void _onScroll() {
    if (mounted) setState(() {});
  }

  // ---------- 工具条（三排，无悬浮按钮） ----------

  Widget _buildToolbar() {
    final hasContent = _lines.any((l) => l.isNotEmpty);
    final hasSelection = _selectedLines.isNotEmpty;
    final minLen = ref.watch(lineListMinLenProvider);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: _toolBtn(
                icon: Icons.copy,
                label: '复制行',
                onTap: hasSelection ? _copySelected : null,
              ),
            ),
            Expanded(
              child: _toolBtn(
                icon: Icons.delete_outline,
                label: '删除行',
                onTap: hasSelection ? _deleteSelected : null,
              ),
            ),
            Expanded(
              child: _toolBtn(
                icon: Icons.select_all,
                label: '全选',
                onTap: hasContent ? _selectAll : null,
              ),
            ),
            Expanded(
              child: _toolBtn(
                icon: Icons.deselect,
                label: '退出选择',
                onTap: hasSelection ? _exitSelection : null,
              ),
            ),
          ],
        ),
        Row(
          children: [
            Expanded(
              child: _toolBtn(
                icon: Icons.west,
                label: '删除左侧',
                onTap: hasContent ? () => _apply('left') : null,
              ),
            ),
            Expanded(
              child: _toolBtn(
                icon: Icons.east,
                label: '删除右侧',
                onTap: hasContent ? () => _apply('right') : null,
              ),
            ),
            Expanded(
              child: _toolBtn(
                icon: Icons.compare_arrows,
                label: '两侧都删',
                onTap: hasContent ? () => _apply('both') : null,
              ),
            ),
            Expanded(
              child: _toolBtn(
                icon: Icons.straighten,
                label: '选>$minLen字的行',
                onTap: hasContent ? () => _selectLongLines(minLen) : null,
                onLongPress: hasContent ? _promptMinLen : null,
              ),
            ),
          ],
        ),
        Row(
          children: [
            Expanded(
              child: _toolBtn(
                icon: _editMode ? Icons.check : Icons.edit,
                label: _editMode ? '完成编辑' : '编辑',
                onTap: _toggleEditMode,
              ),
            ),
            Expanded(
              child: _toolBtn(
                icon: Icons.backspace_outlined,
                label: '退格',
                onTap: _editMode ? _backspaceActive : null,
                onLongPress: _editMode ? _startRepeatBackspace : null,
                onLongPressEnd: _stopRepeatBackspace,
              ),
            ),
            Expanded(
              child: _toolBtn(
                icon: Icons.content_copy,
                label: '复制全部',
                onTap: _copyAll,
              ),
            ),
            const Expanded(child: SizedBox.shrink()),
          ],
        ),
      ],
    );
  }

  Widget _toolBtn({
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
    VoidCallback? onLongPress,
    VoidCallback? onLongPressEnd,
  }) {
    final enabled = onTap != null || onLongPress != null;
    final s = Theme.of(context).colorScheme;
    final color = enabled ? s.onSurface : s.onSurface.withOpacity(0.3);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        onLongPressEnd: onLongPressEnd == null
            ? null
            : (_) => onLongPressEnd(),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.max,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 3),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: color,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ==================== 连接线 ====================

class _RowConnectorPainter extends CustomPainter {
  _RowConnectorPainter({
    required this.first,
    required this.last,
    required this.rowHeight,
    required this.vpad,
    required this.scrollOffset,
    required this.selectedLines,
  });

  final int first;
  final int last;
  final double rowHeight;
  final double vpad;
  final double scrollOffset;
  final Set<int> selectedLines;

  @override
  void paint(Canvas canvas, Size size) {
    final paintNormal = Paint()
      ..color = _kConnectorColor
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    final paintSelected = Paint()
      ..color = _kCheckColor
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;

    for (var i = first; i <= last; i++) {
      final centerY = vpad + i * rowHeight + rowHeight / 2 - scrollOffset;
      if (centerY < -20 || centerY > size.height + 20) continue;

      final blockLeft = i.isEven ? 0.0 : _kBlockOffset;
      final blockCenterX = blockLeft + _kBlockSize / 2;
      final selected = selectedLines.contains(i);

      canvas.drawLine(
        Offset(blockCenterX, centerY),
        Offset(size.width, centerY),
        selected ? paintSelected : paintNormal,
      );
    }
  }

  @override
  bool shouldRepaint(_RowConnectorPainter old) {
    if (old.first != first || old.last != last) return true;
    if (old.rowHeight != rowHeight) return true;
    if (old.vpad != vpad) return true;
    if (old.scrollOffset != scrollOffset) return true;
    if (old.selectedLines.length != selectedLines.length) return true;
    for (final i in selectedLines) {
      if (!old.selectedLines.contains(i)) return true;
    }
    return false;
  }
}
