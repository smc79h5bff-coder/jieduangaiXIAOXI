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

/// 行编辑器 3（绘制版）：正文仍是虚拟化列表，行号栏和方块改为在
/// 绘制阶段读取真实滚动偏移来画，所以永远不会和正文错位。
/// 这是独立的第三个编辑器，效果不满意可以直接删掉本文件。
class LinePainterEditorPage extends ConsumerStatefulWidget {
  const LinePainterEditorPage({super.key});

  @override
  ConsumerState<LinePainterEditorPage> createState() =>
      _LinePainterEditorPageState();
}

class _LinePainterEditorPageState extends ConsumerState<LinePainterEditorPage> {
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
    _vertCtrl = ScrollController();
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
      final pos = _vertCtrl.position;
      final lineTop = _vpad + i * _rowHeight;
      final lineBottom = lineTop + _rowHeight;
      final viewTop = pos.pixels;
      final viewBottom = pos.pixels + pos.viewportDimension;
      // 目标行已经完整可见就完全不动，避免按回车时页面乱跳。
      if (lineTop >= viewTop && lineBottom <= viewBottom) return;
      final target = lineTop - _rowHeight * 2;
      final max = pos.maxScrollExtent;
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

  /// 工具栏「回车」：和软键盘回车一致——在光标处把当前行拆成两行。
  /// 没有激活行时，在末尾新增一空行并进入编辑模式。
  void _enterKey() {
    if (_activeLine != null) {
      _splitActiveLine();
      return;
    }
    final newIndex = _lines.length;
    setState(() {
      _lines.add('');
      _editMode = true;
      _activeLine = newIndex;
      _selectedLines.clear();
      _anchorLine = null;
      _activeCtrl.value = const TextEditingValue(
        text: '',
        selection: TextSelection.collapsed(offset: 0),
      );
    });
    _syncNow();
    _scrollToLine(newIndex);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _activeLine == newIndex) _activeFocus.requestFocus();
    });
  }

  void _closePage() {
    _saveActiveText();
    _syncNow();
    Navigator.of(context).pop();
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
    return Container(
      margin: const EdgeInsets.fromLTRB(1, 6, 1, 0),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 方块栏：绘制阶段读真实滚动偏移，永不错位。
          SizedBox(
            width: _kBlockAreaWidth,
            child: ClipRect(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: (d) => _onBlockTap(d.localPosition),
                onLongPressStart: (d) => _onBlockLongPress(d.localPosition),
                child: CustomPaint(
                  painter: _BlockLayerPainter(
                    repaint: _vertCtrl,
                    offsetGetter: _verticalOffset,
                    lineCount: _lineCount,
                    rowHeight: _rowHeight,
                    vpad: _vpad,
                    scale: _scale,
                    selectedLines: _selectedLines,
                  ),
                ),
              ),
            ),
          ),
          // 行号栏：同上，绘制阶段读偏移。
          SizedBox(
            width: _kGutterWidth,
            child: ColoredBox(
              color: Colors.grey.shade50,
              child: ClipRect(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (d) => _onGutterTap(d.localPosition),
                  onLongPressStart: (d) => _onGutterLongPress(d.localPosition),
                  child: CustomPaint(
                    painter: _GutterLayerPainter(
                      repaint: _vertCtrl,
                      offsetGetter: _verticalOffset,
                      lineCount: _lineCount,
                      rowHeight: _rowHeight,
                      vpad: _vpad,
                      scale: _scale,
                      selectedLines: _selectedLines,
                    ),
                  ),
                ),
              ),
            ),
          ),
          Container(width: 1, color: Colors.grey.shade300),
          Expanded(child: _buildTextColumn(maxHeight)),
        ],
      ),
    );
  }

  /// 真实滚动偏移：绘制/点击时调用，拿到的一定是布局夹紧后的值。
  double _verticalOffset() =>
      _vertCtrl.hasClients ? _vertCtrl.offset : 0.0;

  int? _lineAtY(double localY) {
    final offset = _verticalOffset();
    final n = ((localY + offset - _vpad) / _rowHeight).floor();
    if (n < 0 || n > _lineCount - 1) return null;
    return n;
  }

  void _onBlockTap(Offset p) {
    final i = _lineAtY(p.dy);
    if (i == null) return;
    final left = i.isEven ? 0.0 : _kBlockOffset;
    if (p.dx < left || p.dx > left + _kBlockSize) return;
    _toggleLine(i);
  }

  void _onBlockLongPress(Offset p) {
    final i = _lineAtY(p.dy);
    if (i == null) return;
    final left = i.isEven ? 0.0 : _kBlockOffset;
    if (p.dx < left || p.dx > left + _kBlockSize) return;
    _rangeSelect(i);
  }

  void _onGutterTap(Offset p) {
    final i = _lineAtY(p.dy);
    if (i != null) _toggleLine(i);
  }

  void _onGutterLongPress(Offset p) {
    final i = _lineAtY(p.dy);
    if (i != null) _rangeSelect(i);
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
                icon: Icons.keyboard_return,
                label: '回车',
                onTap: _enterKey,
              ),
            ),
            Expanded(
              child: _toolBtn(
                icon: Icons.close,
                label: '关闭',
                onTap: _closePage,
                colorOverride: Colors.red,
              ),
            ),
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
    Color? colorOverride,
  }) {
    final enabled = onTap != null || onLongPress != null;
    final s = Theme.of(context).colorScheme;
    final color = colorOverride ??
        (enabled ? s.onSurface : s.onSurface.withOpacity(0.3));
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPress: onLongPress,
      onLongPressEnd:
          onLongPressEnd == null ? null : (_) => onLongPressEnd(),
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
    );
  }
}

