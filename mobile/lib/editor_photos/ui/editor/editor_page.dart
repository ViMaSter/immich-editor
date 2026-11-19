// The photo editor screen (port of public/edit/editor.js and the editor markup in
// src/views.js): top bar with close / versions / save, the stage with the rendered
// preview (or the crop UI), the rotation ruler and the tabbed panel.
import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:immich_mobile/editor_photos/data/editor_server.dart';
import 'package:immich_mobile/editor_photos/editor_session.dart';
import 'package:immich_mobile/editor_photos/model/advanced.dart';
import 'package:immich_mobile/editor_photos/model/auto.dart';
import 'package:immich_mobile/editor_photos/model/filters.dart';
import 'package:immich_mobile/editor_photos/model/geometry.dart';
import 'package:immich_mobile/editor_photos/model/recipe.dart';
import 'package:immich_mobile/editor_photos/ui/editor/crop_controller.dart';
import 'package:immich_mobile/editor_photos/ui/editor/crop_stage.dart';
import 'package:immich_mobile/editor_photos/ui/editor/editor_style.dart';
import 'package:immich_mobile/editor_photos/ui/editor/panels/adjust_panel.dart';
import 'package:immich_mobile/editor_photos/ui/editor/panels/advanced_panel.dart';
import 'package:immich_mobile/editor_photos/ui/editor/panels/crop_panel.dart';
import 'package:immich_mobile/editor_photos/ui/editor/panels/filters_panel.dart';
import 'package:immich_mobile/editor_photos/ui/editor/panels/suggestions_panel.dart';
import 'package:immich_mobile/editor_photos/ui/editor/panels/tools_panel.dart';
import 'package:immich_mobile/editor_photos/ui/editor/preview_stage.dart';
import 'package:immich_mobile/editor_photos/ui/editor/rotation_ruler.dart';
import 'package:immich_mobile/editor_photos/ui/editor/versions_dialog.dart';

enum EditorTab {
  suggestions('Suggestions', Icons.auto_awesome_outlined),
  crop('Crop', Icons.crop_rotate),
  tools('Tools', Icons.handyman_outlined),
  adjust('Adjust', Icons.tune),
  filters('Filters', Icons.photo_filter_outlined),
  advanced('Advanced', Icons.equalizer);

  const EditorTab(this.label, this.icon);

  final String label;
  final IconData icon;
}

/// Pixels of a filter thumbnail render
const filterThumbnailPixels = 220.0 * 160;

class EditorPhotosPage extends StatefulWidget {
  const EditorPhotosPage({super.key, required this.session});

  /// An opened session; the page disposes it. Pops with the `SaveResult` after a save.
  final EditorSession session;

  @override
  State<EditorPhotosPage> createState() => _EditorPhotosPageState();
}

class _Disposed implements Exception {
  const _Disposed();
}

class _EditorPhotosPageState extends State<EditorPhotosPage> {
  EditorSession get _session => widget.session;

  /// What the photo shows now (dirty compares against it); a suggestion counts as unsaved
  late final Recipe _initial;
  late Recipe _recipe;
  bool _dirty = false;
  late EditorTab _tab;
  ThemeData? _theme;

  // Previews: full render for most tabs, tone-only (no geometry) for the crop tab
  ui.Image? _result;
  ui.Image? _tone;
  String? _resultKey;
  String? _toneKey;
  bool _rendering = false;
  bool _renderAgain = false;

  /// All GPU work runs one job at a time (the renderer caches per-recipe textures)
  Future<void> _gpuQueue = Future<void>.value();
  bool _disposed = false;

  CropController? _crop;

  Future<ToolMasks?>? _masksFuture;
  bool _masksDone = false;
  Object? _masksError;

  final Map<String, ui.Image> _thumbnails = {};
  String? _thumbnailsKey;
  int _thumbnailsGeneration = 0;

  final _advancedUi = AdvancedUiState();

