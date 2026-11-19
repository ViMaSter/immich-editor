// Adjust tab: the 14 Google Photos sliders in three groups (renderAdjustPanel).
import 'package:flutter/material.dart';
import 'package:immich_mobile/editor_photos/model/recipe.dart';
import 'package:immich_mobile/editor_photos/ui/editor/editor_slider.dart';
import 'package:immich_mobile/editor_photos/ui/editor/editor_style.dart';

class AdjustPanel extends StatelessWidget {
  const AdjustPanel({super.key, required this.adjust, required this.onChanged});

  final Map<String, double> adjust;
  final void Function(String key, double value) onChanged;

  static final groups = [adjustKeys.sublist(0, 7), adjustKeys.sublist(7, 12), adjustKeys.sublist(12)];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < groups.length; i++)
          DecoratedBox(
            decoration: BoxDecoration(
              border: i < groups.length - 1 ? const Border(bottom: BorderSide(color: EditorColors.divider)) : null,
            ),
            child: Padding(
              padding: EdgeInsets.only(bottom: i < groups.length - 1 ? 10 : 0, top: i > 0 ? 10 : 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final key in groups[i])
                    SliderRow(
                      label: adjustLabels[key]!,
                      value: adjust[key] ?? 0,
                      min: unipolarKeys.contains(key) ? 0 : -1,
                      onChanged: (v) => onChanged(key, v),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
