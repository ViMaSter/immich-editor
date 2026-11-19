// Suggestions tab: suggested edits for this photo (from the editor.photos server) and the
// automatic Enhance / Dynamic / Warm / Cool edits (renderSuggestionsPanel in editor.js).
import 'package:flutter/material.dart';
import 'package:immich_mobile/editor_photos/data/editor_server.dart';
import 'package:immich_mobile/editor_photos/model/auto.dart';
import 'package:immich_mobile/editor_photos/ui/editor/editor_style.dart';

class SuggestionsPanel extends StatelessWidget {
  const SuggestionsPanel({
    super.key,
    required this.suggestions,
    required this.autos,
    required this.onSuggestion,
    required this.onAuto,
  });

  /// The suggestion the editor was opened from plus the cached ones for this photo
  final List<Suggestion> suggestions;
  final List<AutoRecipe> autos;
  final ValueChanged<Suggestion> onSuggestion;
  final ValueChanged<AutoRecipe> onAuto;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (suggestions.isNotEmpty) ...[
          const SectionTitle('Suggested for this photo'),
          for (final s in suggestions)
            _SuggestionButton(
              icon: '★',
              title: s.name,
              subtitle: s.why.isNotEmpty ? 'Why: ${s.why}' : null,
              onTap: () => onSuggestion(s),
            ),
        ],
        SectionTitle('Suggestions', top: suggestions.isNotEmpty ? 10 : 0),
        if (autos.isEmpty) const PanelNote('No automatic suggestions for this photo'),
        for (final auto in autos) _SuggestionButton(icon: '✦', title: auto.name, onTap: () => onAuto(auto)),
      ],
    );
  }
}

class _SuggestionButton extends StatelessWidget {
  const _SuggestionButton({required this.icon, required this.title, this.subtitle, required this.onTap});

  final String icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final sub = subtitle;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: EditorColors.panel2,
        borderRadius: const BorderRadius.all(Radius.circular(12)),
        child: InkWell(
          borderRadius: const BorderRadius.all(Radius.circular(12)),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Text(icon, style: const TextStyle(color: EditorColors.accent, fontSize: 16)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: const TextStyle(fontSize: 14, color: EditorColors.text)),
                      if (sub != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(sub, style: const TextStyle(fontSize: 12, color: EditorColors.muted)),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
