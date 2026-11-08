import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:audio_service/audio_service.dart';
import 'models/track.dart';
import 'services/flac_picture_parser.dart';
import 'services/track_naming.dart';
import 'services/track_ordering.dart';

const _bg = Color(0xFF090D0B);
const _surface = Color(0xFF151B17);
const _surface2 = Color(0xFF1D2620);
const _green = Color(0xFF70E34B);
const _muted = Color(0xFF9BA69E);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.streamzone.musify.channel.audio',
    androidNotificationChannelName: 'MusiFy – prehrávanie hudby',
    androidNotificationOngoing: true,
  );
  runApp(const MusiFyApp());
}

class MusiFyApp extends StatelessWidget {
  const MusiFyApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'MusiFy',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: _bg,
      colorScheme: ColorScheme.fromSeed(seedColor: _green, brightness: Brightness.dark, surface: _surface),
      useMaterial3: true,
      appBarTheme: const AppBarTheme(backgroundColor: _bg, surfaceTintColor: Colors.transparent, elevation: 0),
      sliderTheme: const SliderThemeData(activeTrackColor: _green, thumbColor: _green, inactiveTrackColor: Color(0xFF38443B), overlayColor: Color(0x2270E34B)),
    ),
    home: const LibraryPage(),
  );
}



