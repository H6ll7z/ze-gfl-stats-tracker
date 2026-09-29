// GFL Zombie Escape Stats
// Pulls your stats from stats.gflclan.com (HLstatsX) using your Steam ID.
//
// pubspec.yaml dependencies needed:
//   http: ^1.2.0
//   html: ^0.15.4
//   shared_preferences: ^2.2.0
//
// Android release builds need this in android/app/src/main/AndroidManifest.xml
// (above <application>):
//   <uses-permission android:name="android.permission.INTERNET"/>

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as dom;
import 'package:shared_preferences/shared_preferences.dart';

const String kBase = 'https://stats.gflclan.com/hlstats.php';
const Color kGreen = Color(0xFF00FF66);
const Color kDim = Color(0xFF148A45);
const Color kYellow = Color(0xFFFFE600);
const Color kRed = Color(0xFFFF4444);
const String kFont = 'monospace';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const GflStatsApp());
}

// ---------------------------------------------------------------- data ----

class TableData {
  final List<String> header;
  final List<List<String>> rows;
  TableData(this.header, this.rows);

  String col(List<String> row, String key) {
    final i = header.indexWhere((h) => h.toLowerCase().contains(key));
    if (i < 0 || i >= row.length) return '-';
    return row[i];
  }
}

class PlayerStats {
  final String name;
  final String url;
  final Map<String, String> summary;
  final TableData? weapons;
  final TableData? maps;
  final TableData? actions;
  PlayerStats(this.name, this.url, this.summary, this.weapons, this.maps,
      this.actions);

  String s(String label) => summary[label] ?? '-';

  /// Sum of "Earned" for actions that look like round wins / escapes.
  int? get roundsWon {
    if (actions == null) return null;
    int total = 0;
    bool found = false;
    for (final r in actions!.rows) {
      final n = actions!.col(r, 'action').toLowerCase();
      if (n.contains('win') || n.contains('escape') || n.contains('round')) {
        found = true;
        total += num_(actions!.col(r, 'earned')).toInt();
      }
    }
    return found ? total : null;
  }
}

double num_(String s) =>
    double.tryParse(s.replaceAll(',', '').replaceAll(RegExp(r'[^0-9.\-]'), '')) ??
    0;

