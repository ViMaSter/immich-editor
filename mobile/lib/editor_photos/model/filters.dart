// Filter presets (port of public/edit/filters.js and learned-presets.js), expressed in the
// same slider units as the Adjust panel so a filter at strength s adds s × its values.

class SplitTone {
  final List<double> shadows;
  final List<double> highlights;
  final double amount;

  const SplitTone({required this.shadows, required this.highlights, this.amount = 1});
}

class FilterPreset {
  final String name;
  final Map<String, double>? adjust;
  final bool mono;
  final SplitTone? split;
  final bool learned;

  const FilterPreset({required this.name, this.adjust, this.mono = false, this.split, this.learned = false});
}

const _sepiaSplit = SplitTone(shadows: [0.04, 0.015, -0.03], highlights: [0.06, 0.03, -0.04]);

/// Built-in filters, in the order the web editor lists them
const _builtIn = <String, FilterPreset>{
  'none': FilterPreset(name: 'None'),
  'vivid': FilterPreset(name: 'Vivid', adjust: {'saturation': 0.35, 'contrast': 0.15, 'pop': 0.1, 'blueTone': 0.15}),
  'warm': FilterPreset(name: 'Warm', adjust: {'warmth': 0.3, 'saturation': 0.08, 'highlights': -0.1}),
  'cool': FilterPreset(name: 'Cool', adjust: {'warmth': -0.3, 'tint': 0.05, 'contrast': 0.05}),
  'golden': FilterPreset(
    name: 'Golden',
    adjust: {'warmth': 0.4, 'saturation': 0.12, 'shadows': 0.1, 'highlights': -0.15},
    split: SplitTone(shadows: [0.01, 0, -0.02], highlights: [0.03, 0.015, -0.02]),
  ),
  'matte': FilterPreset(
    name: 'Matte',
    adjust: {'blackPoint': -0.4, 'highlights': -0.2, 'saturation': -0.15, 'contrast': -0.1},
  ),
  'faded': FilterPreset(
    name: 'Faded',
    adjust: {'blackPoint': -0.55, 'contrast': -0.25, 'saturation': -0.3, 'warmth': 0.08},
  ),
  'punch': FilterPreset(name: 'Punch', adjust: {'contrast': 0.3, 'pop': 0.35, 'saturation': 0.15, 'blackPoint': 0.15}),
  'teal': FilterPreset(
    name: 'Teal & Orange',
    adjust: {'contrast': 0.15, 'saturation': 0.1},
    split: SplitTone(shadows: [-0.03, 0.01, 0.035], highlights: [0.04, 0.015, -0.03]),
  ),
  'dusk': FilterPreset(
    name: 'Dusk',
    adjust: {'warmth': 0.15, 'tint': 0.2, 'shadows': -0.1, 'saturation': 0.1},
    split: SplitTone(shadows: [0.01, -0.01, 0.04], highlights: [0.04, 0.01, 0]),
  ),
  'neon': FilterPreset(
    name: 'Neon night',
    adjust: {
      'contrast': 0.35,
      'saturation': 0.35,
      'blueTone': 0.45,
      'blackPoint': 0.15,
      'warmth': -0.3,
      'tint': 0.2,
      'pop': 0.25,
      'highlights': -0.15,
    },
    split: SplitTone(shadows: [-0.03, 0.02, 0.07], highlights: [0.08, -0.03, 0.07]),
  ),
  'mono': FilterPreset(name: 'Mono', mono: true, adjust: {'contrast': 0.1}),
  'mono-contrast': FilterPreset(
    name: 'Mono High Contrast',
    mono: true,
    adjust: {'contrast': 0.45, 'blackPoint': 0.25, 'pop': 0.2},
  ),
  'mono-soft': FilterPreset(
    name: 'Mono Soft',
    mono: true,
    adjust: {'contrast': -0.1, 'blackPoint': -0.25, 'highlights': -0.15},
  ),
  'sepia': FilterPreset(name: 'Sepia', mono: true, adjust: {'contrast': 0.1, 'blackPoint': -0.15}, split: _sepiaSplit),
};

class LearnedPreset {
  final String id;
  final String name;
  final double share;
  final String? filterId;
  final double filterStrength;
  final Map<String, double> adjust;

  const LearnedPreset({
    required this.id,
    required this.name,
    required this.share,
    this.filterId,
    this.filterStrength = 1,
    required this.adjust,
  });
}

/// Edit patterns learned from your own Google Photos edits (learned-presets.js)
const learnedPresets = <LearnedPreset>[
  LearnedPreset(
    id: 'learned-vivid',
    name: 'Vivid look',
    share: 10 / 35,
    filterId: 'vivid',
    adjust: {
      'saturation': 0.41,
      'blueTone': 0.14,
      'skinTone': -0.24,
      'pop': 0.12,
      'whitePoint': 0.11,
      'shadows': 0.1,
      'highlights': -0.08,
      'contrast': 0.08,
    },
  ),
  LearnedPreset(
    id: 'learned-enhance',
    name: 'Gentle enhance',
    share: 10 / 35,
    adjust: {
      'pop': 0.12,
      'saturation': 0.12,
      'shadows': 0.07,
      'contrast': 0.08,
      'highlights': -0.04,
      'skinTone': -0.07,
    },
  ),
  LearnedPreset(
    id: 'learned-blue-sky',
    name: 'Deep blue sky',
    share: 8 / 35,
    adjust: {'saturation': 0.74, 'blueTone': 0.34, 'highlights': -0.28, 'contrast': 0.12, 'whitePoint': 0.05},
  ),
  LearnedPreset(
    id: 'learned-warm-lift',
    name: 'Warm lift',
    share: 4 / 35,
    filterId: 'golden',
    filterStrength: 0.5,
    adjust: {'shadows': 0.26, 'pop': 0.15, 'whitePoint': 0.13, 'saturation': 0.12},
  ),
  LearnedPreset(
    id: 'learned-mono-contrast',
    name: 'B&W contrast',
    share: 2 / 35,
    adjust: {
      'saturation': -1,
      'contrast': 0.48,
      'highlights': 0.6,
      'blackPoint': 0.17,
      'shadows': 0.13,
      'whitePoint': -0.23,
      'vignette': 0.08,
    },
  ),
  LearnedPreset(
    id: 'learned-sepia',
    name: 'Sepia contrast',
    share: 1 / 35,
    filterId: 'sepia',
    adjust: {'contrast': 0.5, 'blackPoint': 0.25, 'highlights': 0.4},
  ),
];

/// All filters: built-in looks, then the learned looks (as registered by learned-presets.js)
final Map<String, FilterPreset> filters = {
  ..._builtIn,
  for (final p in learnedPresets)
    if (!_builtIn.containsKey(p.id))
      p.id: FilterPreset(
        name: p.name,
        learned: true,
        adjust: p.adjust,
        mono: p.filterId == 'sepia' || p.adjust['saturation'] == -1,
        split: p.filterId == 'sepia' ? _sepiaSplit : null,
      ),
};