class KDriveService {
  // Predvolené hodnoty zdieľaného odkazu kDrive. Voliteľne ich možno prepísať pri buildi:
  // --dart-define=KDRIVE_DRIVE_ID=... --dart-define=KDRIVE_SHARE_TOKEN=...
  static const _driveId = String.fromEnvironment('KDRIVE_DRIVE_ID', defaultValue: '1800737');
  static const _shareToken = String.fromEnvironment('KDRIVE_SHARE_TOKEN', defaultValue: 'd5b56959-2447-46ed-aa12-942b2ce66042');
  final http.Client _client = http.Client();
  Uri _downloadUri(String fileId) => Uri.https('kdrive.infomaniak.com', '/2/app/$_driveId/share/$_shareToken/files/$fileId/download');
  Uri _shareRootUri() => Uri.https('kdrive.infomaniak.com', '/2/app/$_driveId/share/$_shareToken/files');
  Uri _folderFilesUri(String folderId, {String? cursor, int? page}) => Uri.https(
    'kdrive.infomaniak.com', '/2/app/$_driveId/share/$_shareToken/files/$folderId/files',
    {if (cursor != null) 'cursor': cursor, if (page != null) 'page': '$page', 'per_page': '100'},
  );
  Future<dynamic> _getJson(Uri uri) async {
    final response = await _client.get(uri, headers: const {'Accept': 'application/json'}).timeout(const Duration(seconds: 25));
    if (response.statusCode != 200) throw Exception('kDrive odpovedal HTTP ${response.statusCode} pri načítaní obsahu.');
    return jsonDecode(utf8.decode(response.bodyBytes));
  }
  Future<LibraryResult> loadAudioTracks({
    Future<void> Function(List<Track>)? onInitialBatchReady,
    Future<void> Function(List<Track>)? onProgress,
    bool Function()? isCancelled,
  }) async {
    if (_driveId.isEmpty || _shareToken.isEmpty) {
      throw StateError('Chýba konfigurácia kDrive. Skontroluj hodnoty _driveId a _shareToken v KDriveService.');
    }
    bool cancelled() => isCancelled?.call() ?? false;
    final root = await _getJson(_shareRootUri());
    if (cancelled()) return const LibraryResult(<Track>[], <String>[]);
    if (root is! Map || root['data'] is! Map) throw FormatException('kDrive neposkytol metadáta zdieľaného priečinka.');
    final rootData = Map<String, dynamic>.from(root['data'] as Map);
    final rootId = (rootData['id'] ?? '').toString();
    if (rootId.isEmpty || rootData['type'] != 'dir') throw FormatException('Zdieľaný odkaz nevrátil priečinok. ID: $rootId, typ: ${rootData['type']}.');
    final tracks = <Track>[];
    final allUniqueTracks = <String, Track>{};
    var initialBatchPublished = false;
    var initialBatchReady = false;
    final trackSourcePages = <String, List<String>>{};
    final itemDiagnosticMetadata = <String, String>{};
    var pendingFolders = <String>[rootId];
    final visitedFolders = <String>{};
    final diagnostics = <String>['Koreň: ID=$rootId, názov=${rootData['name'] ?? '-'}'];
    // Fetch independent folders concurrently; pages within one folder remain
    // sequential because the next cursor depends on the previous response.
    Future<({List<Track> tracks, List<String> folders, List<String> logs})> readFolder(String folderId) async {
      final folderTracks = <Track>[];
      final childFolders = <String>[];
      final logs = <String>[];
      final cursors = <String>{};
      final excludedSamples = <String>[];
      final pageDiagnostics = <String>[];
      final seenPageAudioIds = <String>{};
      var pageCount = 0;
      var listedItems = 0;
      var fileItems = 0;
      var audioItems = 0;
      var lastHasMore = false;
      var hitPageLimit = false;
      String? cursor;
      var pageNumber = 1;
      for (var page = 0; page < 100; page++) {
        if (cancelled()) break;
        final requestMode = cursor == null ? 'page=$pageNumber' : 'cursor (${cursor.length} znakov)';
        final response = await _getJson(_folderFilesUri(folderId, cursor: cursor, page: cursor == null ? pageNumber : null));
        final pageData = _parsePage(response);
        pageCount++;
        listedItems += pageData.items.length;
        lastHasMore = pageData.hasMore;
        final pageAudioIds = <String>[];
        final pageRepeatedIds = <String>[];
        for (final item in pageData.items) {
          final type = (item['type'] ?? '').toString();
          final id = (item['id'] ?? '').toString();
          if (type == 'dir' && id.isNotEmpty) { childFolders.add(id); continue; }
          if (type != 'file') continue;
          fileItems++;
          final track = Track.fromJson(item);
          final name = track.name.toLowerCase();
          final audio = track.mimeType.startsWith('audio/') || const ['.flac', '.mp3', '.m4a', '.aac', '.ogg', '.opus', '.wav', '.wma'].any(name.endsWith);
          if (audio && track.id.isNotEmpty) {
            audioItems++;
            folderTracks.add(track);
            allUniqueTracks.putIfAbsent(track.id, () => track);
            pageAudioIds.add(track.id);
            final metadataKeys = const ['etag', 'size', 'created_at', 'updated_at', 'modified_at', 'mtime', 'last_modified', 'checksum', 'hash', 'parent_id'];
            final metadata = <String, dynamic>{};
            for (final key in metadataKeys) {
              if (item.containsKey(key) && item[key] != null) metadata[key] = item[key];
            }
            itemDiagnosticMetadata[track.id] = metadata.isEmpty ? 'bez známych metadátových polí' : jsonEncode(metadata);
            if (!seenPageAudioIds.add(track.id)) pageRepeatedIds.add(track.id);
            trackSourcePages.putIfAbsent(track.id, () => <String>[]).add('$folderId / strana $pageCount');
          } else if (excludedSamples.length < 8) {
            excludedSamples.add('${track.name} [${track.mimeType.isEmpty ? 'bez MIME' : track.mimeType}]');
          }
        }
        final firstIds = pageAudioIds.take(5).join(',');
        final lastIds = pageAudioIds.length <= 5 ? '' : pageAudioIds.skip(pageAudioIds.length - 5).join(',');
        final overlap = pageRepeatedIds.take(12).join(',');
        pageDiagnostics.add('Strana $pageCount: request=$requestMode, položiek=${pageData.items.length}, audio=${pageAudioIds.length}, prvé ID=[$firstIds], posledné ID=[$lastIds], opakovanie z predošlých strán=${pageRepeatedIds.length}${overlap.isEmpty ? '' : ' [$overlap]'}, has_more=${pageData.hasMore}, cursor=${pageData.cursor == null || pageData.cursor!.isEmpty ? 'nie' : 'áno (${pageData.cursor!.length} znakov)'}, ${pageData.responseKeys}');
        if (!initialBatchPublished && allUniqueTracks.length >= 100) {
          initialBatchPublished = true;
          final initialTracks = allUniqueTracks.values.take(100).toList()
            ..sort((a, b) {
              final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
              return byName != 0 ? byName : a.id.compareTo(b.id);
            });
          await onInitialBatchReady?.call(initialTracks);
          initialBatchReady = true;
        } else if (initialBatchPublished && initialBatchReady) {
          final progressTracks = allUniqueTracks.values.toList()
              ..sort((a, b) {
                final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
                return byName != 0 ? byName : a.id.compareTo(b.id);
              });
          await onProgress?.call(progressTracks);
        }
        if (!pageData.hasMore) break;
        if (page == 99) hitPageLimit = true;
        final next = pageData.cursor;
        if (next != null && next.isNotEmpty) {
          if (!cursors.add(next)) throw Exception('kDrive opakovane vrátil rovnaký kurzor.');
          cursor = next;
        } else { pageNumber++; }
      }
      logs.add('Priečinok $folderId: stránok=$pageCount, položiek=$listedItems, súborov=$fileItems, rozpoznané audio=$audioItems, podpriečinky=${childFolders.length}, posledné has_more=$lastHasMore, limit 100 strán=${hitPageLimit ? 'ÁNO' : 'nie'}');
      logs.addAll(pageDiagnostics);
      if (excludedSamples.isNotEmpty) logs.add('Vynechané súbory (ukážka): ${excludedSamples.join(' | ')}');
      return (tracks: folderTracks, folders: childFolders, logs: logs);
    }
    while (pendingFolders.isNotEmpty && !cancelled()) {
      final batch = pendingFolders.take(3).toList();
      pendingFolders = pendingFolders.skip(batch.length).toList();
      final fresh = batch.where((id) => visitedFolders.add(id)).toList();
      final results = await Future.wait(fresh.map(readFolder));
      for (final result in results) {
        tracks.addAll(result.tracks);
        pendingFolders.addAll(result.folders);
        diagnostics.addAll(result.logs);
      }
    }
    if (cancelled()) return LibraryResult(const <Track>[], diagnostics);
    if (!initialBatchPublished && allUniqueTracks.isNotEmpty) {
      initialBatchPublished = true;
      final initialTracks = allUniqueTracks.values.take(100).toList()
          ..sort((a, b) {
                final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
                return byName != 0 ? byName : a.id.compareTo(b.id);
              });
      await onInitialBatchReady?.call(initialTracks);
      initialBatchReady = true;
    }
    // Report ID collisions before deduplication so we can distinguish repeated
    // API entries from different files incorrectly sharing the same identifier.
    final tracksById = <String, List<Track>>{};
    for (final track in tracks) {
      tracksById.putIfAbsent(track.id, () => <Track>[]).add(track);
    }
    final duplicateGroups = tracksById.entries.where((entry) => entry.value.length > 1).toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));
    final duplicateOccurrences = tracks.length - tracksById.length;
    diagnostics.add('Kontrola ID: prijaté audio=${tracks.length}, unikátne ID=${tracksById.length}, ID s opakovaním=${duplicateGroups.length}, nadbytočné výskyty=$duplicateOccurrences');
    for (final entry in duplicateGroups.take(20)) {
      final names = entry.value.map((track) => track.name).toSet().join(' / ');
      final pages = trackSourcePages[entry.key]?.join(', ') ?? 'neznáma';
      diagnostics.add('Duplicitné ID ${entry.key} (výskytov ${entry.value.length}, stránky: $pages): $names; metadáta=${itemDiagnosticMetadata[entry.key] ?? 'nedostupné'}');
    }
    if (duplicateGroups.length > 20) {
      diagnostics.add('Ďalšie duplicitné ID: ${duplicateGroups.length - 20}');
    }
    // Keep the existing one-entry-per-ID behavior until the collision cause is known.
    final uniqueTracks = Map<String, Track>.from(allUniqueTracks);
    final orderedTracks = uniqueTracks.values.toList()
      ..sort((a, b) {
                final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
                return byName != 0 ? byName : a.id.compareTo(b.id);
              });
    diagnostics.add('Hotovo: priečinkov ${visitedFolders.length}, skladieb ${orderedTracks.length} (unikátne ID)');
    if (initialBatchReady) await onProgress?.call(orderedTracks);
    return LibraryResult(orderedTracks, diagnostics);
  }
  _Page _parsePage(dynamic value) {
    if (value is String) value = jsonDecode(value);
    if (value is List) return _Page(value.whereType<Map>().map((e) => Map<String,dynamic>.from(e)).toList(), false, null, 'odpoveď je priamo zoznam');
    if (value is! Map) throw FormatException('Neočakávaný formát zoznamu kDrive: ${value.runtimeType}.');
    final root = Map<String,dynamic>.from(value);
    final data = root['data'] is Map ? Map<String,dynamic>.from(root['data'] as Map) : <String,dynamic>{};
    final pagination = root['pagination'] is Map ? Map<String,dynamic>.from(root['pagination'] as Map) : (data['pagination'] is Map ? Map<String,dynamic>.from(data['pagination'] as Map) : <String,dynamic>{});
    dynamic raw = root['data'];
    if (raw is Map) raw = data['files'] ?? data['items'] ?? data['results'] ?? data['entries'] ?? data['children'] ?? data['data'];
    raw ??= root['files'] ?? root['items'] ?? root['results'] ?? root['entries'] ?? root['children'];
    if (raw is! List) throw FormatException('Zoznam položiek priečinka kDrive nemá očakávaný formát. Root kľúče: ${root.keys.join(', ')}; data typ: ${root['data']?.runtimeType}.');
    final items = raw.whereType<Map>().map((e) => Map<String,dynamic>.from(e)).toList();
    final explicitMore = root['has_more'] ?? root['hasMore'] ?? data['has_more'] ?? data['hasMore'] ?? pagination['has_more'] ?? pagination['hasMore'];
    final perPage = int.tryParse('${root['items_per_page'] ?? data['items_per_page'] ?? pagination['items_per_page'] ?? ''}');
    final more = explicitMore == true || (explicitMore == null && perPage != null && raw.length >= perPage);
    final cursorValue = root['cursor'] ?? root['next_cursor'] ?? root['nextCursor'] ?? data['cursor'] ?? data['next_cursor'] ?? data['nextCursor'] ?? pagination['cursor'] ?? pagination['next_cursor'] ?? pagination['nextCursor'];
    return _Page(items, more, cursorValue?.toString(), 'server_page=${root['page'] ?? data['page'] ?? pagination['page'] ?? '-'}; items_per_page=${root['items_per_page'] ?? data['items_per_page'] ?? pagination['items_per_page'] ?? '-'}; explicit_has_more=${explicitMore ?? 'nevrátené'}; kľúče root=${root.keys.join(',')}; data=${data.keys.join(',')}; pagination=${pagination.keys.join(',')}');
  }
}
class _Page { const _Page(this.items,this.hasMore,this.cursor,this.responseKeys); final List<Map<String,dynamic>> items; final bool hasMore; final String? cursor; final String responseKeys; }
class LibraryResult { const LibraryResult(this.tracks,this.diagnostics); final List<Track> tracks; final List<String> diagnostics; }