String clean(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

// Strip trailing "(0*)" style bits and stray separators.
String cleanVal(String s) {
  var v = s.split(' (').first.replaceAll('·', '').trim();
  return v.isEmpty ? '-' : v;
}

// ------------------------------------------------------------ steam id ----

/// Accepts SteamID64, STEAM_0:X:Y, or a steamcommunity.com/profiles/<id64> URL.
/// Returns "STEAM_0:X:Y". Vanity URLs (/id/name) can't be resolved without a
/// Steam API key, so those throw.
String toSteam2(String input) {
  final t = input.trim();
  final m2 = RegExp(r'STEAM_[0-5]:([01]):(\d+)', caseSensitive: false)
      .firstMatch(t);
  if (m2 != null) return 'STEAM_0:${m2.group(1)}:${m2.group(2)}';
  final m64 = RegExp(r'7656119\d{10}').firstMatch(t);
  if (m64 != null) {
    final id64 = int.parse(m64.group(0)!);
    final acc = id64 - 76561197960265728;
    return 'STEAM_0:${acc % 2}:${acc ~/ 2}';
  }
  throw Exception(
      'Use your SteamID64 (17 digits), STEAM_0:X:Y, or a /profiles/ URL.');
}

// -------------------------------------------------------------- scraping ----

List<dom.Element> ownRows(dom.Element table) =>
    table.querySelectorAll('tr').where((tr) {
      dom.Element? p = tr.parent;
      while (p != null && p.localName != 'table') {
        p = p.parent;
      }
      return identical(p, table);
    }).toList();

List<String> cellsOf(dom.Element tr) => tr
    .children
    .where((c) => c.localName == 'td' || c.localName == 'th')
    .map((c) => clean(c.text))
    .toList();

TableData? findTable(dom.Document doc, String kind) {
  for (final table in doc.querySelectorAll('table')) {
    final rows = ownRows(table);
    List<String>? header;
    final data = <List<String>>[];
    for (final tr in rows) {
      final cells = cellsOf(tr);
      if (cells.isEmpty) continue;
      if (header == null) {
        if (cells.first.toLowerCase().startsWith('rank') &&
            cells.length < 20 &&
            cells.any((c) => c.toLowerCase().startsWith(kind))) {
          header = cells;
        }
      } else if (cells.length >= 3 && int.tryParse(cells.first) != null) {
        data.add(cells);
      }
    }
    if (header != null && data.isNotEmpty) return TableData(header, data);
  }
  return null;
}

Map<String, String> readSummary(dom.Document doc) {
  final out = <String, String>{};
  for (final tr in doc.querySelectorAll('tr')) {
    if (tr.querySelector('table') != null) continue;
    final cells = cellsOf(tr).where((c) => c.isNotEmpty && c != '·').toList();
    if (cells.length >= 2 && cells[0].endsWith(':')) {
      out.putIfAbsent(cells[0], () => cleanVal(cells[1]));
    }
  }
  return out;
}

Future<http.Response> _get(Uri u) => http.get(u, headers: {
      'User-Agent': 'Mozilla/5.0 (Android) GFLZEStats/1.0',
    }).timeout(const Duration(seconds: 20));

Future<PlayerStats> fetchStats(String input) async {
  final steam2 = toSteam2(input);
  final uniq = steam2.substring('STEAM_0:'.length); // "X:Y"

  final searchUri =
      Uri.parse('$kBase?mode=search&q=$uniq&st=uniqueid&game=');
  var res = await _get(searchUri);
  var url = res.request?.url ?? searchUri;
  var doc = html_parser.parse(res.body);

  // Follow a meta-refresh redirect if the site uses one.
  final meta = doc.querySelector('meta[http-equiv="refresh"]');
  if (meta != null) {
    final m = RegExp(r'url=(.+)', caseSensitive: false)
        .firstMatch(meta.attributes['content'] ?? '');
    if (m != null) {
      url = url.resolve(m.group(1)!.trim());
      res = await _get(url);
      doc = html_parser.parse(res.body);
    }
  }

  // Not on a player page yet -> pick a result link (prefer Zombie Escape).
  if (!url.toString().contains('mode=playerinfo')) {
    final links = doc.querySelectorAll('a').where(
        (a) => (a.attributes['href'] ?? '').contains('mode=playerinfo'));
    if (links.isEmpty) {
      throw Exception(
          'No player found for $steam2 on stats.gflclan.com. '
          'You may not be ranked there yet.');
    }
    dom.Element pick = links.first;
    for (final a in links) {
      dom.Element? p = a.parent;
      while (p != null && p.localName != 'tr') {
        p = p.parent;
      }
      if (p != null && p.text.toLowerCase().contains('zombie')) {
        pick = a;
        break;
      }
    }
    url = url.resolve(pick.attributes['href']!.replaceAll('&amp;', '&'));
    res = await _get(url);
    doc = html_parser.parse(res.body);
  }

  final title = clean(doc.querySelector('title')?.text ?? '');
  final name = title.contains(' - ') ? title.split(' - ').last : 'PLAYER';

  return PlayerStats(
    name,
    url.toString(),
    readSummary(doc),
    findTable(doc, 'weapon'),
    findTable(doc, 'map'),
    findTable(doc, 'action'),
  );
}

// -------------------------------------------------------------------- UI ----

class GflStatsApp extends StatelessWidget {
  const GflStatsApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'GFL ZE Stats',
        theme: ThemeData.dark().copyWith(
          scaffoldBackgroundColor: Colors.black,
          textTheme: ThemeData.dark().textTheme.apply(fontFamily: kFont),
        ),
        home: const StatsPage(),
      );
}

