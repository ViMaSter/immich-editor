// Advanced tab: Lightroom-style controls, same sections, ranges, steps, neutral values and
// value formats as public/edit/advanced-panel.js.
import 'package:flutter/material.dart';
import 'package:immich_mobile/editor_photos/model/advanced.dart';
import 'package:immich_mobile/editor_photos/model/js_compat.dart';
import 'package:immich_mobile/editor_photos/ui/editor/editor_slider.dart';
import 'package:immich_mobile/editor_photos/ui/editor/editor_style.dart';
import 'package:immich_mobile/editor_photos/ui/editor/panels/curve_editor.dart';

/// What stays selected while you switch tabs (module state in advanced-panel.js)
class AdvancedUiState {
  final Set<String> openSections = {'Light'};
  String curveChannel = 'rgb';
  String hslBand = 'blue';
}

/// `pct`: +12 / -5 / 0
String formatPercent(double v) => '${v > 0 ? '+' : ''}${jsRound(v * 100).toInt()}';

/// The slider's default format: the value rounded to two decimals, as JS prints it
String formatPlain(double v) {
  final r = jsRound(v * 100) / 100;
  return r == r.roundToDouble() ? '${r.toInt()}' : '$r';
}

String _format255(double v) => '${jsRound(v * 255).toInt()}';

class AdvancedPanel extends StatelessWidget {
  const AdvancedPanel({
    super.key,
    required this.advanced,
    required this.ui,
    required this.onChanged,
    required this.onUiChanged,
    required this.onReset,
  });

  final Advanced advanced;
  final AdvancedUiState ui;

  /// A value changed in place: re-render
  final VoidCallback onChanged;

  /// Only the panel's own state changed (section, channel, band)
  final VoidCallback onUiChanged;
  final VoidCallback onReset;

  Widget _slider(
    String label, {
    required double value,
    required ValueChanged<double> set,
    double min = -1,
    double max = 1,
    double step = 0.01,
    double neutral = 0,
    String Function(double)? format,
    bool hueTrack = false,
  }) => SliderRow(
    label: label,
    value: value,
    min: min,
    max: max,
    step: step,
    neutral: neutral,
    format: format ?? formatPlain,
    hueTrack: hueTrack,
    onChanged: (v) {
      set(v);
      onChanged();
    },
  );