class _LibrarySkeleton extends StatelessWidget {
  const _LibrarySkeleton({required this.completed, required this.total, required this.failures, required this.stage});
  final int completed;
  final int total;
  final int failures;
  final String stage;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Padding(
        padding: EdgeInsets.fromLTRB(20, 18, 20, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Pripravujem tvoju hudbu', style: TextStyle(fontSize: 23, fontWeight: FontWeight.w800)),
          SizedBox(height: 5),
          Text('Načítavam prvých 100 skladieb a ich obaly…', style: TextStyle(color: _muted, fontSize: 13)),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: total == 0 ? null : (completed / total).clamp(0.0, 1.0).toDouble(),
              minHeight: 4,
              backgroundColor: _surface2,
              color: _green,
            ),
          ),
          const SizedBox(height: 7),
          Text("$stage: $completed z $total${failures > 0 ? ' • neúspešné: $failures' : ''}", style: const TextStyle(color: _muted, fontSize: 11)),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Container(
          height: 49,
          decoration: BoxDecoration(color: _surface, borderRadius: BorderRadius.circular(15)),
        ),
      ),
      Expanded(
        child: ListView.builder(
          itemCount: 100,
          padding: const EdgeInsets.fromLTRB(12, 2, 12, 14),
          itemBuilder: (context, index) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Container(
              height: 67,
              padding: const EdgeInsets.all(9),
              decoration: BoxDecoration(color: _surface.withValues(alpha: .55), borderRadius: BorderRadius.circular(15)),
              child: Row(children: [
                Container(width: 49, height: 49, decoration: BoxDecoration(color: _surface2, borderRadius: BorderRadius.circular(12))),
                const SizedBox(width: 12),
                Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  FractionallySizedBox(widthFactor: index % 3 == 0 ? .58 : .78, child: Container(height: 10, decoration: BoxDecoration(color: _surface2, borderRadius: BorderRadius.circular(5)))),
                  const SizedBox(height: 9),
                  FractionallySizedBox(widthFactor: .38, child: Container(height: 7, decoration: BoxDecoration(color: _surface2, borderRadius: BorderRadius.circular(4)))),
                ])),
              ]),
            ),
          ),
        ),
      ),
    ],
  );
}

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});
  @override State<LibraryPage> createState() => _LibraryPageState();
}
class _LibraryPageState extends State<LibraryPage> {
  final _service = KDriveService();
  late Future<LibraryResult> _future;
  late final AudioPlayer _player;
  List<Track>? _loadedTracks;
  final ValueNotifier<List<Track>> _tracksListenable = ValueNotifier<List<Track>>(<Track>[]);
  ConcatenatingAudioSource? _playlistSource;
  Future<void> _playlistMutation = Future<void>.value();
  int _initialArtworkCompleted = 0;
  int _initialArtworkTotal = 100;
  int _initialArtworkFailures = 0;
  String _initialArtworkStage = 'Sťahujem a kontrolujem obaly';
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  int? _currentIndex;
  bool _loadingTrack = false;
  List<Track>? _cachedTracks;
  bool _playlistReady = false;
  List<String> _playlistTrackIds = <String>[];
  final Set<String> _artworkHasImage = <String>{};
  final Set<String> _artworkRequested = <String>{};
  final Set<String> _artworkChecked = <String>{};
  final Map<String, ValueNotifier<File?>> _trackArtwork = <String, ValueNotifier<File?>>{};
  final List<Track> _artworkQueue = <Track>[];
  int _activeArtworkWorkers = 0;
  Directory? _artworkCacheDirectory;
  final http.Client _artworkClient = http.Client();
  String _sort = sortNameAsc;
  bool _flacOnly = false;
  int _loadGeneration = 0;
  String? _currentTrackId;
  final ValueNotifier<String?> _currentTrackIdListenable = ValueNotifier<String?>(null);
  bool _queueRebuilding = false;
  // Kontext (zoradenie a filter), s ktorým bola postavená aktuálna prehrávacia fronta.
  String _queueSort = sortNameAsc;
  bool _queueFlacOnly = false;
  String _queueQuery = '';

  @override void initState() {
    super.initState();
    _future = _loadLibrary();
    _player = AudioPlayer();
    _player.currentIndexStream.listen((index) { if (index != null) _syncCurrentTrack(); });
  }
  @override void dispose() { _searchFocus.dispose(); _search.dispose(); _tracksListenable.dispose(); _currentTrackIdListenable.dispose(); for (final notifier in _trackArtwork.values) { notifier.dispose(); } _artworkClient.close(); _service._client.close(); _player.dispose(); super.dispose(); }
  void _dismissSearchKeyboard() {
    _searchFocus.unfocus();
    FocusManager.instance.primaryFocus?.unfocus();
    SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
  }
  Future<void> _reload() async {
    _loadGeneration++; // zneplatní prebiehajúce načítanie a jeho callbacky
    await _player.stop();
    if (!mounted) return;
    _playlistReady = false;
    _playlistTrackIds = <String>[];
    _currentIndex = null;
    _currentTrackId = null;
    _currentTrackIdListenable.value = null;
    _queueRebuilding = false;
    _cachedTracks = null;
    _loadedTracks = null;
    _tracksListenable.value = <Track>[];
    _playlistSource = null;
    _artworkRequested.clear();
    _artworkChecked.clear();
    _artworkQueue.clear();
    _initialArtworkCompleted = 0;
    _initialArtworkTotal = 100;
    _initialArtworkFailures = 0;
    _initialArtworkStage = 'Sťahujem a kontrolujem obaly';
    if (!mounted) return;
    setState(() => _future = _loadLibrary());
  }


  Future<LibraryResult> _loadLibrary() {
    final generation = _loadGeneration;
    return _service.loadAudioTracks(
      isCancelled: () => _isStale(generation),
      onInitialBatchReady: (tracks) => _handleInitialBatchReady(tracks, generation),
      onProgress: (tracks) => _handleLibraryProgress(tracks, generation),
    );
  }

  bool _isStale(int generation) => !mounted || generation != _loadGeneration;

  Future<void> _handleInitialBatchReady(List<Track> tracks, int generation) async {
    if (_isStale(generation)) return;
    _initialArtworkTotal = tracks.length;
    _initialArtworkCompleted = 0;
    _initialArtworkFailures = 0;
    _initialArtworkStage = 'Sťahujem a kontrolujem obaly';
    setState(() {});
    await _prefetchArtwork(tracks, onProgress: (done, total) {
      if (_isStale(generation)) return;
      _initialArtworkCompleted = done;
      _initialArtworkTotal = total;
      setState(() {});
    });
    if (_isStale(generation)) return;
    _initialArtworkStage = 'Pripravujem obrázky na zobrazenie';
    _initialArtworkCompleted = 0;
    setState(() {});
    await _precacheInitialArtwork(tracks, onProgress: (done, total) {
      if (_isStale(generation)) return;
      _initialArtworkCompleted = done;
      _initialArtworkTotal = total;
      setState(() {});
    });
    if (_isStale(generation)) return;
    _loadedTracks = tracks;
    _tracksListenable.value = tracks;
    setState(() {});
  }

