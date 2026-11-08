/// Pomocné funkcie na odvodenie interpreta, názvu a formátu z názvu súboru
/// v tvare „Interpret - Názov.flac“.
final RegExp _audioExtension = RegExp(
  r'\.(flac|mp3|m4a|aac|ogg|opus|wav|wma)$',
  caseSensitive: false,
);

const String unknownArtistLabel = 'Miestna knižnica';

/// Odstráni príponu zvukového súboru (ak je rozpoznaná).
String stripAudioExtension(String name) => name.replaceAll(_audioExtension, '');

/// Interpret z názvu súboru, alebo `null`, ak názov nemá tvar „Interpret - Názov“.
String? parseArtist(String name) {
  final dash = name.indexOf(' - ');
  return dash > 0 ? name.substring(0, dash) : null;
}

String artistOf(String name) => parseArtist(name) ?? unknownArtistLabel;

String titleOf(String name) {
  final dash = name.indexOf(' - ');
  final value = dash > 0 ? name.substring(dash + 3) : name;
  return stripAudioExtension(value);
}

/// Prípona veľkými písmenami (napr. „FLAC“); prázdny reťazec, ak nie je rozpoznaná.
String formatLabelOf(String name) {
  final match = _audioExtension.firstMatch(name);
  return match == null ? '' : match.group(1)!.toUpperCase();
}

bool isFlacName(String name) => name.toLowerCase().endsWith('.flac');
