// GFL Zombie Escape Stats v2
// Reads your stats from ZE Graph (zegraph.xyz) using your Steam ID.
//
// pubspec.yaml dependencies needed:
//   http, html, shared_preferences, url_launcher
//   (run: flutter pub add http html shared_preferences url_launcher)
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
import 'package:url_launcher/url_launcher.dart';

const String kSite = 'https://zegraph.xyz';
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

class Community {
  final String name;
  final String hours;
  Community(this.name, this.hours);
}

class PlayerStats {
  final String name;
  final String id64;
  final String url;
  final String hours;
  final String servers;
  final String communityCount;
  final String rank;
  final String totalPlayers;
  final String bestMapRank;
  final String bestMap;
  final String lastSeen;
  final String yearHours;
  final String year;
  final List<Community> communities;

  PlayerStats({
    required this.name,
    required this.id64,
    required this.url,
    required this.hours,
    required this.servers,
    required this.communityCount,
    required this.rank,
    required this.totalPlayers,
    required this.bestMapRank,
    required this.bestMap,
    required this.lastSeen,
    required this.yearHours,
    required this.year,
    required this.communities,
  });
}

class NotTrackedException implements Exception {
  @override
  String toString() =>
      'No stats found for this Steam ID. ZE Graph only lists players it has '
      'seen on a tracked server. Play on the GFL CS2 server and try again later.';
}