  Future<void> _handleLibraryProgress(List<Track> tracks, int generation) async {
    if (_isStale(generation)) return;
    _loadedTracks = tracks;
    _tracksListenable.value = tracks;
    setState(() {});
    await _appendTracksToPlaylist(tracks, generation: generation);
  }

  /// Zaradí zmeny fronty za seba, aby sa nikdy neprekrývali.
  Future<T> _serializePlaylist<T>(Future<T> Function() action) async {
    final previous = _playlistMutation;
    final gate = Completer<void>();
    _playlistMutation = gate.future;
    await previous;
    try {
      return await action();
    } finally {
      gate.complete();
    }
  }

  /// Doplní do fronty novo objavené skladby tak, aby fronta mala rovnaké
  /// poradie a filter, s akým sa začalo prehrávanie.
  Future<void> _appendTracksToPlaylist(List<Track> tracks, {int? generation}) {
    if (tracks.isEmpty) return Future<void>.value();
    return _serializePlaylist<void>(() async {
      if (generation != null && _isStale(generation)) return;
      final source = _playlistSource;
      if (!_playlistReady || source == null) return;
      final desired = orderTracks(tracks, sort: _queueSort, flacOnly: _queueFlacOnly, query: _queueQuery);
      for (var index = 0; index < desired.length; index++) {
        final track = desired[index];
        if (index < _playlistTrackIds.length && _playlistTrackIds[index] == track.id) {
          continue;
        }
        if (_playlistTrackIds.contains(track.id)) {
          continue;
        }
        final insertAt = index > _playlistTrackIds.length ? _playlistTrackIds.length : index;
        try {
          await source.insert(insertAt, _audioSourceFor(track));
        } catch (_) {
          // Aktualizácia knižnice nesmie prerušiť aktuálne prehrávanie.
          break;
        }
        _playlistTrackIds.insert(insertAt, track.id);
        _syncCurrentTrack();
      }
    });
  }

  Track? _trackForId(String? id) {
    if (id == null) return null;
    final tracks = _loadedTracks ?? _cachedTracks;
    if (tracks == null) return null;
    for (final track in tracks) {
      if (track.id == id) return track;
    }
    return null;
  }

  /// Zosúladí aktuálnu skladbu (podľa ID) s indexom, na ktorom je prehrávač.
  void _syncCurrentTrack() {
    if (!mounted || _queueRebuilding) return;
    final index = _player.currentIndex;
    if (index == null) return;
    final id = index >= 0 && index < _playlistTrackIds.length ? _playlistTrackIds[index] : null;
    if (index == _currentIndex && id == _currentTrackId) return;
    setState(() {
      _currentIndex = index;
      _currentTrackId = id;
    });
    _currentTrackIdListenable.value = id;
    final track = _trackForId(id);
    if (track != null) _loadArtwork(track);
  }

  AudioSource _audioSourceFor(Track track) => AudioSource.uri(
    _service._downloadUri(track.id),
    tag: MediaItem(id: track.id, title: titleOf(track.name), artist: parseArtist(track.name), album: 'MusiFy'),
  );

  Future<void> _prefetchArtwork(
    List<Track> tracks, {
    void Function(int completed, int total)? onProgress,
  }) async {
    var next = 0;
    var completed = 0;
    Future<void> worker() async {
      while (true) {
        final index = next++;
        if (index >= tracks.length) return;
        await _loadArtwork(tracks[index]);
        if (!_artworkChecked.contains(tracks[index].id)) _initialArtworkFailures++;
        completed++;
        if (completed % 5 == 0 || completed == tracks.length) {
          onProgress?.call(completed, tracks.length);
        }
      }
    }
    final workers = tracks.length < 6 ? tracks.length : 6;
    await Future.wait(List.generate(workers, (_) => worker()));
  }

  Future<void> _precacheInitialArtwork(
    List<Track> tracks, {
    required void Function(int completed, int total) onProgress,
  }) async {
    if (!mounted) return;
    final pixelSize = (49 * MediaQuery.devicePixelRatioOf(context)).round();
    var next = 0;
    var completed = 0;
    Future<void> worker() async {
      while (true) {
        final index = next++;
        if (index >= tracks.length) return;
        if (!mounted) return;
        final file = _artworkNotifier(tracks[index].id).value;
        if (file != null) {
          var failed = false;
          try {
            final provider = ResizeImage.resizeIfNeeded(
              pixelSize,
              pixelSize,
              FileImage(file),
            );
            await precacheImage(
              provider,
              context,
              onError: (error, stackTrace) { failed = true; },
            );
          } catch (_) {
            failed = true;
          }
          if (failed) _initialArtworkFailures++;
        }
        completed++;
        if (completed % 5 == 0 || completed == tracks.length) {
          onProgress(completed, tracks.length);
        }
      }
    }

    final workers = tracks.length < 6 ? tracks.length : 6;
    await Future.wait(List.generate(workers, (_) => worker()));
  }

  ValueNotifier<File?> _artworkNotifier(String id) =>
      _trackArtwork.putIfAbsent(id, () => ValueNotifier<File?>(null));

  void _publishArtwork(String id, File imageFile) {
    _artworkHasImage.add(id);
    _artworkNotifier(id).value = imageFile;
  }

  void _prioritizeArtwork(Track track) {
    if (!track.name.toLowerCase().endsWith('.flac')) return;
    if (_artworkChecked.contains(track.id)) {
      if (_artworkHasImage.contains(track.id) && _artworkNotifier(track.id).value == null) {
        _loadArtwork(track); // Restore the file reference from the disk cache if needed.
      }
      return;
    }
    if (_artworkRequested.contains(track.id)) return;
    final queuedIndex = _artworkQueue.indexWhere((item) => item.id == track.id);
    if (queuedIndex > 0) {
      final queued = _artworkQueue.removeAt(queuedIndex);
      _artworkQueue.insert(0, queued);
    } else if (queuedIndex < 0) {
      _artworkQueue.insert(0, track);
    }
    _pumpArtworkQueue();
  }

  void _pumpArtworkQueue() {
    while (_activeArtworkWorkers < 4 && _artworkQueue.isNotEmpty) {
      final track = _artworkQueue.removeAt(0);
      _activeArtworkWorkers++;
      _loadArtwork(track).whenComplete(() {
        _activeArtworkWorkers--;
        _pumpArtworkQueue();
      });
    }
  }

  Future<Directory> _getArtworkCacheDirectory() async {
    final directory = _artworkCacheDirectory ??=
        Directory('${(await getApplicationSupportDirectory()).path}/artwork');
    await directory.create(recursive: true);
    return directory;
  }

  String _artworkCacheName(Track track) =>
      base64Url.encode(utf8.encode('${track.id}|${track.size}|${track.revision}')).replaceAll('=', '');