// ==================== 绘制层 ====================
//
// 这两层在 paint() 里才读取滚动偏移。paint 发生在 layout 之后，
// 所以拿到的永远是布局夹紧后的真实值，和正文不可能错位。

/// 计算当前可见的行号区间。
int _firstVisibleLine(double offset, double vpad, double rowHeight) {
  final n = ((offset - vpad) / rowHeight).floor();
  return n < 0 ? 0 : n;
}

int _lastVisibleLine(
  double offset,
  double sizeHeight,
  double vpad,
  double rowHeight,
  int lineCount,
) {
  final n = ((offset + sizeHeight - vpad) / rowHeight).ceil();
  return n > lineCount - 1 ? lineCount - 1 : n;
}

class _BlockLayerPainter extends CustomPainter {
  _BlockLayerPainter({
    required Listenable repaint,
    required this.offsetGetter,
    required this.lineCount,
    required this.rowHeight,
    required this.vpad,
    required this.scale,
    required this.selectedLines,
  }) : super(repaint: repaint);

  final double Function() offsetGetter;
  final int lineCount;
  final double rowHeight;
  final double vpad;
  final double scale;
  final Set<int> selectedLines;

  @override
  void paint(Canvas canvas, Size size) {
    if (lineCount <= 0 || size.height <= 0) return;
    final offset = offsetGetter();
    final first = _firstVisibleLine(offset, vpad, rowHeight);
    final last =
        _lastVisibleLine(offset, size.height, vpad, rowHeight, lineCount);

    final lineNormal = Paint()
      ..color = _kConnectorColor
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    final lineSelected = Paint()
      ..color = _kCheckColor
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;

    for (var i = first; i <= last; i++) {
      final top = vpad + i * rowHeight - offset;
      if (top + rowHeight <= 0 || top >= size.height) continue;
      final centerY = top + rowHeight / 2;
      final left = i.isEven ? 0.0 : _kBlockOffset;
      final selected = selectedLines.contains(i);

      canvas.drawLine(
        Offset(left + _kBlockSize / 2, centerY),
        Offset(size.width, centerY),
        selected ? lineSelected : lineNormal,
      );

      final rect = Rect.fromLTWH(
        left,
        centerY - _kBlockSize / 2,
        _kBlockSize,
        _kBlockSize,
      );
      final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(4));
      canvas.drawRRect(
        rrect,
        Paint()..color = selected ? _kCheckColor : _kBlockBgNormal,
      );
      canvas.drawRRect(
        rrect,
        Paint()
          ..color = selected ? _kCheckColor : _kBlockBorderNormal
          ..style = PaintingStyle.stroke
          ..strokeWidth = selected ? 2 : 1,
      );

      final tp = TextPainter(
        text: TextSpan(
          text: '${i + 1}',
          style: TextStyle(
            fontSize: 12 * scale,
            fontFamily: 'monospace',
            fontWeight: FontWeight.bold,
            color: selected ? Colors.white : _kBlockTextNormal,
            height: 1.0,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      // 自己算居中，不依赖 TextAlign，避免数字贴着方块左边缘。
      tp.paint(
        canvas,
        Offset(
          rect.center.dx - tp.width / 2,
          rect.top + (_kBlockSize - tp.height) / 2,
        ),
      );
    }
  }

  @override
  bool shouldRepaint(_BlockLayerPainter old) => true;
}

class _GutterLayerPainter extends CustomPainter {
  _GutterLayerPainter({
    required Listenable repaint,
    required this.offsetGetter,
    required this.lineCount,
    required this.rowHeight,
    required this.vpad,
    required this.scale,
    required this.selectedLines,
  }) : super(repaint: repaint);

  final double Function() offsetGetter;
  final int lineCount;
  final double rowHeight;
  final double vpad;
  final double scale;
  final Set<int> selectedLines;

  static const double _checkSize = 14.0;

  @override
  void paint(Canvas canvas, Size size) {
    if (lineCount <= 0 || size.height <= 0) return;
    final offset = offsetGetter();
    final first = _firstVisibleLine(offset, vpad, rowHeight);
    final last =
        _lastVisibleLine(offset, size.height, vpad, rowHeight, lineCount);

    for (var i = first; i <= last; i++) {
      final top = vpad + i * rowHeight - offset;
      if (top + rowHeight <= 0 || top >= size.height) continue;
      final selected = selectedLines.contains(i);

      if (selected) {
        canvas.drawRect(
          Rect.fromLTWH(0, top, size.width, rowHeight),
          Paint()..color = _kSelectedBg,
        );
      }

      final cbTop = top + (rowHeight - _checkSize) / 2;
      final cbRect = Rect.fromLTWH(0, cbTop, _checkSize, _checkSize);
      final cbRRect =
          RRect.fromRectAndRadius(cbRect, const Radius.circular(2));
      if (selected) {
        canvas.drawRRect(cbRRect, Paint()..color = _kCheckColor);
        final path = Path()
          ..moveTo(cbRect.left + 3.5, cbRect.top + 7)
          ..lineTo(cbRect.left + 6, cbRect.top + 9.5)
          ..lineTo(cbRect.left + 10.5, cbRect.top + 4.5);
        canvas.drawPath(
          path,
          Paint()
            ..color = Colors.white
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round,
        );
      } else {
        canvas.drawRRect(
          cbRRect,
          Paint()
            ..color = Colors.grey.shade400
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );
      }

      final leftPad = _checkSize + 1;
      final tp = TextPainter(
        text: TextSpan(
          text: '${i + 1}',
          style: TextStyle(
            fontSize: 11 * scale,
            fontFamily: 'monospace',
            color: selected ? _kLineNumSelected : _kLineNumNormal,
            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
            height: 1.0,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      // 右对齐到边长减 1，和旧编辑器的行号位置一致。
      final x = size.width - 1 - tp.width;
      tp.paint(
        canvas,
        Offset(
          x < leftPad ? leftPad : x,
          top + (rowHeight - tp.height) / 2,
        ),
      );
    }
  }

  @override
  bool shouldRepaint(_GutterLayerPainter old) => true;
}