String clean(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

// ------------------------------------------------------------ steam id ----

/// Accepts SteamID64, STEAM_0:X:Y, or a steamcommunity.com/profiles/<id64> URL.
/// Returns the SteamID64 as a string. Vanity URLs (/id/name) can't be
/// resolved without a Steam API key, so those throw.
String toSteam64(String input) {
  final t = input.trim();
  final m64 = RegExp(r'7656119\d{10}').firstMatch(t);
  if (m64 != null) return m64.group(0)!;
  final m2 =
      RegExp(r'STEAM_[0-5]:([01]):(\d+)', caseSensitive: false).firstMatch(t);
  if (m2 != null) {
    final y = int.parse(m2.group(1)!);
    final z = int.parse(m2.group(2)!);
    return (76561197960265728 + z * 2 + y).toString();
  }
  throw Exception(
      'Use your SteamID64 (17 digits), STEAM_0:X:Y, or a /profiles/ URL.');
}

// -------------------------------------------------------------- scraping ----

List<Community> readCommunities(dom.Document doc) {
  final out = <Community>[];
  final hrs = RegExp(r'([\d,]+\.?\d*)\s*hrs');
  for (final h in doc.querySelectorAll('h3')) {
    final name = clean(h.text);
    if (name.isEmpty) continue;
    var txt = '';
    dom.Element? sib = h.nextElementSibling;
    while (sib != null && sib.localName != 'h3') {
      txt += ' ${sib.text}';
      sib = sib.nextElementSibling;
    }
    var m = hrs.firstMatch(txt);
    final parent = h.parent;
    if (m == null && parent != null && parent.querySelectorAll('h3').length == 1) {
      m = hrs.firstMatch(parent.text.replaceFirst(h.text, ''));
    }
    if (m != null) out.add(Community(name, m.group(1)!));
  }
  return out;
}

PlayerStats parseProfile(String body, String id64, String url) {
  final doc = html_parser.parse(body);

  String meta(String key) =>
      doc.querySelector('meta[name="$key"]')?.attributes['content'] ??
      doc.querySelector('meta[property="og:$key"]')?.attributes['content'] ??
      '';

  final desc = meta('description');
  final hm = RegExp(
          r'([\d,\.]+) hrs of Zombie Escape playtime across (\d+) servers? in (\d+) communit')
      .firstMatch(desc);
  if (hm == null) throw NotTrackedException();

  final rank = RegExp(r'Ranked (\S+) of ([\d,]+) players').firstMatch(desc);
  final best =
      RegExp(r'Best map rank: (\S+) on (.+?)\.\s*(?:Last seen|$)').firstMatch(desc);
  final seen = RegExp(r'Last seen (.+?)\.?$').firstMatch(desc);

  final title = clean(doc.querySelector('title')?.text ?? '');
  final name = title.contains(' | ') ? title.split(' | ').first : 'PLAYER';

  final bodyText = doc.body?.text ?? '';
  final yr = RegExp(r'Total Play Time\s*([\d,\.]+)\s*hrs\s*in\s*(\d{4})')
      .firstMatch(bodyText);

  return PlayerStats(
    name: name,
    id64: id64,
    url: url,
    hours: hm.group(1)!,
    servers: hm.group(2)!,
    communityCount: hm.group(3)!,
    rank: rank?.group(1) ?? '-',
    totalPlayers: rank?.group(2) ?? '-',
    bestMapRank: best?.group(1) ?? '-',
    bestMap: best?.group(2) ?? '-',
    lastSeen: seen?.group(1) ?? '-',
    yearHours: yr?.group(1) ?? '-',
    year: yr?.group(2) ?? '',
    communities: readCommunities(doc),
  );
}

Future<PlayerStats> fetchStats(String input) async {
  final id = toSteam64(input);
  final url = '$kSite/players/$id/profile';
  http.Response res;
  try {
    res = await http.get(Uri.parse(url), headers: {
      'User-Agent': 'Mozilla/5.0 (Android) GFLZEStats/2.0',
    }).timeout(const Duration(seconds: 20));
  } catch (e) {
    final msg = e.toString();
    if (msg.contains('SocketFailed') ||
        msg.contains('SocketException') ||
        msg.contains('ClientException') ||
        msg.contains('TimeoutException')) {
      throw Exception(
          'Cannot reach zegraph.xyz. Check that your phone has internet.');
    }
    rethrow;
  }
  if (res.statusCode == 404) throw NotTrackedException();
  if (res.statusCode != 200) {
    throw Exception('ZE Graph returned error ${res.statusCode}. Try again later.');
  }
  return parseProfile(res.body, id, url);
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
  static const _tabs = ['STATS', 'COMMUNITIES', 'MORE'];

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

  Future<void> _openProfile() async {
    final url = _stats?.url;
    if (url == null) return;
    var opened = false;
    try {
      opened = await launchUrl(Uri.parse(url),
          mode: LaunchMode.externalApplication);
    } catch (_) {}
    if (!opened) {
      await Clipboard.setData(ClipboardData(text: url));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not open browser. Link copied instead.')));
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
              Text('// zombie escape tracker  [data: zegraph.xyz]',
                  style: _t(11, color: kDim)),
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
                        _loading
                            ? 'connecting to zegraph.xyz...'
                            : 'enter your steam id and scan',
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
        return _communities(s);
      default:
        return _more(s);
    }
  }

  Widget _overview(PlayerStats s) {
    final pairs = <List<String>>[
      ['TOTAL PLAYTIME', '${s.hours} hrs'],
      [
        s.year.isEmpty ? 'THIS YEAR' : 'IN ${s.year}',
        s.yearHours == '-' ? '-' : '${s.yearHours} hrs'
      ],
      ['GLOBAL RANK', '${s.rank} of ${s.totalPlayers}'],
      ['BEST MAP RANK', s.bestMapRank],
      ['BEST MAP', s.bestMap],
      ['LAST SEEN', s.lastSeen],
      ['SERVERS', s.servers],
      ['COMMUNITIES', s.communityCount],
    ];
    return LayoutBuilder(builder: (context, c) {
      final max = (c.maxHeight / 30).floor().clamp(1, 40);
      return Column(children: [
        for (final p in pairs.take(max))
          SizedBox(
            height: 30,
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
                      color: p[0] == 'BEST MAP' ? kYellow : kGreen,
                      bold: true),
                ),
              ),
            ]),
          ),
      ]);
    });
  }

  Widget _communities(PlayerStats s) {
    if (s.communities.isEmpty) {
      return Text('// no community list found on the page. Open the full profile in MORE.',
          style: _t(12, color: kDim));
    }
    return LayoutBuilder(builder: (context, c) {
      const rowH = 28.0;
      final max = (c.maxHeight / rowH).floor().clamp(1, 40);
      return Column(children: [
        for (final co in s.communities.take(max))
          SizedBox(
            height: rowH,
            child: Row(children: [
              Expanded(
                child: Text(co.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _t(13)),
              ),
              Text('${co.hours} hrs', style: _t(13, bold: true)),
            ]),
          ),
      ]);
    });
  }

  Widget _more(PlayerStats s) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('STEAM ID', style: _t(11, color: kDim)),
        Text(s.id64, style: _t(14, bold: true)),
        const SizedBox(height: 14),
        Text('// on the website only:', style: _t(12, color: kDim)),
        Text('per-map playtime, play sessions,\nactivity heatmap, map rankings',
            style: _t(12)),
        const SizedBox(height: 14),
        Text('// not tracked by ZE Graph:', style: _t(12, color: kDim)),
        Text('guns, kills, boss kills, boss damage,\nround wins, map wins',
            style: _t(12, color: kRed)),
        const SizedBox(height: 18),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            onPressed: _openProfile,
            style: OutlinedButton.styleFrom(
                side: const BorderSide(color: kGreen),
                shape: const RoundedRectangleBorder(),
                padding: const EdgeInsets.symmetric(vertical: 12)),
            child: Text('OPEN FULL PROFILE', style: _t(13, bold: true)),
          ),
        ),
      ],
    );
  }
}
