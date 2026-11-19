// Tools tab: Sky, Color focus, Portrait light and Blur, available when the editor.photos
// server found the right masks for this photo (renderToolsPanel in editor.js).
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:immich_mobile/editor_photos/editor_session.dart';
import 'package:immich_mobile/editor_photos/model/js_compat.dart';
import 'package:immich_mobile/editor_photos/model/recipe.dart';
import 'package:immich_mobile/editor_photos/render/cpu_tools.dart';
import 'package:immich_mobile/editor_photos/ui/editor/editor_slider.dart';
import 'package:immich_mobile/editor_photos/ui/editor/editor_style.dart';

class ToolsPanel extends StatelessWidget {
  const ToolsPanel({
    super.key,
    required this.tools,
    required this.masks,
    required this.loading,
    required this.error,
    required this.onChanged,
  });

  final Tools tools;
  final ToolMasks? masks;
  final bool loading;
  final Object? error;

  /// The tools were changed in place
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final err = error;
    if (err != null) {
      return PanelNote("Tools aren't available: $err");
    }
    final m = masks;
    if (m == null) {
      return PanelNote(
        loading ? 'Analysing the photo for sky, subject, depth and faces…' : "Tools aren't available for this photo",
      );
    }
    final t = tools;
    final unavailable = <String>[];
    final children = <Widget>[];
    if (m.hasSky) {
      children.addAll([
        const SectionTitle('Sky'),
        _PaletteRow(
          selected: t.sky.palette,
          onSelect: (p) {
            t.sky.palette = p;
            if (t.sky.strength == 0) {
              t.sky.strength = 0.7;
            }
            onChanged();
          },
        ),
        SliderRow(
          label: 'Sky strength',
          value: t.sky.strength,
          min: 0,
          onChanged: (v) {
            t.sky.strength = v;
            onChanged();
          },
        ),
      ]);
    } else {
      unavailable.add('Sky');
    }
    if (m.hasColorFocus) {
      children.addAll([
        SectionTitle('Color focus', top: children.isEmpty ? 0 : 16),
        SliderRow(
          label: 'Color focus',
          value: t.colorFocus,
          min: 0,
          onChanged: (v) {
            t.colorFocus = v;
            onChanged();
          },
        ),
      ]);
    } else {
      unavailable.add('Color focus');
    }
    if (m.hasPortraitLight) {
      children.addAll([
        SectionTitle('Portrait light', top: children.isEmpty ? 0 : 16),
        SliderRow(
          label: 'Light strength',
          value: t.portraitLight.strength,
          min: 0,
          onChanged: (v) {
            t.portraitLight.strength = v;
            onChanged();
          },
        ),
        const PanelNote('Drag to move the light'),
        LightPad(
          x: t.portraitLight.x,
          y: t.portraitLight.y,
          onChanged: (x, y) {
            t.portraitLight.x = x;
            t.portraitLight.y = y;
            onChanged();
          },
        ),
      ]);
    } else {
      unavailable.add('Portrait light');
    }
    if (m.hasBlur) {
      children.addAll([
        SectionTitle('Blur', top: children.isEmpty ? 0 : 16),
        SliderRow(
          label: 'Blur strength',
          value: t.blur.strength,
          min: 0,
          onChanged: (v) {
            t.blur.strength = v;
            onChanged();
          },
        ),
        const PanelNote('Tap the photo to choose what stays sharp'),
      ]);
    } else {
      unavailable.add('Blur');
    }
    if (unavailable.isNotEmpty) {
      children.add(PanelNote('Not available for this photo: ${unavailable.join(', ')}'));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }
}

Color _rgb(List<double> c) => Color.fromARGB(255, (c[0] * 255).round(), (c[1] * 255).round(), (c[2] * 255).round());

class _PaletteRow extends StatelessWidget {
  const _PaletteRow({required this.selected, required this.onSelect});

  final String selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final columns = constraints.maxWidth >= 480 ? 7 : 4;
          final width = (constraints.maxWidth - (columns - 1) * 10) / columns;
          return Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final p in skyPalettes)
                SizedBox(
                  width: width,
                  child: _PaletteChip(palette: p, selected: p == selected, onTap: () => onSelect(p)),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _PaletteChip extends StatelessWidget {
  const _PaletteChip({required this.palette, required this.selected, required this.onTap});

  final String palette;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final look = skyLooks[palette];
    final name = palette[0].toUpperCase() + palette.substring(1);
    return Semantics(
      button: true,
      selected: selected,
      label: name,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Column(
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: selected ? EditorColors.accent : Colors.transparent, width: 2),
              ),
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: look == null
                        ? null
                        : LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [_rgb(look.top), _rgb(look.bottom)],
                          ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(name, style: TextStyle(fontSize: 12, color: selected ? EditorColors.accent : EditorColors.text)),
          ],
        ),
      ),
    );
  }
}

/// Where the portrait light comes from: drag the dot (x, y in 0..1 of the photo)
class LightPad extends StatelessWidget {
  const LightPad({super.key, required this.x, required this.y, required this.onChanged});

  final double x;
  final double y;
  final void Function(double x, double y) onChanged;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Light direction',
      value: '${(x * 100).round()}% across, ${(y * 100).round()}% down',
      child: SizedBox(
        height: 140,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final size = Size(constraints.maxWidth, 140);
            void move(Offset p) => onChanged(clampD(p.dx / size.width, 0, 1), clampD(p.dy / size.height, 0, 1));
            // The pad claims its pointers so dragging the light does not scroll the panel
            return RawGestureDetector(
              gestures: {
                EagerGestureRecognizer: GestureRecognizerFactoryWithHandlers<EagerGestureRecognizer>(
                  EagerGestureRecognizer.new,
                  (_) {},
                ),
              },
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: (e) => move(e.localPosition),
                onPointerMove: (e) => move(e.localPosition),
                child: DecoratedBox(
                  decoration: const BoxDecoration(
                    borderRadius: BorderRadius.all(Radius.circular(12)),
                    gradient: RadialGradient(colors: [Color(0xFF3A3B40), Color(0xFF202125)]),
                  ),
                  child: Stack(
                    children: [
                      Positioned(
                        left: x * size.width - 11,
                        top: y * size.height - 11,
                        child: Container(
                          width: 22,
                          height: 22,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: Color(0xFFFFF6D6),
                            boxShadow: [BoxShadow(color: Color(0x99FFF0C8), blurRadius: 18, spreadRadius: 6)],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
