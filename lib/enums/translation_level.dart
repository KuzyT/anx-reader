enum TranslationLevelEnum {
  full('full', 'Full translation'),
  level0('level0', '0 - Word by word'),
  a1('a1', 'A1'),
  a2('a2', 'A2'),
  b1('b1', 'B1'),
  b2('b2', 'B2'),
  c1('c1', 'C1'),
  c2('c2', 'C2');

  const TranslationLevelEnum(this.code, this.displayName);

  final String code;
  final String displayName;

  static TranslationLevelEnum fromCode(String code) {
    return TranslationLevelEnum.values.firstWhere(
      (e) => e.code == code,
      orElse: () => TranslationLevelEnum.full,
    );
  }

  /// Whether this level requires word-by-word translation
  bool get isWordLevel => this != TranslationLevelEnum.full;

  /// Description for the AI prompt
  String get levelDescription {
    switch (this) {
      case TranslationLevelEnum.full:
        return 'Translate everything';
      case TranslationLevelEnum.level0:
        return 'Translate every single word, regardless of how basic it is';
      case TranslationLevelEnum.a1:
        return 'A1 beginner - translate all but the most basic words (hello, yes, no, numbers 1-10)';
      case TranslationLevelEnum.a2:
        return 'A2 elementary - translate all but basic everyday words (common greetings, family, food, colors, days)';
      case TranslationLevelEnum.b1:
        return 'B1 intermediate - translate uncommon and advanced words only (skip everyday conversation vocabulary)';
      case TranslationLevelEnum.b2:
        return 'B2 upper-intermediate - translate only advanced, literary, or specialized words';
      case TranslationLevelEnum.c1:
        return 'C1 advanced - translate only rare, archaic, or highly specialized words';
      case TranslationLevelEnum.c2:
        return 'C2 proficiency - translate only extremely rare or domain-specific terms';
    }
  }
}
