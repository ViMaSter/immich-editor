// Filters tab: every filter as a thumbnail on top of the current adjustments, plus the
// strength of the chosen one (renderFiltersPanel in editor.js).
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:immich_mobile/editor_photos/model/filters.dart';
import 'package:immich_mobile/editor_photos/ui/editor/editor_slider.dart';
import 'package:immich_mobile/editor_photos/ui/editor/editor_style.dart';

class FiltersPanel extends StatelessWidget {
  const FiltersPanel({
    super.key,
    required this.filterId,
    required this.strength,
    required this.thumbnails,
    required this.onFilter,
    required this.onStrength,
  });

  final String filterId;
  final double strength;

  /// Rendered thumbnails by filter id (missing while they render)
  final Map<String, ui.Image> thumbnails;
  final ValueChanged<String> onFilter;
  final ValueChanged<double> onStrength;

  @override
  Widget build(BuildContext context) {
    final current = filters[filterId];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (filterId != 'none')
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: SliderRow(
              label: '${current?.name ?? filterId} strength',
              value: strength,
              min: 0,
              onChanged: onStrength,
            ),
          ),
        LayoutBuilder(
          builder: (context, constraints) {
            const cell = 84.0;
            final columns = (constraints.maxWidth / cell).floor().clamp(3, 8);
            final width = (constraints.maxWidth - (columns - 1) * 12) / columns;
            return Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final entry in filters.entries)
                  SizedBox(
                    width: width,
                    child: _FilterButton(
                      name: entry.value.name,
                      image: thumbnails[entry.key],
                      selected: entry.key == filterId,
                      onTap: () => onFilter(entry.key),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _FilterButton extends StatelessWidget {
  const _FilterButton({required this.name, required this.image, required this.selected, required this.onTap});

  final String name;
  final ui.Image? image;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final img = image;
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
                borderRadius: const BorderRadius.all(Radius.circular(14)),
                border: Border.all(color: selected ? EditorColors.accent : Colors.transparent, width: 2),
              ),
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: ClipRRect(
                  borderRadius: const BorderRadius.all(Radius.circular(12)),
                  child: SizedBox(
                    width: 72,
                    height: 72,
                    child: img == null
                        ? const ColoredBox(color: EditorColors.panel2)
                        : RawImage(image: img, fit: BoxFit.cover, filterQuality: FilterQuality.medium),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              name,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: selected ? EditorColors.accent : EditorColors.text),
            ),
          ],
        ),
      ),
    );
  }
}