  Future<void> _loadArtwork(Track track) async {
    if (!track.name.toLowerCase().endsWith('.flac')) {
      _artworkChecked.add(track.id);
      return;
    }
    if (_artworkChecked.contains(track.id)) {
      if (!_artworkHasImage.contains(track.id) || _artworkNotifier(track.id).value != null) return;
      if (!_artworkRequested.add(track.id)) return;
      try {
        final directory = await _getArtworkCacheDirectory();
        final cached = File('${directory.path}/${_artworkCacheName(track)}.img');
        if (await cached.exists() && await cached.length() > 0) {
          _publishArtwork(track.id, cached);
        } else {
          _artworkHasImage.remove(track.id);
          _artworkChecked.remove(track.id);
        }
      } catch (_) {
        _artworkHasImage.remove(track.id);
        _artworkChecked.remove(track.id);
      } finally {
        _artworkRequested.remove(track.id);
      }
      return;
    }
    if (!_artworkRequested.add(track.id)) return;
    try {
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          final directory = await _getArtworkCacheDirectory();
          final cacheName = _artworkCacheName(track);
          final cached = File('${directory.path}/$cacheName.img');
          if (await cached.exists()) {
            try {
              final length = await cached.length();
              if (length > 0) {
                _artworkChecked.add(track.id);
                _publishArtwork(track.id, cached);
                return;
              }
              await cached.delete();
            } catch (_) {
              // A damaged artwork cache entry is disposable; fetch it again.
            }
          }
          final noArtworkMarker = File('${directory.path}/$cacheName.none');
          if (await noArtworkMarker.exists()) {
            _artworkChecked.add(track.id);
            _artworkHasImage.remove(track.id);
            return;
          }

          final bytes = <int>[];
          Uint8List? image;
          var metadataComplete = false;
          var start = 0;
          const rangeEnds = <int>[262143, 1048575, 4194303, 8388607];
          for (final end in rangeEnds) {
            final request = http.Request('GET', _service._downloadUri(track.id));
            request.headers['Accept'] = 'audio/flac, application/octet-stream, */*';
            request.headers['Range'] = 'bytes=$start-$end';
            final response = await _artworkClient.send(request).timeout(const Duration(seconds: 25));
            if (response.statusCode != 200 && response.statusCode != 206) {
              throw HttpException('Artwork HTTP ${response.statusCode}');
            }
            await for (final chunk in response.stream.timeout(const Duration(seconds: 20))) {
              const metadataLimit = 8 * 1024 * 1024;
              final remaining = metadataLimit - bytes.length;
              if (remaining <= 0) {
                throw const FormatException('FLAC metadáta prekročili limit 8 MB.');
              }
              if (chunk.length > remaining) {
                bytes.addAll(chunk.take(remaining));
              } else {
                bytes.addAll(chunk);
              }
              final parsed = readFlacPicture(bytes);
              if (parsed.complete) {
                metadataComplete = true;
                image = parsed.image;
                break;
              }
              if (bytes.length >= metadataLimit) {
                throw const FormatException('FLAC metadáta prekročili limit 8 MB.');
              }
            }
            if (metadataComplete) break;
            if (response.statusCode == 200) {
              throw const FormatException('Server ignoroval Range a metadáta sa nepodarilo dokončiť.');
            }
            start = end + 1;
          }
          if (!metadataComplete) {
            throw const FormatException('FLAC PICTURE metadáta sa nezmestili do rozsahu 8 MB.');
          }

          if (image != null && image.isNotEmpty) {
            final target = File('${directory.path}/${_artworkCacheName(track)}.img');
            final temporary = File('${target.path}.tmp');
            await temporary.writeAsBytes(image, flush: true);
            if (await target.exists()) await target.delete();
            await temporary.rename(target.path);
            final noArtworkMarker = File('${directory.path}/${_artworkCacheName(track)}.none');
            if (await noArtworkMarker.exists()) await noArtworkMarker.delete();
            _artworkChecked.add(track.id);
            _publishArtwork(track.id, target);
          } else {
            final marker = File('${directory.path}/${_artworkCacheName(track)}.none');
            final temporaryMarker = File('${marker.path}.tmp');
            await temporaryMarker.writeAsString('no-picture', flush: true);
            if (await marker.exists()) await marker.delete();
            await temporaryMarker.rename(marker.path);
            _artworkHasImage.remove(track.id);
            _artworkChecked.add(track.id);
          }
          return;
        } catch (_) {
          if (attempt == 1) rethrow;
          await Future.delayed(Duration(milliseconds: 350 * (attempt + 1)));
        }
      }
    } catch (_) {
      // Artwork failures never block library loading or audio playback.
    } finally {
      _artworkRequested.remove(track.id);
    }
  }

  Widget _artworkOrFallback(String trackId, int index, {double size = 49, double iconSize = 25}) {
    return ValueListenableBuilder<File?>(
      valueListenable: _artworkNotifier(trackId),
      builder: (context, file, _) {
        final pixelSize = (size * MediaQuery.devicePixelRatioOf(context)).round();
        return Container(
          width: size, height: size,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(size * .24),
            gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
              colors: [[_green, const Color(0xFF1D7043), const Color(0xFF285C70), const Color(0xFF6B3D8E)][index % 4], _surface2]),
          ),
          clipBehavior: Clip.antiAlias,
          child: file != null
              ? Image.file(file, fit: BoxFit.cover, gaplessPlayback: true, cacheWidth: pixelSize, cacheHeight: pixelSize,
                  errorBuilder: (context, error, stackTrace) => Center(child: Icon(Icons.music_note_rounded, color: Colors.white70, size: iconSize)))
              : Center(child: Icon(Icons.music_note_rounded, color: Colors.white70, size: iconSize)),
        );
      },
    );
  }

  Future<void> _playTrack(String trackId) async {
    final tracks = _loadedTracks ?? (await _future).tracks;
    // Fronta sa stavia v rovnakom poradí a s rovnakým filtrom ako zobrazený zoznam.
    final queue = orderTracks(tracks, sort: _sort, flacOnly: _flacOnly, query: _search.text);
    final index = queue.indexWhere((track) => track.id == trackId);
    if (index < 0) return;
    setState(() { _currentIndex = index; _currentTrackId = trackId; _loadingTrack = true; });
    _currentTrackIdListenable.value = trackId;
    _loadArtwork(queue[index]);
    try {
      final query = _search.text.trim().toLowerCase();
      final contextChanged = _queueSort != _sort || _queueFlacOnly != _flacOnly || _queueQuery != query;
      var rebuild = !_playlistReady || _playlistSource == null || contextChanged;
      if (!rebuild) {
        await _appendTracksToPlaylist(tracks);
        rebuild = !_playlistTrackIds.contains(trackId);
      }
      if (rebuild) {
        final queueIds = queue.map((track) => track.id).toList(growable: false);
        await _serializePlaylist<void>(() async {
          _queueRebuilding = true;
          _playlistReady = false;
          try {
            final source = ConcatenatingAudioSource(
              children: queue.map(_audioSourceFor).toList(growable: false),
            );
            _playlistSource = source;
            _playlistTrackIds = List<String>.of(queueIds);
            _queueSort = _sort;
            _queueFlacOnly = _flacOnly;
            _queueQuery = query;
            await _player.setAudioSource(source, initialIndex: index, initialPosition: Duration.zero);
            _playlistReady = true;
          } catch (_) {
            _playlistSource = null;
            _playlistTrackIds = <String>[];
            rethrow;
          } finally {
            _queueRebuilding = false;
          }
        });
        _syncCurrentTrack();
        await _appendTracksToPlaylist(_loadedTracks ?? tracks);
      } else {
        await _player.seek(Duration.zero, index: _playlistTrackIds.indexOf(trackId));
      }
      final playbackFuture = _player.play();
      if (mounted) setState(() => _loadingTrack = false);
      await playbackFuture;
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Skladbu sa nepodarilo prehrať: $error')));
    } finally {
      if (mounted) setState(() => _loadingTrack = false);
    }
  }
  Future<void> _togglePlayback() async {
    if (_player.playing) { await _player.pause(); }
    else if (_currentIndex != null) { await _player.play(); }
  }
  String _size(int bytes) {
    if (bytes <= 0) return '';
    final mb = bytes / 1048576;
    return mb >= 1024 ? '${(mb/1024).toStringAsFixed(1)} GB' : '${mb.toStringAsFixed(1)} MB';
  }
  String _artist(String name) => artistOf(name);
  String _title(String name) => titleOf(name);
  List<Track> _visible(List<Track> tracks) =>
      orderTracks(tracks, sort: _sort, flacOnly: _flacOnly, query: _search.text);

  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      toolbarHeight: 68,
      titleSpacing: 20,
      title: Row(children: [
        ClipRRect(borderRadius: BorderRadius.circular(9),child: Image.asset('assets/images/musify_logo.jpg',width:46,height:46,fit:BoxFit.contain)),
        const SizedBox(width:11),
        const Text('Musi',style:TextStyle(fontSize:23,fontWeight:FontWeight.w800,letterSpacing:-.7)),
        const Text('Fy',style:TextStyle(fontSize:23,fontWeight:FontWeight.w800,color:_green,letterSpacing:-.7)),
      ]),
      actions: [
        IconButton(tooltip:'Obnoviť knižnicu',onPressed:_reload,icon:const Icon(Icons.refresh_rounded)),
        IconButton(tooltip:'Nastavenia',onPressed:()=>_showSettings(),icon:const Icon(Icons.tune_rounded)),
        const SizedBox(width:6),
      ],
    ),
    body: FutureBuilder<LibraryResult>(
      future:_future,
      builder:(context,snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting && _loadedTracks == null) {
          return _LibrarySkeleton(completed: _initialArtworkCompleted, total: _initialArtworkTotal, failures: _initialArtworkFailures, stage: _initialArtworkStage);
        }
        if (snapshot.hasError && _loadedTracks == null) {
          return Center(child:Padding(padding:const EdgeInsets.all(28),child:Column(mainAxisSize:MainAxisSize.min,children:[const Icon(Icons.cloud_off_rounded,size:60,color:_muted),const SizedBox(height:16),const Text('Knižnicu sa nepodarilo načítať',style:TextStyle(fontSize:19,fontWeight:FontWeight.w700)),const SizedBox(height:8),Text('${snapshot.error}',textAlign:TextAlign.center,style:const TextStyle(color:_muted)),const SizedBox(height:18),FilledButton.icon(onPressed:_reload,icon:const Icon(Icons.refresh),label:const Text('Skúsiť znova'))])));
        }
        final tracks = snapshot.data?.tracks ?? _loadedTracks ?? const <Track>[];
        _cachedTracks = tracks;
        final visible = _visible(tracks);
        return Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          Padding(padding:const EdgeInsets.fromLTRB(20,12,20,14),child:Row(crossAxisAlignment:CrossAxisAlignment.end,children:[
            Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[const Text('Tvoja hudba',style:TextStyle(fontSize:25,fontWeight:FontWeight.w800,letterSpacing:-.6)),const SizedBox(height:3),Text(snapshot.hasError ? 'Synchronizácia zvyšku knižnice zlyhala' : snapshot.connectionState == ConnectionState.waiting ? 'Načítavam ďalšie skladby na pozadí…' : (_initialArtworkFailures > 0 ? 'Niektoré obaly sa nepodarilo načítať' : 'Hudobná knižnica'),style:const TextStyle(color:_muted,fontSize:13))])),
            Container(padding:const EdgeInsets.symmetric(horizontal:12,vertical:7),decoration:BoxDecoration(color:_surface2,borderRadius:BorderRadius.circular(20)),child:Text('${tracks.length} skladieb',style:const TextStyle(color:_green,fontWeight:FontWeight.w700,fontSize:12))),
          ])),
          Padding(padding:const EdgeInsets.symmetric(horizontal:16),child:Container(height:50,decoration:BoxDecoration(color:_surface,borderRadius:BorderRadius.circular(16),border:Border.all(color:const Color(0xFF27332A))),child:TextField(controller:_search,focusNode:_searchFocus,textInputAction:TextInputAction.search,onSubmitted:(_)=>_dismissSearchKeyboard(),onTapOutside:(_)=>_dismissSearchKeyboard(),onChanged:(_)=>setState((){}),style:const TextStyle(fontSize:14),decoration:InputDecoration(hintText:'Hľadať skladbu alebo interpreta…',hintStyle:const TextStyle(color:_muted,fontSize:14),prefixIcon:const Icon(Icons.search_rounded,color:_muted),suffixIcon:_search.text.isEmpty?null:IconButton(onPressed:(){_search.clear();setState((){});},icon:const Icon(Icons.close_rounded)),border:InputBorder.none,contentPadding:const EdgeInsets.symmetric(vertical:14))))),
          const SizedBox(height:13),
          Padding(padding:const EdgeInsets.symmetric(horizontal:16),child:Row(children:[
            _filterChip('Všetky',flacOnly:false),
            const SizedBox(width:8),_filterChip('FLAC',flacOnly:true),
            const Spacer(),
            PopupMenuButton<String>(onSelected:(v)=>setState(()=>_sort=v),itemBuilder:(_)=>const [PopupMenuItem(value:sortNameAsc,child:Text('Názov A–Z')),PopupMenuItem(value:sortNameDesc,child:Text('Názov Z–A')),PopupMenuItem(value:sortArtist,child:Text('Interpret'))],child:Container(padding:const EdgeInsets.symmetric(horizontal:11,vertical:8),decoration:BoxDecoration(color:_surface,borderRadius:BorderRadius.circular(12)),child:Row(children:[const Icon(Icons.sort_rounded,size:17,color:_green),const SizedBox(width:5),Text(_sort,style:const TextStyle(fontSize:12))]))),
          ])),
          const SizedBox(height:8),
          Expanded(child:visible.isEmpty?const Center(child:Text('Žiadne skladby nezodpovedajú vyhľadávaniu.',style:TextStyle(color:_muted))):ListView.builder(cacheExtent:700,padding:const EdgeInsets.fromLTRB(12,4,12,14),itemCount:visible.length,itemBuilder:(context,i){
            final track=visible[i]; final active=_currentTrackId==track.id;
            _prioritizeArtwork(track);
            final details=[_artist(track.name),if(_size(track.size).isNotEmpty)_size(track.size)].join('  •  ');
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Material(
                color: active ? const Color(0xFF18251B) : Colors.transparent,
                borderRadius: BorderRadius.circular(15),
                child: InkWell(
                  borderRadius: BorderRadius.circular(15),
                  onTap: () => _playTrack(track.id),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 9),
                    child: Row(children: [
                      _artworkOrFallback(track.id, i),
                      const SizedBox(width: 12),
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(_title(track.name), maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 14, fontWeight: active ? FontWeight.w700 : FontWeight.w500, color: active ? _green : Colors.white)),
                        const SizedBox(height: 4),
                        Text(details, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: _muted, fontSize: 11)),
                      ])),
                      const SizedBox(width: 6),
                      active ? const Icon(Icons.graphic_eq_rounded, color: _green, size: 22) : const SizedBox(width: 22),
                    ]),
                  ),
                ),
              ),
            );
          })),
        ]);
      },
    ),
    bottomNavigationBar:_currentIndex==null?null:_miniPlayer(),
  );

  Widget _filterChip(String label,{required bool flacOnly}) {
    final selected=_flacOnly==flacOnly;
    return ChoiceChip(label:Text(label),selected:selected,onSelected:(_)=>setState(()=>_flacOnly=flacOnly),showCheckmark:false,labelStyle:TextStyle(fontSize:12,fontWeight:FontWeight.w700,color:selected?_bg:_muted),selectedColor:_green,backgroundColor:_surface,side:BorderSide(color:selected?_green:const Color(0xFF29342C)),padding:const EdgeInsets.symmetric(horizontal:8));
  }
  Widget _miniPlayer()=>SafeArea(top:false,child:GestureDetector(onTap:_openPlayer,child:Container(
    margin:const EdgeInsets.fromLTRB(10,0,10,7),
    padding:const EdgeInsets.fromLTRB(14,15,10,14),
    decoration:BoxDecoration(color:_surface2,borderRadius:BorderRadius.circular(18),border:Border.all(color:const Color(0xFF344238))),
    child:Column(mainAxisSize:MainAxisSize.min,children:[
      Row(crossAxisAlignment:CrossAxisAlignment.center,children:[
        _currentTrackId!=null?_artworkOrFallback(_currentTrackId!,_currentIndex??0,size:59,iconSize:30):const SizedBox(width:59,height:59),const SizedBox(width:12),
        Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          Text(_title(_trackTitle()),maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(fontWeight:FontWeight.w700,fontSize:14)),
          const SizedBox(height:3),Text(_miniSubtitle(),style:const TextStyle(color:_muted,fontSize:12)),
        ])),
        IconButton(tooltip:'Predchádzajúca skladba',constraints:const BoxConstraints(minWidth:56,minHeight:60),onPressed:_currentIndex==null||_currentIndex!<=0?null:()=>_player.seekToPrevious(),icon:const Icon(Icons.skip_previous_rounded,size:34)),
        StreamBuilder<PlayerState>(stream:_player.playerStateStream,builder:(context,snapshot){
          final playing=snapshot.data?.playing??false;
          return IconButton(tooltip:playing?'Pozastaviť':'Prehrať',constraints:const BoxConstraints(minWidth:65,minHeight:65),onPressed:_loadingTrack?null:_togglePlayback,icon:_loadingTrack?const SizedBox(width:28,height:28,child:CircularProgressIndicator(strokeWidth:2,color:_green)):Icon(playing?Icons.pause_circle_filled_rounded:Icons.play_circle_fill_rounded,color:_green,size:48));
        }),
        IconButton(tooltip:'Nasledujúca skladba',constraints:const BoxConstraints(minWidth:56,minHeight:60),onPressed:_currentIndex==null?null:()=>_player.seekToNext(),icon:const Icon(Icons.skip_next_rounded,size:34)),
      ]),
      StreamBuilder<Duration>(stream:_player.positionStream,builder:(context,s){
        final duration=_player.duration??Duration.zero;final pos=s.data??Duration.zero;
        final value=duration.inMilliseconds==0?0.0:pos.inMilliseconds.clamp(0,duration.inMilliseconds).toDouble()/duration.inMilliseconds;
        return ClipRRect(borderRadius:BorderRadius.circular(3),child:LinearProgressIndicator(value:value,minHeight:3,backgroundColor:const Color(0xFF3A453D),valueColor:const AlwaysStoppedAnimation(_green)));
      }),
    ]),
  )));

  String _trackTitle()=>_trackForId(_currentTrackId)?.name??'MusiFy';

  String _miniSubtitle() {
    final track=_trackForId(_currentTrackId);
    if (track==null) return 'MusiFy';
    final format=formatLabelOf(track.name);
    return format.isEmpty?_artist(track.name):'${_artist(track.name)}  •  $format';
  }

  void _openPlayer() {
    _dismissSearchKeyboard();
    showModalBottomSheet(context:context,isScrollControlled:true,backgroundColor:Colors.transparent,builder:(context)=>_FullPlayer(player:_player,tracksListenable:_tracksListenable,currentTrackId:_currentTrackIdListenable,trackFor:_trackForId,artworkForTrack:_artworkNotifier));
  }
  void _showSettings()=>showModalBottomSheet(context:context,backgroundColor:_surface,isScrollControlled:true,showDragHandle:true,builder:(context)=>SafeArea(child:Padding(padding:const EdgeInsets.fromLTRB(20,8,20,28),child:Column(mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.start,children:[
    const Text('Nastavenia',style:TextStyle(fontSize:23,fontWeight:FontWeight.w800)),const SizedBox(height:16),
    const ListTile(leading:Icon(Icons.palette_outlined,color:_green),title:Text('Vzhľad'),subtitle:Text('Tmavý motív • zelená akcentová farba')),
    const ListTile(leading:Icon(Icons.cloud_outlined,color:_green),title:Text('Hudobná knižnica'),subtitle:Text('Zdroj: verejný priečinok kDrive')),
    ExpansionTile(
      leading: const Icon(Icons.monitor_heart_outlined, color: _green),
      title: const Text('Diagnostika prehrávania'),
      children: [
        StreamBuilder<MediaItem?>(
          stream: AudioService.currentMediaItemStream,
          builder: (context, mediaSnapshot) => StreamBuilder<PlaybackState>(
            stream: AudioService.playbackStateStream,
            builder: (context, stateSnapshot) {
              final media = mediaSnapshot.data;
              final state = stateSnapshot.data;
              final lines = [
                'MediaItem: ${media?.title ?? 'ŽIADNA'}',
                'Prehrávanie: ${state?.playing ?? 'bez dát'}',
                'ProcessingState: ${state?.processingState ?? 'bez dát'}',
                'Ovládacie prvky: ${state?.controls.map((c) => c.toString()).join(', ') ?? '-'}',
                'AudioPlayer: ${_player.playing} / index ${_player.currentIndex}',
              ];
              return Padding(
                padding: const EdgeInsets.all(12),
                child: SelectableText(lines.join('\n'), style: const TextStyle(color: _muted, fontSize: 11)),
              );
            },
          ),
        ),
      ],
    ),
    ExpansionTile(
      leading: const Icon(Icons.library_music_outlined, color: _green),
      title: const Text('Diagnostika knižnice'),
      children: [
        FutureBuilder<LibraryResult>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Padding(
                padding: EdgeInsets.all(12),
                child: Text('Načítavam diagnostiku knižnice…', style: TextStyle(color: _muted)),
              );
            }
            if (snapshot.hasError) {
              return Padding(
                padding: const EdgeInsets.all(12),
                child: SelectableText('Chyba načítania: ${snapshot.error}', style: const TextStyle(color: _muted, fontSize: 11)),
              );
            }
            final result = snapshot.data;
            if (result == null) {
              return const Padding(
                padding: EdgeInsets.all(12),
                child: Text('Diagnostické údaje nie sú dostupné.', style: TextStyle(color: _muted)),
              );
            }
            final report = result.diagnostics.join('\n');
            return Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: report));
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Diagnostika skopírovaná do schránky')),
                          );
                        }
                      },
                      icon: const Icon(Icons.copy_rounded, size: 18),
                      label: const Text('Kopírovať diagnostiku'),
                    ),
                  ),
                  SelectableText(report, style: const TextStyle(color: _muted, fontSize: 11)),
                ],
              ),
            );
          },
        ),
      ],
    ),
  ]))));
}

