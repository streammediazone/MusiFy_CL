import 'package:flutter_test/flutter_test.dart';
import 'package:musify/models/track.dart';
import 'package:musify/services/track_ordering.dart';

Track _track(String id, String name) => Track(id: id, name: name, size: 1, mimeType: 'audio/flac');

List<String> _ids(List<Track> tracks) => tracks.map((t) => t.id).toList();

void main() {
  final tracks = <Track>[
    _track('1', 'Beta - Song B.flac'),
    _track('2', 'alpha - Song A.mp3'),
    _track('3', 'Alpha - Song C.flac'),
    _track('4', 'Gamma.flac'),
    _track('5', 'Zed.flac'),
    _track('6', 'Kappa - X.flac'),
  ];

  test('zoradí podľa názvu bez ohľadu na veľkosť písmen', () {
    final result = orderTracks(tracks, sort: sortNameAsc, flacOnly: false, query: '');
    expect(_ids(result), ['2', '3', '1', '4', '6', '5']);
  });

  test('zoradí názov Z–A', () {
    final result = orderTracks(tracks, sort: sortNameDesc, flacOnly: false, query: '');
    expect(_ids(result), ['5', '6', '4', '1', '3', '2']);
  });

  test('zoradí podľa interpreta, pri zhode podľa názvu', () {
    final result = orderTracks(tracks, sort: sortArtist, flacOnly: false, query: '');
    expect(_ids(result), ['2', '3', '1', '6', '4', '5']);
  });

  test('filter FLAC vynechá iné formáty', () {
    final result = orderTracks(tracks, sort: sortNameAsc, flacOnly: true, query: '');
    expect(_ids(result), ['3', '1', '4', '6', '5']);
  });

  test('vyhľadávanie ignoruje veľkosť písmen a okolité medzery', () {
    expect(_ids(orderTracks(tracks, sort: sortNameAsc, flacOnly: false, query: 'alpha')), ['2', '3']);
    expect(_ids(orderTracks(tracks, sort: sortNameAsc, flacOnly: false, query: '  BETA ')), ['1']);
  });

  test('rovnaké názvy sa rozlíšia podľa ID, poradie je deterministické', () {
    final same = <Track>[_track('b', 'Same.flac'), _track('a', 'Same.flac')];
    expect(_ids(orderTracks(same, sort: sortNameAsc, flacOnly: false, query: '')), ['a', 'b']);
    expect(_ids(orderTracks(same.reversed, sort: sortNameAsc, flacOnly: false, query: '')), ['a', 'b']);
  });
}