class StatsPage extends StatefulWidget {
  const StatsPage({super.key});
  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  final _ctrl = TextEditingController();
  PlayerStats? _stats;
  bool _loading = false;
  String? _err;
  int _tab = 0;
  static const _tabs = ['STATS', 'GUNS', 'MAPS', 'ACTIONS'];

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    final p = await SharedPreferences.getInstance();
    final id = p.getString('steam');
    if (id != null && id.isNotEmpty) {
      _ctrl.text = id;
      _load();
    }
  }

  Future<void> _load() async {
    final id = _ctrl.text.trim();
    if (id.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _err = null;
    });
    try {
      final s = await fetchStats(id);
      final p = await SharedPreferences.getInstance();
      await p.setString('steam', id);
      if (!mounted) return;
      setState(() => _stats = s);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _err = e.toString().replaceFirst('Exception: ', '');
        _stats = null;
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  TextStyle _t(double size, {Color color = kGreen, bool bold = false}) =>
      TextStyle(
          fontFamily: kFont,
          fontSize: size,
          color: color,
          fontWeight: bold ? FontWeight.bold : FontWeight.normal);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('> GFL_ZE_STATS', style: _t(20, bold: true)),
              Text('// zombie escape player tracker', style: _t(11, color: kDim)),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _ctrl,
                    style: _t(13),
                    cursorColor: kGreen,
                    onSubmitted: (_) => _load(),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: 'steamid64 / STEAM_0:X:Y',
                      hintStyle: _t(13, color: kDim),
                      enabledBorder: const OutlineInputBorder(
                          borderSide: BorderSide(color: kDim)),
                      focusedBorder: const OutlineInputBorder(
                          borderSide: BorderSide(color: kGreen)),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: _loading ? null : _load,
                  style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: kGreen),
                      shape: const RoundedRectangleBorder()),
                  child: Text(_loading ? '...' : 'SCAN', style: _t(13)),
                ),
              ]),
              const SizedBox(height: 8),
              if (_err != null) Text('! $_err', style: _t(12, color: kRed)),
              if (_stats != null) ...[
                Text('USER: ${_stats!.name}', style: _t(13, color: kYellow)),
                const SizedBox(height: 6),
                Row(
                  children: [
                    for (int i = 0; i < _tabs.length; i++)
                      Expanded(
                        child: GestureDetector(
                          onTap: () => setState(() => _tab = i),
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              border: Border(
                                  bottom: BorderSide(
                                      color: _tab == i ? kGreen : kDim,
                                      width: _tab == i ? 2 : 1)),
                            ),
                            child: Text(_tabs[i],
                                style: _t(12,
                                    color: _tab == i ? kGreen : kDim,
                                    bold: _tab == i)),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Expanded(child: _content(_stats!)),
              ] else
                Expanded(
                  child: Center(
                    child: Text(
                        _loading ? 'connecting to stats.gflclan.com...' : 'enter your steam id and scan',
                        style: _t(12, color: kDim)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _content(PlayerStats s) {
    switch (_tab) {
      case 0:
        return _overview(s);
      case 1:
        return _guns(s);
      case 2:
        return _maps(s);
      default:
        return _actions(s);
    }
  }

  // Fixed-size table: shows as many rows as fit, no scrolling.
  Widget _grid(List<String> titles, List<int> flex, List<List<String>> rows,
      {int yellowCol = -1, String empty = 'no data on this page'}) {
    if (rows.isEmpty) {
      return Text('// $empty', style: _t(12, color: kDim));
    }
    return LayoutBuilder(builder: (context, c) {
      const rowH = 26.0;
      final max = ((c.maxHeight - rowH) / rowH).floor().clamp(1, 60);
      Widget line(List<String> cells, {bool head = false}) => SizedBox(
            height: rowH,
            child: Row(children: [
              for (int i = 0; i < cells.length; i++)
                Expanded(
                  flex: flex[i],
                  child: Text(
                    cells[i],
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: i == 0 ? TextAlign.left : TextAlign.right,
                    style: head
                        ? _t(11, color: kDim, bold: true)
                        : _t(12, color: i == yellowCol ? kYellow : kGreen),
                  ),
                ),
            ]),
          );
      return Column(children: [
        line(titles, head: true),
        for (final r in rows.take(max)) line(r),
      ]);
    });
  }

  Widget _overview(PlayerStats s) {
    final rounds = s.roundsWon;
    final pairs = <List<String>>[
      ['ZOMBIES KILLED', s.s('Kills:')],
      ['DEATHS', s.s('Deaths:')],
      ['K/D', s.s('Kills per Death:')],
      ['HEADSHOTS', s.s('Headshots:')],
      ['ROUNDS WON', rounds?.toString() ?? 'not tracked'],
      ['POINTS', s.s('Points:')],
      ['RANK', s.s('Rank:')],
      ['KILL STREAK', s.s('Longest Kill Streak:')],
      ['SUICIDES', s.s('Suicides:')],
      ['PLAY TIME', s.s('Total Connection Time:')],
      ['FAV GUN', s.s('Favorite Weapon:')],
      ['FAV MAP', s.s('Favorite Map:')],
    ];
    return LayoutBuilder(builder: (context, c) {
      final max = (c.maxHeight / 28).floor().clamp(1, 40);
      return Column(children: [
        for (final p in pairs.take(max))
          SizedBox(
            height: 28,
            child: Row(children: [
              Text(p[0], style: _t(12, color: kDim)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  p[1],
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: _t(14,
                      color: p[0] == 'FAV MAP' ? kYellow : kGreen, bold: true),
                ),
              ),
            ]),
          ),
      ]);
    });
  }

  Widget _guns(PlayerStats s) {
    final t = s.weapons;
    if (t == null) return _grid([], [], []);
    final rows = t.rows
        .map((r) => [t.col(r, 'weapon'), t.col(r, 'kills'), t.col(r, 'headshots')])
        .toList()
      ..sort((a, b) => num_(b[1]).compareTo(num_(a[1])));
    return _grid(['GUN', 'KILLS', 'HS'], [5, 2, 2], rows);
  }

  Widget _maps(PlayerStats s) {
    final t = s.maps;
    if (t == null) return _grid([], [], []);
    final rows = t.rows
        .map((r) => [
              t.col(r, 'map'),
              t.col(r, 'kills'),
              t.col(r, 'deaths'),
              t.col(r, 'k:d'),
            ])
        .toList()
      ..sort((a, b) => num_(b[1]).compareTo(num_(a[1])));
    return _grid(['MAP', 'KILLS', 'DEATHS', 'K:D'], [6, 2, 2, 2], rows,
        yellowCol: 0);
  }

  Widget _actions(PlayerStats s) {
    final t = s.actions;
    if (t == null) {
      return _grid([], [], [],
          empty: 'no actions listed (round wins may not be tracked)');
    }
    final rows = t.rows
        .map((r) => [t.col(r, 'action'), t.col(r, 'earned'), t.col(r, 'points')])
        .toList()
      ..sort((a, b) => num_(b[1]).compareTo(num_(a[1])));
    return _grid(['ACTION', 'COUNT', 'POINTS'], [5, 2, 2], rows);
  }
}
