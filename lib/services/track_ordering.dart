import '../models/track.dart';
import 'track_naming.dart';

const String sortNameAsc = 'Názov';
const String sortNameDesc = 'Názov Z–A';
const String sortArtist = 'Interpret';

int compareTracksByName(Track a, Track b) {
  final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
  return byName != 0 ? byName : a.id.compareTo(b.id);
}

/// Vráti nový zoznam skladieb vyfiltrovaný a zoradený podľa zadaných kritérií.
///
/// Poradie je deterministické (pri rovnosti rozhoduje názov a potom ID), takže
/// pri postupnom dopĺňaní knižnice zostáva relatívne poradie už zoradených
/// skladieb stabilné. Rovnaká funkcia sa používa pre zobrazený zoznam aj pre
/// prehrávaciu frontu, aby Next/Prev zodpovedali tomu, čo používateľ vidí.
List<Track> orderTracks(
  Iterable<Track> tracks, {
  required String sort,
  required bool flacOnly,
  required String query,
}) {
  final q = query.trim().toLowerCase();
  final result = tracks
      .where((t) => (!flacOnly || isFlacName(t.name)) && (q.isEmpty || t.name.toLowerCase().contains(q)))
      .toList();
  switch (sort) {
    case sortNameDesc:
      result.sort((a, b) => compareTracksByName(b, a));
    case sortArtist:
      result.sort((a, b) {
        final byArtist = artistOf(a.name).toLowerCase().compareTo(artistOf(b.name).toLowerCase());
        return byArtist != 0 ? byArtist : compareTracksByName(a, b);
      });
    default:
      result.sort(compareTracksByName);
  }
  return result;
}