class _FullPlayer extends StatelessWidget {
  const _FullPlayer({required this.player,required this.tracksListenable,required this.currentTrackId,required this.trackFor,required this.artworkForTrack});
  final AudioPlayer player;
  final ValueListenable<List<Track>> tracksListenable;
  final ValueListenable<String?> currentTrackId;
  final Track? Function(String?) trackFor;
  final ValueListenable<File?> Function(String) artworkForTrack;
  String _artist(String name)=>artistOf(name);
  String _title(String name)=>titleOf(name);
  @override
  Widget build(BuildContext context) {
    return Container(
      height:MediaQuery.of(context).size.height*.88,
      decoration:const BoxDecoration(color:_surface,borderRadius:BorderRadius.vertical(top:Radius.circular(28))),
      child:SafeArea(
        child:Padding(
          padding:const EdgeInsets.fromLTRB(22,8,22,20),
          child:ValueListenableBuilder<List<Track>>(
            valueListenable: tracksListenable,
            builder: (context, tracks, _) => ValueListenableBuilder<String?>(
            valueListenable: currentTrackId,
            builder:(context,trackId,_) {
              final track=trackFor(trackId);
              final valid=track!=null;
              final name=track?.name??'MusiFy';
              return Column(children:[
                Row(children:[
                  IconButton(onPressed:()=>Navigator.pop(context),icon:const Icon(Icons.keyboard_arrow_down_rounded,size:30)),
                  const Expanded(child:Text('PRÁVE SA PREHRÁVA',textAlign:TextAlign.center,style:TextStyle(color:_muted,fontSize:11,fontWeight:FontWeight.w700,letterSpacing:1.5))),
                  const SizedBox(width:48),
                ]),
                const Spacer(),
                Container(
                  width:MediaQuery.of(context).size.width*.72,
                  height:MediaQuery.of(context).size.width*.72,
                  constraints:const BoxConstraints(maxWidth:320,maxHeight:320),
                  decoration:BoxDecoration(borderRadius:BorderRadius.circular(28),gradient:const LinearGradient(begin:Alignment.topLeft,end:Alignment.bottomRight,colors:[Color(0xFF244A31),Color(0xFF13251B),Color(0xFF263A2C)]),boxShadow:[BoxShadow(color:_green.withValues(alpha: .12),blurRadius:40,spreadRadius:2)]),
                  child: track != null
                    ? ValueListenableBuilder<File?>(
                        valueListenable: artworkForTrack(track.id),
                        builder: (context, imageFile, _) => imageFile == null
                          ? const Center(child:Icon(Icons.graphic_eq_rounded,size:112,color:_green))
                          : ClipRRect(
                              borderRadius:BorderRadius.circular(28),
                              child:Image.file(imageFile,fit:BoxFit.cover,width:double.infinity,height:double.infinity,cacheWidth:640,cacheHeight:640,errorBuilder:(context,error,stackTrace)=>const Center(child:Icon(Icons.graphic_eq_rounded,size:112,color:_green))),
                            ),
                      )
                    : const Center(child:Icon(Icons.graphic_eq_rounded,size:112,color:_green)),
                ),
                const SizedBox(height:34),
                Text(_title(name),key:ValueKey('title-$trackId'),maxLines:2,textAlign:TextAlign.center,overflow:TextOverflow.ellipsis,style:const TextStyle(fontSize:22,fontWeight:FontWeight.w800,letterSpacing:-.4)),
                const SizedBox(height:7),
                Text(valid?_artist(name):'',key:ValueKey('artist-$trackId'),style:const TextStyle(color:_muted,fontSize:14)),
                const SizedBox(height:25),
                _SeekBar(player:player),
                const SizedBox(height:18),
                Row(mainAxisAlignment:MainAxisAlignment.spaceEvenly,children:[
                  IconButton(iconSize:25,onPressed:()=>player.setShuffleModeEnabled(!player.shuffleModeEnabled),icon:StreamBuilder<bool>(stream:player.shuffleModeEnabledStream,builder:(c,s)=>Icon(Icons.shuffle_rounded,color:(s.data??false)?_green:_muted))),
                  IconButton(iconSize:38,onPressed:()=>player.seekToPrevious(),icon:const Icon(Icons.skip_previous_rounded)),
                  StreamBuilder<PlayerState>(stream:player.playerStateStream,builder:(context,s){
                    final playing=s.data?.playing??false;
                    return Container(width:70,height:70,decoration:const BoxDecoration(color:_green,shape:BoxShape.circle),child:IconButton(iconSize:39,color:_bg,onPressed:()=>playing?player.pause():player.play(),icon:Icon(playing?Icons.pause_rounded:Icons.play_arrow_rounded)));
                  }),
                  IconButton(iconSize:38,onPressed:()=>player.seekToNext(),icon:const Icon(Icons.skip_next_rounded)),
                  IconButton(iconSize:25,onPressed:()=>player.setLoopMode(player.loopMode==LoopMode.off?LoopMode.all:LoopMode.off),icon:StreamBuilder<LoopMode>(stream:player.loopModeStream,builder:(c,s)=>Icon(Icons.repeat_rounded,color:(s.data??LoopMode.off)==LoopMode.off?_muted:_green))),
                ]),
                const Spacer(),
              ]);
            },
          ),
          ),
        ),
      ),
    );
  }
}