  bool _saving = false;
  String _savingText = 'Saving…';
  double? _savingProgress;

  String? _status;
  Timer? _statusTimer;

  @override
  void initState() {
    super.initState();
    final edit = _session.context!;
    _initial = edit.recipe.copy();
    _recipe = _session.initialRecipe();
    _dirty = !_recipe.equals(_initial);
    _tab = _session.suggestion != null || _session.assetSuggestions.isNotEmpty
        ? EditorTab.suggestions
        : EditorTab.adjust;
    if (!edit.editable) {
      _status = 'Only photos can be edited.';
    }
    if (_recipe.tools.any) {
      _ensureMasks();
    }
    unawaited(_requestRender());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _theme = editorTheme(Theme.of(context));
  }

  ThemeData get _editorTheme => _theme ??= editorTheme(Theme.of(context));

  @override
  void dispose() {
    _disposed = true;
    _statusTimer?.cancel();
    _thumbnailsGeneration++;
    _result?.dispose();
    _tone?.dispose();
    for (final image in _thumbnails.values) {
      image.dispose();
    }
    _thumbnails.clear();
    _crop?.dispose();
    // Release the session once nothing on the GPU uses its preview any more
    final session = _session;
    unawaited(_gpuQueue.whenComplete(session.dispose));
    super.dispose();
  }

  bool get _editable => _session.context?.editable ?? false;

  double get _proxyWidth => _session.preview!.image.width.toDouble();
  double get _proxyHeight => _session.preview!.image.height.toDouble();

  // ---- Rendering --------------------------------------------------------------------