  @override
  Widget build(BuildContext context) {
    final a = advanced;
    final light = [
      _slider(
        'Exposure',
        value: a.exposure,
        min: -3,
        max: 3,
        step: 0.05,
        set: (v) => a.exposure = v,
        format: (v) => '${v > 0 ? '+' : ''}${v.toStringAsFixed(2)} EV',
      ),
      _slider('Clarity', value: a.clarity, set: (v) => a.clarity = v, format: formatPercent),
      _slider('Dehaze', value: a.dehaze, set: (v) => a.dehaze = v, format: formatPercent),
    ];

    final lv = a.levels;
    final levels = [
      _slider('Input black', value: lv.inBlack, min: 0, max: 0.5, set: (v) => lv.inBlack = v, format: _format255),
      _slider(
        'Input white',
        value: lv.inWhite,
        min: 0.5,
        max: 1,
        neutral: 1,
        set: (v) => lv.inWhite = v,
        format: _format255,
      ),
      _slider(
        'Gamma',
        value: lv.gamma,
        min: 0.2,
        max: 5,
        step: 0.05,
        neutral: 1,
        set: (v) => lv.gamma = v,
        format: (v) => v.toStringAsFixed(2),
      ),
      _slider('Output black', value: lv.outBlack, min: 0, max: 0.5, set: (v) => lv.outBlack = v, format: _format255),
      _slider(
        'Output white',
        value: lv.outWhite,
        min: 0.5,
        max: 1,
        neutral: 1,
        set: (v) => lv.outWhite = v,
        format: _format255,
      ),
    ];

    final channel = ui.curveChannel;
    final curves = [
      _ChipRow(
        children: [
          for (final ch in curveChannels)
            _TextChip(
              label: ch == 'rgb' ? 'RGB' : ch.toUpperCase(),
              selected: ch == channel,
              onTap: () {
                ui.curveChannel = ch;
                onUiChanged();
              },
            ),
        ],
      ),
      CurveEditor(curves: a.curves, channel: channel, onChanged: onChanged),
      Row(
        children: [
          const Expanded(child: PanelNote('Tap to add a point, drag to move, double-tap to remove')),
          TextButton(
            onPressed: () {
              a.curves[channel] = [];
              onChanged();
            },
            child: const Text('Reset curve'),
          ),
        ],
      ),
    ];

    final bandName = ui.hslBand;
    final band = a.hsl[bandName]!;
    final hsl = [
      _ChipRow(
        children: [
          for (final (name, hue) in hslBands)
            _HueChip(
              name: name,
              color: HSLColor.fromAHSL(1, hue, 0.75, 0.55).toColor(),
              selected: name == bandName,
              onTap: () {
                ui.hslBand = name;
                onUiChanged();
              },
            ),
        ],
      ),
      _slider(
        'Hue ($bandName)',
        value: band.h,
        set: (v) => band.h = v,
        format: (v) => '${v > 0 ? '+' : ''}${jsRound(v * 30).toInt()}°',
      ),
      _slider('Saturation ($bandName)', value: band.s, set: (v) => band.s = v, format: formatPercent),
      _slider('Luminance ($bandName)', value: band.l, set: (v) => band.l = v, format: formatPercent),
    ];

    final gr = a.grading;
    final defaults = Advanced.defaults().grading.regions;
    final grading = [
      for (final region in gradingRegions) ...[
        _slider(
          '${region[0].toUpperCase()}${region.substring(1)} hue',
          value: gr.regions[region]!.hue,
          min: 0,
          max: 360,
          step: 1,
          neutral: defaults[region]!.hue,
          set: (v) => gr.regions[region]!.hue = v,
          format: (v) => '${jsRound(v).toInt()}°',
          hueTrack: true,
        ),
        _slider(
          '${region[0].toUpperCase()}${region.substring(1)} saturation',
          value: gr.regions[region]!.sat,
          min: 0,
          max: 1,
          set: (v) => gr.regions[region]!.sat = v,
          format: formatPercent,
        ),
      ],
      _slider('Balance', value: gr.balance, set: (v) => gr.balance = v, format: formatPercent),
      _slider(
        'Blending',
        value: gr.blending,
        min: 0,
        max: 1,
        neutral: 0.5,
        set: (v) => gr.blending = v,
        format: formatPercent,
      ),
    ];

    final detail = [
      _slider(
        'Sharpen',
        value: a.sharpen.amount,
        min: 0,
        max: 1,
        set: (v) => a.sharpen.amount = v,
        format: formatPercent,
      ),
      _slider(
        'Sharpen radius',
        value: a.sharpen.radius,
        min: 0.5,
        max: 3,
        step: 0.1,
        neutral: 1,
        set: (v) => a.sharpen.radius = v,
        format: (v) => v.toStringAsFixed(1),
      ),
      _slider('Noise reduction', value: a.noise, min: 0, max: 1, set: (v) => a.noise = v, format: formatPercent),
      _slider('Grain', value: a.grain, min: 0, max: 1, set: (v) => a.grain = v, format: formatPercent),
    ];

    final vg = a.vignette;
    final vignette = [
      _slider('Amount', value: vg.amount, set: (v) => vg.amount = v, format: formatPercent),
      _slider(
        'Midpoint',
        value: vg.midpoint,
        min: 0,
        max: 1,
        neutral: 0.5,
        set: (v) => vg.midpoint = v,
        format: formatPercent,
      ),
      _slider('Roundness', value: vg.roundness, set: (v) => vg.roundness = v, format: formatPercent),
      _slider(
        'Feather',
        value: vg.feather,
        min: 0,
        max: 1,
        neutral: 0.5,
        set: (v) => vg.feather = v,
        format: formatPercent,
      ),
    ];

    final sections = <(String, List<Widget>)>[
      ('Light', light),
      ('Levels', levels),
      ('Curves', curves),
      ('HSL', hsl),
      ('Color grading', grading),
      ('Detail', detail),
      ('Vignette', vignette),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (title, children) in sections)
          _Section(
            title: title,
            open: ui.openSections.contains(title),
            onToggle: () {
              if (!ui.openSections.remove(title)) {
                ui.openSections.add(title);
              }
              onUiChanged();
            },
            children: children,
          ),
        Padding(
          padding: const EdgeInsets.only(top: 14),
          child: Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(onPressed: onReset, child: const Text('Reset advanced')),
          ),
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.open, required this.onToggle, required this.children});

  final String title;
  final bool open;
  final VoidCallback onToggle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: EditorColors.divider)),
      ),
      child: Padding(
        padding: EdgeInsets.only(bottom: open ? 10 : 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              button: true,
              expanded: open,
              child: InkWell(
                onTap: onToggle,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Row(
                    children: [
                      Icon(
                        open ? Icons.expand_more : Icons.chevron_right,
                        size: 20,
                        color: open ? EditorColors.accent : EditorColors.text,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: open ? EditorColors.accent : EditorColors.text,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (open) ...children,
          ],
        ),
      ),
    );
  }
}

class _ChipRow extends StatelessWidget {
  const _ChipRow({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 6, bottom: 10),
    child: Wrap(spacing: 8, runSpacing: 8, children: children),
  );
}

class _TextChip extends StatelessWidget {
  const _TextChip({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: ShapeDecoration(
            shape: StadiumBorder(side: BorderSide(color: selected ? EditorColors.accent : EditorColors.outline)),
          ),
          child: Text(label, style: TextStyle(fontSize: 12, color: selected ? EditorColors.accent : EditorColors.text)),
        ),
      ),
    );
  }
}

class _HueChip extends StatelessWidget {
  const _HueChip({required this.name, required this.color, required this.selected, required this.onTap});

  final String name;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: name,
      child: Tooltip(
        message: name,
        child: GestureDetector(
          onTap: onTap,
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: selected ? EditorColors.accent : Colors.transparent, width: 2),
            ),
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(shape: BoxShape.circle, color: color),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