/// Posuvník prehrávania. Počas ťahania prsta sa len zobrazuje pozícia a skutočné
/// `seek` sa vykoná až po pustení, aby sa streamovaný súbor zbytočne nepretáčal.
class _SeekBar extends StatefulWidget {
  const _SeekBar({required this.player});
  final AudioPlayer player;
  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar> {
  double? _dragValue;

  String _time(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes % 60;
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:${minutes.toString().padLeft(2, '0')}:$seconds' : '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final player = widget.player;
    return StreamBuilder<Duration?>(
      stream: player.durationStream,
      initialData: player.duration,
      builder: (context, durationSnapshot) {
        final duration = durationSnapshot.data ?? Duration.zero;
        return StreamBuilder<Duration>(
          stream: player.positionStream,
          builder: (context, positionSnapshot) {
            final position = positionSnapshot.data ?? Duration.zero;
            final max = duration.inMilliseconds > 0 ? duration.inMilliseconds.toDouble() : 1.0;
            final value = (_dragValue ?? position.inMilliseconds.toDouble()).clamp(0.0, max).toDouble();
            return Column(children: [
              Slider(
                value: value,
                max: max,
                onChanged: (v) => setState(() => _dragValue = v),
                onChangeEnd: (v) async {
                  await player.seek(Duration(milliseconds: v.round()));
                  if (mounted) setState(() => _dragValue = null);
                },
              ),
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Text(_time(Duration(milliseconds: value.round())), style: const TextStyle(color: _muted, fontSize: 12)),
                Text(_time(duration), style: const TextStyle(color: _muted, fontSize: 12)),
              ]),
            ]);
          },
        );
      },
    );
  }
}