  Future<T> _gpu<T>(Future<T> Function() job) {
    final result = _gpuQueue.then((_) {
      if (_disposed) {
        throw const _Disposed();
      }
      return job();
    });
    _gpuQueue = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  String _renderKey(Recipe recipe, bool tone) {
    final json = recipe.toJson();
    if (tone) {
      json.remove('geometry');
    }
    return '${jsonEncode(json)}|${_session.loadedMasks != null}';
  }

  /// Coalesces render requests: at most one in flight, the latest one wins
  Future<void> _requestRender() async {
    if (_rendering) {
      _renderAgain = true;
      return;
    }
    _rendering = true;
    try {
      do {
        _renderAgain = false;
        if (!mounted) {
          return;
        }
        final tone = _tab == EditorTab.crop;
        final snapshot = _recipe.copy();
        final key = _renderKey(snapshot, tone);
        if (tone ? key == _toneKey && _tone != null : key == _resultKey && _result != null) {
          continue;
        }
        final image = await _gpu(() => _session.render(snapshot, toneOnly: tone));
        if (!mounted) {
          image.dispose();
          return;
        }
        setState(() {
          if (tone) {
            _tone?.dispose();
            _tone = image;
            _toneKey = key;
          } else {
            _result?.dispose();
            _result = image;
            _resultKey = key;
          }
        });
      } while (_renderAgain);
    } on _Disposed {
      return;
    } catch (error) {
      if (mounted) {
        _showStatus('Preview failed: $error');
      }
    } finally {
      _rendering = false;
    }
  }

  /// The recipe changed in place
  void _changed({bool render = true}) {
    if (!mounted) {
      return;
    }
    setState(() => _dirty = !_recipe.equals(_initial));
    if (render) {
      unawaited(_requestRender());
    }
  }

  void _showStatus(String message) {
    _statusTimer?.cancel();
    setState(() => _status = message);
    _statusTimer = Timer(const Duration(seconds: 6), () {
      if (mounted) {
        setState(() => _status = null);
      }
    });
  }

  // ---- Masks and filter thumbnails ----------------------------------------------------

  /// Masks are analysed on the server the first time the tools are needed
  void _ensureMasks() {
    if (_session.server == null || (_masksFuture != null && _masksError == null)) {
      return;
    }
    final future = _session.masks();
    _masksFuture = future;
    _masksError = null;
    _masksDone = false;
    unawaited(
      future.then(
        (_) {
          if (!mounted || _masksFuture != future) {
            return;
          }
          setState(() => _masksDone = true);
          unawaited(_requestRender());
        },
        onError: (Object error) {
          if (!mounted || _masksFuture != future) {
            return;
          }
          setState(() {
            _masksDone = true;
            _masksError = error;
          });
        },
      ),
    );
  }

  /// Thumbnails show each filter at full strength on top of the current adjustments;
  /// they are kept until the rest of the recipe changes
  void _ensureThumbnails() {
    final base = _recipe.copy()
      ..filterId = 'none'
      ..filterStrength = 1;
    final key = '${base.encode()}|${_session.loadedMasks != null}';
    if (key == _thumbnailsKey) {
      return;
    }
    _thumbnailsKey = key;
    final generation = ++_thumbnailsGeneration;
    unawaited(_renderThumbnails(base, generation));
  }

  Future<void> _renderThumbnails(Recipe base, int generation) async {
    for (final id in filters.keys) {
      if (generation != _thumbnailsGeneration || !mounted) {
        return;
      }
      final recipe = base.copy()
        ..filterId = id
        ..filterStrength = 1;
      try {
        final image = await _gpu(() => _session.render(recipe, maxPixels: filterThumbnailPixels));
        if (generation != _thumbnailsGeneration || !mounted) {
          image.dispose();
          return;
        }
        setState(() {
          _thumbnails.remove(id)?.dispose();
          _thumbnails[id] = image;
        });
      } catch (_) {
        if (generation == _thumbnailsGeneration) {
          _thumbnailsKey = null;
        }
        return;
      }
    }
  }

  // ---- Tabs -------------------------------------------------------------------------

  List<EditorTab> get _tabs => [
    for (final tab in EditorTab.values)
      if (tab != EditorTab.tools || _session.server != null) tab,
  ];

  void _selectTab(EditorTab tab) {
    if (tab == _tab) {
      return;
    }
    final old = _crop;
    setState(() {
      _tab = tab;
      if (tab == EditorTab.crop) {
        _crop = CropController(
          geometry: _recipe.geometry,
          sourceWidth: _proxyWidth,
          sourceHeight: _proxyHeight,
          onCommit: _onCropCommit,
        );
      } else {
        _crop = null;
        // The tone-only render is only drawn by the crop tab
        _tone?.dispose();
        _tone = null;
        _toneKey = null;
      }
    });
    if (old != null) {
      // The crop stage unsubscribes while this frame builds
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    }
    if (tab == EditorTab.tools) {
      _ensureMasks();
    } else if (tab == EditorTab.filters) {
      _ensureThumbnails();
    }
    unawaited(_requestRender());
  }

  void _onCropCommit() => _changed(render: false);

  // ---- Edits ------------------------------------------------------------------------

  List<Suggestion> get _suggestions {
    final seen = <String>{};
    return [
      for (final s in [?_session.suggestion, ..._session.assetSuggestions])
        if (seen.add(s.id)) s,
    ];
  }

  void _applySuggestion(Suggestion suggestion) {
    // Saving now reports feedback for this suggestion (applied or tweaked)
    _session.suggestion = suggestion;
    _recipe = Recipe.fromJson(suggestion.recipe);
    if (_recipe.tools.any) {
      _ensureMasks();
    }
    _changed();
  }

  /// Like Google: a suggestion replaces the tone settings but keeps crop and filter
  void _applyAuto(AutoRecipe auto) {
    for (final key in adjustKeys) {
      _recipe.adjust[key] = auto.adjust[key] ?? 0;
    }
    _changed();
  }

  void _selectFilter(String id) {
    if (_recipe.filterId != id) {
      _recipe.filterId = id;
      _recipe.filterStrength = 1;
    }
    _changed();
  }

  /// In the Tools tab a tap on the photo sets the blur focus point
  void _setBlurFocus(double x, double y) {
    final blur = _recipe.tools.blur;
    blur.focusX = x;
    blur.focusY = y;
    if (blur.strength == 0) {
      blur.strength = 0.6;
    }
    _changed();
  }

  // ---- Dialogs, leaving, saving -----------------------------------------------------------

  Future<T?> _dialog<T>(WidgetBuilder builder) {
    final theme = _editorTheme;
    return showDialog<T>(
      context: context,
      builder: (context) => Theme(
        data: theme,
        child: Builder(builder: builder),
      ),
    );
  }

  Future<void> _close() async {
    if (_saving) {
      return;
    }
    if (_dirty) {
      final discard = await _dialog<bool>(
        (context) => AlertDialog(
          title: const Text('Discard changes?'),
          content: const Text("Your changes won't be saved"),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Keep editing')),
            TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Discard')),
          ],
        ),
      );
      if (discard != true) {
        return;
      }
    }
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _save({required bool replace}) async {
    if (!_dirty || _saving || !_editable) {
      return;
    }
    if (replace) {
      final confirmed = await _dialog<bool>(
        (context) => AlertDialog(
          title: const Text('Replace the original?'),
          content: const Text(
            "The edited photo takes its place. The original moves to Immich's trash, where it stays for 30 days.",
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: EditorColors.danger),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Save & replace'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) {
        return;
      }
    }
    setState(() {
      _saving = true;
      _savingText = 'Saving…';
      _savingProgress = null;
    });
    final recipe = _recipe.copy();
    try {
      final result = await _gpu(
        () => _session.save(
          recipe,
          replace: replace,
          onStep: (step, [progress]) {
            if (mounted) {
              setState(() {
                _savingText = '$step…';
                _savingProgress = progress;
              });
            }
          },
        ),
      );
      if (mounted) {
        Navigator.of(context).pop(result);
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _saving = false);
      _showStatus("Couldn't save: $error");
    }
  }

  Future<void> _openVersions() async {
    await showVersionsDialog(context, _session, theme: _editorTheme);
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _editAngle() async {
    final crop = _crop;
    if (crop == null) {
      return;
    }
    final value = await _dialog<double>((context) => _AngleDialog(angle: _recipe.geometry.angle));
    if (value == null || !mounted || _crop != crop) {
      return;
    }
    crop.setAngle(value);
    crop.endStraighten();
  }

  // ---- Layout -----------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: _editorTheme,
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        child: PopScope<Object?>(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) {
              unawaited(_close());
            }
          },
          child: Scaffold(
            backgroundColor: EditorColors.stage,
            body: Stack(
              children: [
                SafeArea(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final wide = constraints.maxWidth > 760;
                      final padding = constraints.maxWidth < 700 ? 20.0 : 48.0;
                      final cropping = _tab == EditorTab.crop;
                      if (wide) {
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              child: Column(
                                children: [
                                  _topBar(narrow: false),
                                  Expanded(child: _stage(padding)),
                                  if (cropping) _rulerBar(),
                                ],
                              ),
                            ),
                            SizedBox(
                              width: 340,
                              child: DecoratedBox(
                                decoration: const BoxDecoration(
                                  border: Border(left: BorderSide(color: EditorColors.divider)),
                                ),
                                child: _panel(),
                              ),
                            ),
                          ],
                        );
                      }
                      return Column(
                        children: [
                          _topBar(narrow: constraints.maxWidth < 520),
                          Expanded(child: _stage(padding)),
                          if (cropping) _rulerBar(),
                          SizedBox(
                            height: constraints.maxHeight * 0.42,
                            child: DecoratedBox(
                              decoration: const BoxDecoration(
                                border: Border(top: BorderSide(color: EditorColors.divider)),
                              ),
                              child: _panel(),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                if (_saving) Positioned.fill(child: _savingOverlay()),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _topBar({required bool narrow}) {
    final canSave = _dirty && !_saving && _editable;
    final hasVersions = _session.context?.edits.isNotEmpty ?? false;
    void saveReplace() => unawaited(_save(replace: true));
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Close',
            icon: const Icon(Icons.close),
            iconSize: 24,
            onPressed: _saving ? null : () => unawaited(_close()),
          ),
          const Spacer(),
          if (hasVersions)
            narrow
                ? IconButton(
                    tooltip: 'Versions',
                    icon: const Icon(Icons.history),
                    onPressed: _saving ? null : () => unawaited(_openVersions()),
                  )
                : TextButton(
                    onPressed: _saving ? null : () => unawaited(_openVersions()),
                    child: const Text('Versions'),
                  ),
          if (narrow)
            PopupMenuButton<String>(
              tooltip: 'More save options',
              icon: const Icon(Icons.more_vert),
              color: EditorColors.dialog,
              enabled: canSave,
              onSelected: (_) => saveReplace(),
              itemBuilder: (context) => const [PopupMenuItem(value: 'replace', child: Text('Save & replace original'))],
            )
          else
            Tooltip(
              message: "Saves the edit and moves the original to Immich's trash",
              child: TextButton(onPressed: canSave ? saveReplace : null, child: const Text('Save & replace original')),
            ),
          const SizedBox(width: 8),
          FilledButton(onPressed: canSave ? () => unawaited(_save(replace: false)) : null, child: const Text('Save')),
        ],
      ),
    );
  }

  Widget _stage(double padding) {
    final crop = _crop;
    final masks = _session.loadedMasks;
    final blur = _recipe.tools.blur;
    final focusable = _tab == EditorTab.tools && (masks?.hasBlur ?? false);
    final Widget content;
    if (_tab == EditorTab.crop && crop != null) {
      content = Stack(
        children: [
          Positioned.fill(
            child: CropStage(controller: crop, image: _tone, padding: padding),
          ),
          if (_tone == null)
            const Center(child: SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 3))),
        ],
      );
    } else {
      content = PreviewStage(
        image: _result,
        padding: padding,
        onTapImage: focusable ? _setBlurFocus : null,
        focus: focusable && blur.strength > 0 ? Offset(blur.focusX, blur.focusY) : null,
      );
    }
    final status = _status;
    return ClipRect(
      child: Stack(
        children: [
          Positioned.fill(child: content),
          if (status != null)
            Positioned(
              left: 16,
              right: 16,
              bottom: 16,
              child: Center(
                child: DecoratedBox(
                  decoration: const BoxDecoration(
                    color: Color(0xE628282C),
                    borderRadius: BorderRadius.all(Radius.circular(8)),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    child: Text(status, style: const TextStyle(fontSize: 14, color: EditorColors.text)),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _rulerBar() {
    final crop = _crop;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 12, 16),
      child: Row(
        children: [
          IconButton(tooltip: 'Rotate 90°', icon: const Icon(Icons.rotate_90_degrees_ccw), onPressed: crop?.rotate90),
          const SizedBox(width: 8),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: RotationRuler(
                  angle: _recipe.geometry.angle,
                  onChanged: (v) => crop?.setAngle(v),
                  onEnd: () => crop?.endStraighten(),
                  onEditExact: () => unawaited(_editAngle()),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(onPressed: crop?.reset, child: const Text('Reset')),
        ],
      ),
    );
  }

  Widget _panel() {
    return ColoredBox(
      color: EditorColors.panel,
      child: Column(
        children: [
          _tabBar(),
          const Divider(height: 1, thickness: 1, color: EditorColors.divider),
          Expanded(
            child: SingleChildScrollView(
              key: PageStorageKey<EditorTab>(_tab),
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
              child: _panelContent(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tabBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
      child: Row(
        children: [
          for (final tab in _tabs)
            Expanded(
              child: _TabButton(tab: tab, selected: tab == _tab, onTap: () => _selectTab(tab)),
            ),
        ],
      ),
    );
  }

  Widget _panelContent() {
    final stats = _session.stats;
    return switch (_tab) {
      EditorTab.suggestions => SuggestionsPanel(
        suggestions: _suggestions,
        autos: stats == null ? const [] : autoRecipes(stats),
        onSuggestion: _applySuggestion,
        onAuto: _applyAuto,
      ),
      EditorTab.crop => CropPanel(
        aspect: _recipe.geometry.aspect,
        originalRatio: () {
          final s = orientedSize(_proxyWidth, _proxyHeight, _recipe.geometry.rotate90);
          return s.width / s.height;
        }(),
        onAspect: (id) => _crop?.setAspect(id),
      ),
      EditorTab.tools => ToolsPanel(
        tools: _recipe.tools,
        masks: _session.loadedMasks,
        loading: _masksFuture != null && !_masksDone,
        error: _masksError,
        onChanged: _changed,
      ),
      EditorTab.adjust => AdjustPanel(
        adjust: _recipe.adjust,
        onChanged: (key, value) {
          _recipe.adjust[key] = value;
          _changed();
        },
      ),
      EditorTab.filters => FiltersPanel(
        filterId: _recipe.filterId,
        strength: _recipe.filterStrength,
        thumbnails: _thumbnails,
        onFilter: _selectFilter,
        onStrength: (v) {
          _recipe.filterStrength = v;
          _changed();
        },
      ),
      EditorTab.advanced => AdvancedPanel(
        advanced: _recipe.advanced,
        ui: _advancedUi,
        onChanged: _changed,
        onUiChanged: () => setState(() {}),
        onReset: () {
          _recipe.advanced = Advanced.defaults();
          _changed();
        },
      ),
    };
  }

  Widget _savingOverlay() {
    final progress = _savingProgress;
    return AbsorbPointer(
      child: ColoredBox(
        color: const Color(0xB3000000),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 40,
                height: 40,
                child: CircularProgressIndicator(
                  strokeWidth: 4,
                  value: progress,
                  backgroundColor: const Color(0x33FFFFFF),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                progress == null ? _savingText : '$_savingText ${(progress * 100).round()}%',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 15, color: EditorColors.text),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({required this.tab, required this.selected, required this.onTap});

  final EditorTab tab;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? EditorColors.accent : EditorColors.muted;
    return Semantics(
      selected: selected,
      button: true,
      label: tab.label,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(2, 10, 2, 8),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: selected ? EditorColors.accent : Colors.transparent, width: 3)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(tab.icon, size: 22, color: color),
              const SizedBox(height: 2),
              Text(
                tab.label,
                maxLines: 1,
                overflow: TextOverflow.fade,
                softWrap: false,
                style: TextStyle(fontSize: 11, color: color),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Type an exact rotation angle (double-tap on the ruler's value)
class _AngleDialog extends StatefulWidget {
  const _AngleDialog({required this.angle});

  final double angle;

  @override
  State<_AngleDialog> createState() => _AngleDialogState();
}

class _AngleDialogState extends State<_AngleDialog> {
  late final TextEditingController _text = TextEditingController(text: formatAngle(widget.angle).replaceAll('°', ''));

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  double? get _value {
    final v = double.tryParse(_text.text.trim().replaceAll(',', '.').replaceAll('−', '-'));
    return v != null && v.isFinite ? v : null;
  }

  void _submit() {
    final v = _value;
    if (v != null) {
      Navigator.of(context).pop(v);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rotation angle'),
      content: TextField(
        controller: _text,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
        decoration: const InputDecoration(suffixText: '°', helperText: 'Between -45 and 45'),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        TextButton(onPressed: _submit, child: const Text('OK')),
      ],
    );
  }
}
