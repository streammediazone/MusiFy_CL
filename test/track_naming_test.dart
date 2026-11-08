import 'package:flutter_test/flutter_test.dart';
import 'package:musify/services/track_naming.dart';

void main() {
  test('odstráni príponu z názvu skladby', () {
    expect(titleOf('Artist - Song.flac'), 'Song');
    expect(titleOf('Artist - Song.FLAC'), 'Song');
    expect(titleOf('Song.mp3'), 'Song');
    expect(titleOf('Song.v2.flac'), 'Song.v2');
  });

  test('nemení názov bez rozpoznanej prípony', () {
    expect(titleOf('Artist - Song.txt'), 'Song.txt');
    expect(titleOf('Song'), 'Song');
  });

  test('rozpozná interpreta z názvu súboru', () {
    expect(parseArtist('Artist - Song.flac'), 'Artist');
    expect(parseArtist('Song.flac'), isNull);
    expect(artistOf('Song.flac'), unknownArtistLabel);
  });

  test('určí formát súboru', () {
    expect(formatLabelOf('a.flac'), 'FLAC');
    expect(formatLabelOf('a.Mp3'), 'MP3');
    expect(formatLabelOf('a'), '');
    expect(formatLabelOf('a.txt'), '');
  });
}
