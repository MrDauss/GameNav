import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

const String kGameDisplayFont = 'Pricedown';

TextStyle gameDisplayStyle({
  double fontSize = 22,
  Color? color,
  double letterSpacing = 0.6,
}) {
  return TextStyle(
    fontFamily: kGameDisplayFont,
    fontSize: fontSize,
    color: color,
    letterSpacing: letterSpacing,
    height: 0.95,
  );
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const GameNavApp());
}

class GameNavApp extends StatelessWidget {
  const GameNavApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'GameNav',
      theme: ThemeData.dark(useMaterial3: true),
      home: const MapScreen(),
    );
  }
}

class SearchResult {
  final String name;
  final double lat;
  final double lon;
  final String? subtitle;
  final double? durationSeconds;
  final double? distanceMeters;

  const SearchResult(
    this.name,
    this.lat,
    this.lon, {
    this.subtitle,
    this.durationSeconds,
    this.distanceMeters,
  });

  SearchResult copyWithTravelEstimate({
    double? durationSeconds,
    double? distanceMeters,
  }) {
    return SearchResult(
      name,
      lat,
      lon,
      subtitle: subtitle,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      distanceMeters: distanceMeters ?? this.distanceMeters,
    );
  }
}

class RouteResult {
  final List<LatLng> geometry;
  final double distanceMeters;
  final double durationSeconds;

  const RouteResult(
    this.geometry,
    this.distanceMeters,
    this.durationSeconds,
  );
}

class RoadSnapResult {
  final LatLng point;
  final double distanceMeters;

  const RoadSnapResult(this.point, this.distanceMeters);
}

class TrafficSignalInfo {
  final String id;
  final LatLng point;
  final String? phase;
  final int? remainingSeconds;
  final double? confidence;

  const TrafficSignalInfo({
    required this.id,
    required this.point,
    this.phase,
    this.remainingSeconds,
    this.confidence,
  });

  TrafficSignalInfo copyWithTiming({
    String? phase,
    int? remainingSeconds,
    double? confidence,
  }) {
    return TrafficSignalInfo(
      id: id,
      point: point,
      phase: phase ?? this.phase,
      remainingSeconds: remainingSeconds ?? this.remainingSeconds,
      confidence: confidence ?? this.confidence,
    );
  }
}

class GameMapPalette {
  final String background;
  final String land;
  final String water;
  final String park;
  final String building;
  final String road;
  final String roadMajor;
  final String roadOutline;
  final String label;
  final String labelHalo;

  const GameMapPalette({
    required this.background,
    required this.land,
    required this.water,
    required this.park,
    required this.building,
    required this.road,
    required this.roadMajor,
    required this.roadOutline,
    required this.label,
    required this.labelHalo,
  });
}

class GameStyleBuilder {
  static final Map<String, String> _cache = <String, String>{};

  static Future<String> build(GameThemeSpec theme) async {
    final cached = _cache[theme.id];
    if (cached != null) return cached;
    final response = await http
        .get(
          Uri.parse(theme.mapStyle),
          headers: const {'Accept': 'application/json'},
        )
        .timeout(const Duration(seconds: 10));

    if (response.statusCode != 200) return theme.mapStyle;

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) return theme.mapStyle;

    final palette = _palette(theme.id);
    final layers = decoded['layers'];
    if (layers is! List) return theme.mapStyle;

    for (final raw in layers) {
      if (raw is! Map<String, dynamic>) continue;
      final type = raw['type']?.toString() ?? '';
      final id = raw['id']?.toString().toLowerCase() ?? '';
      final sourceLayer = raw['source-layer']?.toString().toLowerCase() ?? '';
      final token = '$id $sourceLayer';
      final paintRaw = raw['paint'];
      final paint = paintRaw is Map<String, dynamic>
          ? paintRaw
          : <String, dynamic>{};
      raw['paint'] = paint;

      if (type == 'background') {
        paint['background-color'] = palette.background;
        continue;
      }

      if (type == 'fill') {
        if (_containsAny(token, ['water', 'ocean', 'lake'])) {
          paint['fill-color'] = palette.water;
          paint['fill-opacity'] = 0.96;
        } else if (_containsAny(token, ['building'])) {
          paint['fill-color'] = palette.building;
          paint['fill-opacity'] = 0.88;
        } else if (_containsAny(token, [
          'park',
          'grass',
          'wood',
          'forest',
          'landcover',
          'cemetery',
        ])) {
          paint['fill-color'] = palette.park;
          paint['fill-opacity'] = 0.9;
        } else if (_containsAny(token, ['landuse', 'land'])) {
          paint['fill-color'] = palette.land;
        }
        continue;
      }

      if (type == 'fill-extrusion') {
        if (_containsAny(token, ['building'])) {
          paint['fill-extrusion-color'] = palette.building;
          paint['fill-extrusion-opacity'] = 0.82;
        }
        continue;
      }

      if (type == 'line') {
        if (_containsAny(token, ['road', 'transportation', 'highway', 'street'])) {
          final major = _containsAny(token, [
            'motorway',
            'trunk',
            'primary',
            'major',
          ]);
          final casing = _containsAny(token, ['case', 'casing', 'outline']);
          paint['line-color'] = casing
              ? palette.roadOutline
              : (major ? palette.roadMajor : palette.road);
          paint['line-opacity'] = casing ? 0.78 : 0.96;
          if (theme.id == 'neon_coast' || theme.id == 'cyber_grid') {
            paint['line-blur'] = casing ? 0.4 : 0.08;
          }
        } else if (_containsAny(token, ['waterway', 'river', 'stream'])) {
          paint['line-color'] = palette.water;
          paint['line-opacity'] = 0.9;
        } else if (_containsAny(token, ['boundary'])) {
          paint['line-color'] = palette.roadOutline;
          paint['line-opacity'] = 0.35;
        }
        continue;
      }

      if (type == 'symbol') {
        paint['text-color'] = palette.label;
        paint['text-halo-color'] = palette.labelHalo;
        paint['text-halo-width'] = 1.2;
        if (theme.id == 'frontier') {
          paint['icon-opacity'] = 0.72;
        } else if (theme.id == 'cyber_grid') {
          paint['icon-opacity'] = 0.82;
        }
        continue;
      }

      if (type == 'raster') {
        if (theme.id == 'frontier') {
          paint['raster-saturation'] = -0.55;
          paint['raster-contrast'] = 0.18;
          paint['raster-brightness-max'] = 0.82;
        } else if (theme.id != 'classic') {
          paint['raster-saturation'] = -0.75;
          paint['raster-contrast'] = 0.22;
          paint['raster-brightness-max'] = 0.7;
        }
      }
    }

    final result = jsonEncode(decoded);
    _cache[theme.id] = result;
    return result;
  }

  static bool _containsAny(String value, List<String> needles) {
    for (final needle in needles) {
      if (value.contains(needle)) return true;
    }
    return false;
  }

  static GameMapPalette _palette(String id) {
    switch (id) {
      case 'frontier':
        return const GameMapPalette(
          background: '#221B13',
          land: '#3A2F20',
          water: '#31464A',
          park: '#36402D',
          building: '#604C34',
          road: '#B59A70',
          roadMajor: '#D0B382',
          roadOutline: '#17110C',
          label: '#F0DBB7',
          labelHalo: '#22180F',
        );
      case 'neon_coast':
        return const GameMapPalette(
          background: '#080611',
          land: '#100C1C',
          water: '#071C2D',
          park: '#102520',
          building: '#24152E',
          road: '#3A3151',
          roadMajor: '#775B98',
          roadOutline: '#050308',
          label: '#F6EFFF',
          labelHalo: '#07040D',
        );
      case 'cyber_grid':
        return const GameMapPalette(
          background: '#020B0D',
          land: '#071416',
          water: '#05212B',
          park: '#0A231E',
          building: '#0B2427',
          road: '#194249',
          roadMajor: '#2D7279',
          roadOutline: '#010607',
          label: '#CFFFF5',
          labelHalo: '#001214',
        );
      case 'midnight':
        return const GameMapPalette(
          background: '#08090C',
          land: '#111216',
          water: '#0B1825',
          park: '#111B17',
          building: '#1C1C24',
          road: '#292A34',
          roadMajor: '#48475B',
          roadOutline: '#030304',
          label: '#EDEDF3',
          labelHalo: '#08080A',
        );
      case 'classic':
        return const GameMapPalette(
          background: '#EDEFF2',
          land: '#F1F2F3',
          water: '#B9DDEB',
          park: '#D4E5D2',
          building: '#D8D7D4',
          road: '#FFFFFF',
          roadMajor: '#F6E7B4',
          roadOutline: '#C8C8C8',
          label: '#29313A',
          labelHalo: '#FFFFFF',
        );
      case 'crime_city':
      default:
        return const GameMapPalette(
          background: '#0D1010',
          land: '#151A18',
          water: '#0B1D23',
          park: '#18251B',
          building: '#242925',
          road: '#3A403B',
          roadMajor: '#626A62',
          roadOutline: '#070908',
          label: '#F2F0EA',
          labelHalo: '#0C0E0D',
        );
    }
  }
}

class GameMapFxOverlay extends StatelessWidget {
  final GameThemeSpec theme;

  const GameMapFxOverlay({super.key, required this.theme});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _GameMapFxPainter(theme),
          size: Size.infinite,
        ),
      ),
    );
  }
}

class _GameMapFxPainter extends CustomPainter {
  final GameThemeSpec theme;

  const _GameMapFxPainter(this.theme);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;

    if (theme.id == 'frontier') {
      canvas.drawRect(
        rect,
        Paint()..color = const Color(0x1FCB8F4B),
      );
      final linePaint = Paint()
        ..color = const Color(0x0FF4D7A5)
        ..strokeWidth = 1;
      for (double y = 0; y < size.height; y += 38) {
        canvas.drawLine(Offset(0, y), Offset(size.width, y + 10), linePaint);
      }
    } else if (theme.id == 'neon_coast' || theme.id == 'cyber_grid') {
      final scanPaint = Paint()
        ..color = theme.accent.withValues(alpha: 0.035)
        ..strokeWidth = 1;
      for (double y = 0; y < size.height; y += 7) {
        canvas.drawLine(Offset(0, y), Offset(size.width, y), scanPaint);
      }
      final glow = Paint()
        ..shader = RadialGradient(
          colors: [
            theme.accent.withValues(alpha: 0.06),
            Colors.transparent,
          ],
        ).createShader(
          Rect.fromCircle(
            center: Offset(size.width * 0.52, size.height * 0.45),
            radius: size.longestSide * 0.7,
          ),
        );
      canvas.drawRect(rect, glow);
    } else if (theme.id == 'crime_city') {
      canvas.drawRect(
        rect,
        Paint()..color = const Color(0x0C6B5848),
      );
    }

    if (theme.id != 'classic') {
      final vignette = Paint()
        ..shader = RadialGradient(
          colors: const [Colors.transparent, Color(0x79000000)],
          stops: const [0.58, 1.0],
        ).createShader(rect);
      canvas.drawRect(rect, vignette);
    }
  }

  @override
  bool shouldRepaint(covariant _GameMapFxPainter oldDelegate) {
    return oldDelegate.theme.id != theme.id;
  }
}

class GameThemeSpec {
  final String id;
  final String name;
  final String tagline;
  final String mapStyle;
  final Color accent;
  final Color panel;
  final Color foreground;
  final String routeColor;
  final IconData icon;

  const GameThemeSpec({
    required this.id,
    required this.name,
    required this.tagline,
    required this.mapStyle,
    required this.accent,
    required this.panel,
    required this.foreground,
    required this.routeColor,
    required this.icon,
  });
}

const gameThemes = <GameThemeSpec>[
  GameThemeSpec(
    id: 'crime_city',
    name: 'Crime City',
    tagline: 'Open world • urban crime-game atmosphere',
    mapStyle: 'https://tiles.openfreemap.org/styles/liberty',
    accent: Color(0xFFE45AAE),
    panel: Color(0xE8121018),
    foreground: Colors.white,
    routeColor: '#E45AAE',
    icon: Icons.location_city,
  ),
  GameThemeSpec(
    id: 'frontier',
    name: 'Frontier Trails',
    tagline: 'Wild west • frontier adventure atmosphere',
    mapStyle: 'https://tiles.openfreemap.org/styles/fiord',
    accent: Color(0xFFD59A55),
    panel: Color(0xE81E1610),
    foreground: Color(0xFFFFF1D0),
    routeColor: '#D59A55',
    icon: Icons.landscape,
  ),
  GameThemeSpec(
    id: 'neon_coast',
    name: 'Neon Coast',
    tagline: 'Night • neon • 80s atmosphere',
    mapStyle: 'https://tiles.openfreemap.org/styles/dark',
    accent: Color(0xFFFF4FD8),
    panel: Color(0xEB10091C),
    foreground: Color(0xFFF7F2FF),
    routeColor: '#FF4FD8',
    icon: Icons.nightlife,
  ),
  GameThemeSpec(
    id: 'cyber_grid',
    name: 'Cyber Grid',
    tagline: 'Futuristic • digital HUD',
    mapStyle: 'https://tiles.openfreemap.org/styles/dark',
    accent: Color(0xFF37F6D1),
    panel: Color(0xE8061718),
    foreground: Color(0xFFE8FFF9),
    routeColor: '#37F6D1',
    icon: Icons.memory,
  ),
  GameThemeSpec(
    id: 'midnight',
    name: 'Midnight Run',
    tagline: 'Night driving • minimal',
    mapStyle: 'https://tiles.openfreemap.org/styles/dark',
    accent: Color(0xFF9D8CFF),
    panel: Color(0xEC111118),
    foreground: Colors.white,
    routeColor: '#9D8CFF',
    icon: Icons.dark_mode,
  ),
  GameThemeSpec(
    id: 'classic',
    name: 'Classic Navigator',
    tagline: 'Bright • clean navigation map',
    mapStyle: 'https://tiles.openfreemap.org/styles/positron',
    accent: Color(0xFF3F72FF),
    panel: Color(0xEE10131A),
    foreground: Colors.white,
    routeColor: '#3F72FF',
    icon: Icons.map,
  ),
];


enum MissionMetric { trips, distanceKm, reports, themes }

class MissionSpec {
  final String id;
  final String title;
  final String description;
  final int rewardXp;
  final MissionMetric metric;
  final double target;
  final IconData icon;

  const MissionSpec({
    required this.id,
    required this.title,
    required this.description,
    required this.rewardXp,
    required this.metric,
    required this.target,
    required this.icon,
  });
}

class RankSpec {
  final String name;
  final int minXp;
  final IconData icon;

  const RankSpec(this.name, this.minXp, this.icon);
}

class RewardSpec {
  final String id;
  final String name;
  final int requiredXp;
  final IconData icon;

  const RewardSpec(this.id, this.name, this.requiredXp, this.icon);
}

const gameRanks = <RankSpec>[
  RankSpec('Rookie', 0, Icons.explore_outlined),
  RankSpec('Street Scout', 250, Icons.assistant_navigation),
  RankSpec('Pathfinder', 600, Icons.route),
  RankSpec('Road Ace', 1200, Icons.bolt),
  RankSpec('Navigator', 2200, Icons.navigation),
  RankSpec('Elite', 4000, Icons.workspace_premium),
  RankSpec('Legend', 7000, Icons.emoji_events),
];

const gameMissions = <MissionSpec>[
  MissionSpec(
    id: 'first_route',
    title: 'First Route',
    description: 'Complete your first navigation trip.',
    rewardXp: 100,
    metric: MissionMetric.trips,
    target: 1,
    icon: Icons.flag,
  ),
  MissionSpec(
    id: 'ten_km',
    title: '10K Explorer',
    description: 'Drive 10 km while GameNav is navigating.',
    rewardXp: 150,
    metric: MissionMetric.distanceKm,
    target: 10,
    icon: Icons.explore,
  ),
  MissionSpec(
    id: 'theme_hopper',
    title: 'Theme Hopper',
    description: 'Use 3 different GameNav themes.',
    rewardXp: 120,
    metric: MissionMetric.themes,
    target: 3,
    icon: Icons.palette,
  ),
  MissionSpec(
    id: 'community_helper',
    title: 'Community Helper',
    description: 'Add 3 non-enforcement road safety reports while stopped.',
    rewardXp: 180,
    metric: MissionMetric.reports,
    target: 3,
    icon: Icons.volunteer_activism,
  ),
  MissionSpec(
    id: 'route_regular',
    title: 'Route Regular',
    description: 'Complete 10 navigation trips.',
    rewardXp: 400,
    metric: MissionMetric.trips,
    target: 10,
    icon: Icons.alt_route,
  ),
  MissionSpec(
    id: 'fifty_km',
    title: '50K Explorer',
    description: 'Navigate 50 km with GameNav.',
    rewardXp: 450,
    metric: MissionMetric.distanceKm,
    target: 50,
    icon: Icons.travel_explore,
  ),
  MissionSpec(
    id: 'hundred_km',
    title: 'Road Veteran',
    description: 'Navigate 100 km with GameNav.',
    rewardXp: 700,
    metric: MissionMetric.distanceKm,
    target: 100,
    icon: Icons.military_tech,
  ),
];

const gameRewards = <RewardSpec>[
  RewardSpec('starter', 'Starter', 0, Icons.navigation),
  RewardSpec('bolt', 'Bolt', 250, Icons.bolt),
  RewardSpec('star', 'Route Star', 600, Icons.star),
  RewardSpec('shield', 'Road Shield', 1200, Icons.shield),
  RewardSpec('crown', 'Navigator Crown', 2200, Icons.diamond),
  RewardSpec('rocket', 'Elite Rocket', 4000, Icons.rocket_launch),
  RewardSpec('legend', 'Legend Trophy', 7000, Icons.emoji_events),
];

class CommunityReport {
  final String type;
  final DateTime createdAt;

  CommunityReport(this.type) : createdAt = DateTime.now();
}

class OpenMapServices {
  static const _userAgent =
      'GameNav/0.5.2 (https://github.com/MrDauss/GameNav)';

  static Future<List<SearchResult>> search(
    String query, {
    Position? bias,
  }) async {
    Object? photonError;

    try {
      final params = <String, String>{
        'q': query,
        'limit': '7',
        'lang': 'en',
      };

      if (bias != null) {
        params['lat'] = bias.latitude.toString();
        params['lon'] = bias.longitude.toString();
        params['zoom'] = '11';
      }

      final uri = Uri.https('photon.komoot.io', '/api/', params);
      final response = await http
          .get(
            uri,
            headers: {
              'User-Agent': _userAgent,
              'Accept': 'application/json',
              'Accept-Language': 'en,he;q=0.8',
            },
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        if (decoded is! Map<String, dynamic>) {
          photonError = 'Photon returned an invalid response';
        } else {
          final features = decoded['features'];
          final results = <SearchResult>[];

          for (final raw in features is List ? features : const <dynamic>[]) {
            if (raw is! Map<String, dynamic>) continue;
            final geometry = raw['geometry'];
            final properties = raw['properties'];
            if (geometry is! Map<String, dynamic>) continue;
            final coordinates = geometry['coordinates'];
            if (coordinates is! List || coordinates.length < 2) continue;
            if (coordinates[0] is! num || coordinates[1] is! num) continue;

            final lon = (coordinates[0] as num).toDouble();
            final lat = (coordinates[1] as num).toDouble();
            if (!_validCoordinate(lat, lon)) continue;
            final props = properties is Map<String, dynamic>
                ? properties
                : const <String, dynamic>{};
            final name = _photonTitle(props);
            final subtitle = _photonSubtitle(props, name);
            results.add(
              SearchResult(
                name,
                lat,
                lon,
                subtitle: subtitle,
              ),
            );
          }

          if (results.isNotEmpty) return results;
        }
      } else {
        photonError = 'Photon HTTP ${response.statusCode}';
      }
    } catch (e) {
      photonError = e;
    }

    try {
      final uri = Uri.https('nominatim.openstreetmap.org', '/search', {
        'q': query,
        'format': 'jsonv2',
        'addressdetails': '1',
        'limit': '7',
        'accept-language': 'en,he',
      });

      final response = await http
          .get(
            uri,
            headers: {
              'User-Agent': _userAgent,
              'Accept': 'application/json',
              'Accept-Language': 'en,he;q=0.8',
            },
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        throw Exception('Nominatim HTTP ${response.statusCode}');
      }

      final data = jsonDecode(response.body);
      if (data is! List) throw const FormatException('Invalid Nominatim response');
      final results = <SearchResult>[];
      for (final raw in data) {
        if (raw is! Map<String, dynamic>) continue;
        final lat = double.tryParse(raw['lat']?.toString() ?? '');
        final lon = double.tryParse(raw['lon']?.toString() ?? '');
        if (lat == null || lon == null || !_validCoordinate(lat, lon)) continue;
        final displayName = raw['display_name']?.toString() ?? 'Destination';
        final label = _shortNominatimLabel(displayName);
        results.add(
          SearchResult(
            label.$1,
            lat,
            lon,
            subtitle: label.$2,
          ),
        );
      }

      if (results.isNotEmpty) return results;
    } catch (e) {
      throw Exception('Search providers failed: $photonError / $e');
    }

    return const [];
  }

  static bool _validCoordinate(double lat, double lon) {
    return lat.isFinite &&
        lon.isFinite &&
        lat >= -90 &&
        lat <= 90 &&
        lon >= -180 &&
        lon <= 180;
  }

  static String _photonTitle(Map<String, dynamic> p) {
    final name = p['name']?.toString().trim();
    if (name != null && name.isNotEmpty) return name;

    final street = p['street']?.toString().trim();
    final house = p['housenumber']?.toString().trim();
    if (street != null && street.isNotEmpty) {
      if (house != null && house.isNotEmpty) return '$street $house';
      return street;
    }

    final city = p['city']?.toString().trim();
    if (city != null && city.isNotEmpty) return city;
    final district = p['district']?.toString().trim();
    if (district != null && district.isNotEmpty) return district;
    return 'Destination';
  }

  static String? _photonSubtitle(
    Map<String, dynamic> p,
    String title,
  ) {
    final parts = <String>[];
    for (final key in ['street', 'district', 'city']) {
      final value = p[key]?.toString().trim();
      if (value != null &&
          value.isNotEmpty &&
          value != title &&
          !parts.contains(value)) {
        parts.add(value);
      }
      if (parts.length >= 2) break;
    }
    return parts.isEmpty ? null : parts.join(', ');
  }

  static (String, String?) _shortNominatimLabel(String displayName) {
    final parts = displayName
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (parts.isEmpty) return ('Destination', null);
    final title = parts.first;
    final secondary = <String>[];
    for (final part in parts.skip(1)) {
      if (part != title && !secondary.contains(part)) secondary.add(part);
      if (secondary.length >= 2) break;
    }
    return (title, secondary.isEmpty ? null : secondary.join(', '));
  }

  static Future<List<SearchResult>> addTravelEstimates(
    LatLng from,
    List<SearchResult> results,
  ) async {
    if (results.isEmpty) return results;

    final limited = results.take(6).toList();
    final coordinates = <String>[
      '${from.longitude},${from.latitude}',
      ...limited.map((r) => '${r.lon},${r.lat}'),
    ].join(';');
    final destinationIndexes =
        List.generate(limited.length, (i) => '${i + 1}').join(';');
    final uri = Uri.https(
      'router.project-osrm.org',
      '/table/v1/driving/$coordinates',
      {
        'sources': '0',
        'destinations': destinationIndexes,
        'annotations': 'duration,distance',
      },
    );

    try {
      final response = await http
          .get(uri, headers: {'User-Agent': _userAgent})
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return limited;

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) return limited;
      final durations = decoded['durations'];
      final distances = decoded['distances'];
      if (durations is! List || durations.isEmpty || durations.first is! List) {
        return limited;
      }
      final durationRow = durations.first as List;
      final distanceRow =
          distances is List && distances.isNotEmpty && distances.first is List
              ? distances.first as List
              : const <dynamic>[];

      return List.generate(limited.length, (i) {
        final duration = i < durationRow.length && durationRow[i] is num
            ? (durationRow[i] as num).toDouble()
            : null;
        final distance = i < distanceRow.length && distanceRow[i] is num
            ? (distanceRow[i] as num).toDouble()
            : null;
        return limited[i].copyWithTravelEstimate(
          durationSeconds: duration,
          distanceMeters: distance,
        );
      });
    } catch (_) {
      return limited;
    }
  }

  static Future<RoadSnapResult?> nearestRoad(LatLng point) async {
    final path =
        '/nearest/v1/driving/${point.longitude},${point.latitude}';
    final uri = Uri.https('router.project-osrm.org', path, {'number': '1'});

    final response = await http
        .get(uri, headers: {'User-Agent': _userAgent})
        .timeout(const Duration(seconds: 8));

    if (response.statusCode != 200) return null;
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) return null;
    final waypoints = decoded['waypoints'];
    if (waypoints is! List || waypoints.isEmpty) return null;
    final waypoint = waypoints.first;
    if (waypoint is! Map<String, dynamic>) return null;
    final location = waypoint['location'];
    if (location is! List || location.length < 2) return null;
    if (location[0] is! num || location[1] is! num) return null;
    final lon = (location[0] as num).toDouble();
    final lat = (location[1] as num).toDouble();
    if (!_validCoordinate(lat, lon)) return null;
    final rawDistance = waypoint['distance'];
    final distance = rawDistance is num ? rawDistance.toDouble() : double.infinity;
    if (!distance.isFinite || distance < 0) return null;

    return RoadSnapResult(LatLng(lat, lon), distance);
  }

  static Future<List<TrafficSignalInfo>> trafficSignalsNear(
    LatLng center, {
    int radiusMeters = 1100,
  }) async {
    final query =
        '[out:json][timeout:10];node(around:$radiusMeters,${center.latitude},${center.longitude})["highway"="traffic_signals"];out body;';
    final hosts = <String>[
      'overpass-api.de',
      'overpass.kumi.systems',
    ];

    Object? lastError;
    for (final host in hosts) {
      try {
        final uri = Uri.https(host, '/api/interpreter', {'data': query});
        final response = await http
            .get(uri, headers: {'User-Agent': _userAgent})
            .timeout(const Duration(seconds: 12));
        if (response.statusCode != 200) {
          lastError = 'Overpass HTTP ${response.statusCode}';
          continue;
        }

        final decoded = jsonDecode(response.body);
        if (decoded is! Map<String, dynamic>) return const [];
        final elements = decoded['elements'];
        if (elements is! List) return const [];
        final signals = <TrafficSignalInfo>[];
        for (final raw in elements) {
          if (raw is! Map<String, dynamic>) continue;
          final lat = raw['lat'];
          final lon = raw['lon'];
          if (lat is! num || lon is! num) continue;
          signals.add(
            TrafficSignalInfo(
              id: 'osm:${raw['id']}',
              point: LatLng(lat.toDouble(), lon.toDouble()),
            ),
          );
          if (signals.length >= 80) break;
        }
        return signals;
      } catch (e) {
        lastError = e;
      }
    }
    if (lastError != null) {
      throw Exception('Traffic signal providers failed: $lastError');
    }
    return const [];
  }

  static Future<List<RouteResult>> routes(LatLng from, LatLng to) async {
    final path =
        '/route/v1/driving/${from.longitude},${from.latitude};${to.longitude},${to.latitude}';
    final uri = Uri.https('router.project-osrm.org', path, {
      'overview': 'full',
      'geometries': 'geojson',
      'alternatives': '3',
    });

    final response = await http
        .get(uri, headers: {'User-Agent': _userAgent})
        .timeout(const Duration(seconds: 15));

    if (response.statusCode != 200) {
      throw Exception('Routing HTTP ${response.statusCode}');
    }

    final data = jsonDecode(response.body);
    if (data is! Map<String, dynamic>) throw const FormatException('Invalid route response');
    final rawRoutes = data['routes'];
    if (rawRoutes is! List || rawRoutes.isEmpty) throw Exception('No route');

    final results = <RouteResult>[];
    for (final raw in rawRoutes) {
      if (raw is! Map<String, dynamic>) continue;
      final geometry = raw['geometry'];
      final distance = raw['distance'];
      final duration = raw['duration'];
      if (geometry is! Map<String, dynamic> ||
          distance is! num ||
          duration is! num) {
        continue;
      }
      final coordinates = geometry['coordinates'];
      if (coordinates is! List) continue;
      final points = <LatLng>[];
      for (final coordinate in coordinates) {
        if (coordinate is! List || coordinate.length < 2) continue;
        if (coordinate[0] is! num || coordinate[1] is! num) continue;
        final lon = (coordinate[0] as num).toDouble();
        final lat = (coordinate[1] as num).toDouble();
        if (!_validCoordinate(lat, lon)) continue;
        points.add(LatLng(lat, lon));
      }
      if (points.length < 2) continue;
      results.add(
        RouteResult(points, distance.toDouble(), duration.toDouble()),
      );
    }
    if (results.isEmpty) throw Exception('No valid route');
    return results;
  }
}

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> with WidgetsBindingObserver {
  final _searchController = TextEditingController();
  MapLibreMapController? _map;
  StreamSubscription<Position>? _positionSub;
  StreamSubscription<CompassEvent>? _compassSub;
  Timer? _renderTimer;
  Symbol? _vehicle;
  Line? _routeGlowLine;
  Line? _routeLine;
  final List<Circle> _trafficSignalCircles = [];
  Position? _lastPosition;
  LatLng? _roadSnapPoint;
  LatLng? _targetDisplayPoint;
  LatLng? _renderedDisplayPoint;
  double? _deviceHeading;
  double _targetHeading = 0;
  double _renderedHeading = 0;
  double _lastSpeedMps = 0;
  bool _renderTickBusy = false;
  DateTime? _lastCameraFrameAt;
  LatLng? _lastRoadSnapRequestPoint;
  DateTime? _lastRoadSnapAt;
  bool _roadSnapBusy = false;
  List<TrafficSignalInfo> _trafficSignals = const [];
  TrafficSignalInfo? _nextTrafficSignal;
  double? _distanceToNextTrafficSignal;
  DateTime? _lastSignalsFetchAt;
  LatLng? _lastSignalsCenter;
  bool _signalsBusy = false;
  SearchResult? _destination;
  List<RouteResult> _routeOptions = const [];
  int _selectedRouteIndex = 0;
  int _lastRouteVertexIndex = 0;
  double _lastRouteMatchDistanceMeters = double.infinity;
  List<double> _routeRemainingGeometryMeters = const [];
  double? _remainingRouteDistanceMeters;
  double? _remainingRouteDurationSeconds;
  bool _styleReady = false;
  bool _mapStylePrepared = false;
  bool _mapVisible = false;
  bool _following = true;
  bool _programmaticCameraMove = false;
  bool _busy = false;
  bool _rerouting = false;
  int _offRouteSamples = 0;
  DateTime? _lastRerouteAt;
  String? _gpsIssue;
  GameThemeSpec _theme = gameThemes.first;
  String _resolvedMapStyle = gameThemes.first.mapStyle;
  int _styleRevision = 0;
  int _styleBuildToken = 0;
  final List<CommunityReport> _reports = [];
  DateTime? _lastXpEligibleReportAt;

  // Gamification / progression. These values are local in v0.5.2 and are
  // persisted with SharedPreferences. Friend competition needs the online
  // GameNav account/backend layer, but the XP/rank/reward model is already
  // the same model the backend will sync later.
  int _xp = 0;
  int _completedTrips = 0;
  double _totalDrivenKm = 0;
  int _reportedEvents = 0;
  final Set<String> _usedThemes = <String>{'crime_city'};
  final Set<String> _claimedMissions = <String>{};
  String _selectedRewardId = 'starter';
  LatLng? _lastProgressPoint;
  bool _arrivalAwardedForCurrentRoute = false;
  double _distanceSinceLastProgressSaveKm = 0;

  bool avoidTraffic = true;
  bool avoidClosures = true;
  bool avoidRoadworks = false;
  bool avoidHazards = false;
  bool avoidTolls = false;
  bool avoidUnpaved = false;
  bool preferMainRoads = false;
  bool preferQuietRoads = false;

  RouteResult? get _route =>
      _routeOptions.isEmpty ? null : _routeOptions[_selectedRouteIndex];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_setWakeLock(true));
    unawaited(_loadProgress());
    _startCompass();
    _renderTimer = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => unawaited(_renderFrame()),
    );
    unawaited(_prepareThemeStyle(_theme));
    _startLocation();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Keep the display awake only while the app is actually visible. Android
    // also receives FLAG_KEEP_SCREEN_ON in MainActivity as a native fallback.
    if (state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive) {
      unawaited(_setWakeLock(true));
      return;
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      unawaited(_saveProgress());
      unawaited(_setWakeLock(false));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _positionSub?.cancel();
    _compassSub?.cancel();
    _renderTimer?.cancel();
    unawaited(_setWakeLock(false));
    _searchController.dispose();
    super.dispose();
  }


  Future<void> _setWakeLock(bool enabled) async {
    try {
      if (enabled) {
        await WakelockPlus.enable();
      } else {
        await WakelockPlus.disable();
      }
    } catch (_) {
      // Native FLAG_KEEP_SCREEN_ON is also applied by the Android build.
      // A plugin failure must never crash navigation.
    }
  }

  Future<void> _loadProgress() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _xp = (prefs.getInt('progress_xp') ?? 0).clamp(0, 1000000).toInt();
      _completedTrips =
          (prefs.getInt('progress_trips') ?? 0).clamp(0, 100000).toInt();
      _totalDrivenKm =
          (prefs.getDouble('progress_distance_km') ?? 0).clamp(0.0, 10000000.0).toDouble();
      _reportedEvents =
          (prefs.getInt('progress_reports') ?? 0).clamp(0, 100000).toInt();

      final validRewardIds = gameRewards.map((reward) => reward.id).toSet();
      final storedReward = prefs.getString('progress_reward') ?? 'starter';
      _selectedRewardId =
          validRewardIds.contains(storedReward) ? storedReward : 'starter';

      final validThemeIds = gameThemes.map((theme) => theme.id).toSet();
      final storedThemes =
          prefs.getStringList('progress_themes') ?? <String>['crime_city'];
      _usedThemes
        ..clear()
        ..addAll(storedThemes.where(validThemeIds.contains).take(gameThemes.length));
      if (_usedThemes.isEmpty) _usedThemes.add('crime_city');

      final validMissionIds = gameMissions.map((mission) => mission.id).toSet();
      final storedMissions =
          prefs.getStringList('progress_claimed') ?? const <String>[];
      _claimedMissions
        ..clear()
        ..addAll(storedMissions.where(validMissionIds.contains).take(gameMissions.length));
    });
  }

  Future<void> _saveProgress() async {
    final prefs = await SharedPreferences.getInstance();
    await Future.wait([
      prefs.setInt('progress_xp', _xp),
      prefs.setInt('progress_trips', _completedTrips),
      prefs.setDouble('progress_distance_km', _totalDrivenKm),
      prefs.setInt('progress_reports', _reportedEvents),
      prefs.setString('progress_reward', _selectedRewardId),
      prefs.setStringList('progress_themes', _usedThemes.toList()),
      prefs.setStringList('progress_claimed', _claimedMissions.toList()),
    ]);
  }

  double _missionValue(MissionSpec mission) {
    switch (mission.metric) {
      case MissionMetric.trips:
        return _completedTrips.toDouble();
      case MissionMetric.distanceKm:
        return _totalDrivenKm;
      case MissionMetric.reports:
        return _reportedEvents.toDouble();
      case MissionMetric.themes:
        return _usedThemes.length.toDouble();
    }
  }

  Future<void> _checkMissions() async {
    final newlyCompleted = <MissionSpec>[];
    for (final mission in gameMissions) {
      if (_claimedMissions.contains(mission.id)) continue;
      if (_missionValue(mission) >= mission.target) {
        _claimedMissions.add(mission.id);
        _xp += mission.rewardXp;
        newlyCompleted.add(mission);
      }
    }
    if (newlyCompleted.isEmpty) return;
    if (mounted) setState(() {});
    await _saveProgress();
    for (final mission in newlyCompleted) {
      _message('Mission complete: ${mission.title}  +${mission.rewardXp} XP');
    }
  }

  RankSpec get _currentRank {
    var rank = gameRanks.first;
    for (final candidate in gameRanks) {
      if (_xp >= candidate.minXp) rank = candidate;
    }
    return rank;
  }

  RankSpec? get _nextRank {
    for (final rank in gameRanks) {
      if (rank.minXp > _xp) return rank;
    }
    return null;
  }

  RewardSpec get _selectedReward {
    return gameRewards.firstWhere(
      (reward) => reward.id == _selectedRewardId && _xp >= reward.requiredXp,
      orElse: () => gameRewards.first,
    );
  }

  Future<void> _trackProgressDistance(LatLng rawPoint, Position p) async {
    if (_route == null || _arrivalAwardedForCurrentRoute) {
      _lastProgressPoint = null;
      return;
    }
    if (!p.accuracy.isFinite || p.accuracy > 45 || _lastSpeedMps < 1.0) {
      return;
    }

    final previous = _lastProgressPoint;
    _lastProgressPoint = rawPoint;
    if (previous == null) return;

    final meters = Geolocator.distanceBetween(
      previous.latitude,
      previous.longitude,
      rawPoint.latitude,
      rawPoint.longitude,
    );
    // Ignore GPS drift and impossible one-sample jumps.
    if (!meters.isFinite || meters < 2 || meters > 180) return;

    final km = meters / 1000.0;
    _totalDrivenKm += km;
    _distanceSinceLastProgressSaveKm += km;
    if (mounted) setState(() {});

    if (_distanceSinceLastProgressSaveKm >= 0.25) {
      _distanceSinceLastProgressSaveKm = 0;
      await _saveProgress();
      await _checkMissions();
    }
  }

  Future<void> _recordTripArrival() async {
    if (_arrivalAwardedForCurrentRoute) return;
    _arrivalAwardedForCurrentRoute = true;
    _completedTrips++;
    _lastProgressPoint = null;
    _remainingRouteDistanceMeters = 0;
    _remainingRouteDurationSeconds = 0;
    if (mounted) setState(() {});
    await _saveProgress();
    await _checkMissions();
    _message('Trip complete • $_completedTrips total trips');
  }

  void _startCompass() {
    final events = FlutterCompass.events;
    if (events == null) return;
    _compassSub = events.listen((event) {
      final heading = event.heading;
      if (heading == null || !heading.isFinite) return;
      _deviceHeading = _normalizeHeading(heading);

      // When standing still or moving slowly, GPS course is noisy or missing.
      // In that state the arrow follows the physical orientation of the phone.
      if (_lastSpeedMps < 2.8) {
        _targetHeading = _deviceHeading!;
      }
    });
  }

  Future<void> _prepareThemeStyle(GameThemeSpec theme) async {
    final token = ++_styleBuildToken;
    if (mounted) {
      setState(() {
        _mapStylePrepared = false;
        _mapVisible = false;
        _styleReady = false;
      });
    }

    String resolvedStyle;
    try {
      resolvedStyle = await GameStyleBuilder.build(theme);
    } catch (_) {
      resolvedStyle = theme.mapStyle;
    }

    if (!mounted || token != _styleBuildToken || theme.id != _theme.id) return;
    setState(() {
      _resolvedMapStyle = resolvedStyle;
      _mapStylePrepared = true;
      _styleRevision++;
      _styleReady = false;
      _mapVisible = false;
      _map = null;
      _vehicle = null;
      _renderedDisplayPoint = null;
      _routeGlowLine = null;
      _routeLine = null;
      _trafficSignalCircles.clear();
    });
  }

  Future<void> _startLocation() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      if (mounted) setState(() => _gpsIssue = 'Location services are turned off');
      return;
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      if (mounted) setState(() => _gpsIssue = 'Location permission is required');
      return;
    }

    const settings = LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 0,
    );

    _positionSub = Geolocator.getPositionStream(locationSettings: settings)
        .listen(_onPosition);

    try {
      await _onPosition(
        await Geolocator.getCurrentPosition(locationSettings: settings),
      );
    } catch (_) {}
  }

  Future<void> _onPosition(Position p) async {
    _lastPosition = p;
    _lastSpeedMps = p.speed.isFinite && p.speed > 0 ? p.speed : 0;

    if (mounted && _gpsIssue != null) {
      setState(() => _gpsIssue = null);
    }

    final map = _map;
    if (map == null || !_styleReady) return;

    final rawPoint = LatLng(p.latitude, p.longitude);
    unawaited(_trackProgressDistance(rawPoint, p));
    _targetHeading = _preferredHeading(p);

    // STRICT ROAD LOCK. The raw GPS point is never drawn. During navigation
    // use the route geometry as the primary map-matching surface. If that
    // cannot produce a plausible point, keep the last confirmed road point
    // while a fresh nearest-road match is requested.
    LatLng? displayPoint;
    final route = _route;
    var routeMatchDistanceMeters = double.infinity;
    if (route != null && route.geometry.isNotEmpty) {
      final nearest = _nearestPointOnGeometry(rawPoint, route.geometry);
      routeMatchDistanceMeters = nearest.$2;
      final maxSnapDistance =
          math.min(120.0, math.max(55.0, p.accuracy * 2.2)).toDouble();
      if (nearest.$2 <= maxSnapDistance) {
        displayPoint = nearest.$1;
        _roadSnapPoint = displayPoint;
      }
    }

    if (displayPoint == null) {
      unawaited(_refreshRoadSnapIfNeeded(rawPoint));
      displayPoint = _roadSnapPoint;
    }

    if (displayPoint == null) return;

    // GPS updates only move the TARGET. The visible marker and camera are
    // updated by a 10 fps render loop. This prevents animation queues, freezes
    // and the large catch-up jumps that occurred when every GPS sample called
    // animateCamera directly.
    _targetDisplayPoint = displayPoint;
    _renderedDisplayPoint ??= displayPoint;
    if (_renderedHeading == 0) _renderedHeading = _targetHeading;
    if (route != null) {
      _lastRouteMatchDistanceMeters = routeMatchDistanceMeters;
      _updateRouteProgress(displayPoint);
    }

    unawaited(_maybeReroute(p));
    unawaited(_refreshTrafficSignalsIfNeeded(displayPoint));
    _updateNextTrafficSignal(displayPoint);
  }

  double _preferredHeading(Position p) {
    final courseValid =
        p.heading.isFinite && p.heading >= 0 && p.heading <= 360;
    final device = _deviceHeading;

    // Above ~10 km/h, GPS course is normally more stable inside a vehicle.
    // Below that speed, use the device compass so rotating the phone rotates
    // the arrow immediately instead of leaving it stuck on the old course.
    if (_lastSpeedMps >= 2.8 && courseValid) {
      return _normalizeHeading(p.heading);
    }
    if (device != null && device.isFinite) return _normalizeHeading(device);
    if (courseValid) return _normalizeHeading(p.heading);
    return _targetHeading;
  }

  double _normalizeHeading(double value) {
    var result = value % 360.0;
    if (result < 0) result += 360.0;
    return result;
  }

  double _lerpHeading(double from, double to, double t) {
    final a = _normalizeHeading(from);
    final b = _normalizeHeading(to);
    var delta = ((b - a + 540.0) % 360.0) - 180.0;
    if (!delta.isFinite) delta = 0;
    return _normalizeHeading(a + delta * t.clamp(0.0, 1.0));
  }

  LatLng _moveToward(LatLng from, LatLng to, double maxMeters) {
    final distance = Geolocator.distanceBetween(
      from.latitude,
      from.longitude,
      to.latitude,
      to.longitude,
    );
    if (!distance.isFinite || distance <= maxMeters || distance < 0.25) {
      return to;
    }
    final ratio = (maxMeters / distance).clamp(0.0, 1.0);
    return LatLng(
      from.latitude + (to.latitude - from.latitude) * ratio,
      from.longitude + (to.longitude - from.longitude) * ratio,
    );
  }

  Future<void> _renderFrame() async {
    if (_renderTickBusy || !_styleReady || !_mapVisible) return;
    final map = _map;
    final target = _targetDisplayPoint;
    if (map == null || target == null) return;

    _renderTickBusy = true;
    try {
      var rendered = _renderedDisplayPoint ?? target;
      final maxStepMeters = math.max(
        2.0,
        math.min(9.0, _lastSpeedMps * 0.22 + 1.6),
      );
      rendered = _moveToward(rendered, target, maxStepMeters);
      _renderedDisplayPoint = rendered;

      final headingAlpha = _lastSpeedMps >= 2.8 ? 0.34 : 0.22;
      _renderedHeading =
          _lerpHeading(_renderedHeading, _targetHeading, headingAlpha);

      if (_vehicle == null) {
        _vehicle = await map.addSymbol(
          SymbolOptions(
            geometry: rendered,
            iconImage: 'vehicle-marker',
            iconSize: 0.56,
            iconRotate: _following ? 0.0 : _renderedHeading,
            iconAnchor: 'center',
          ),
        );
      } else {
        await map.updateSymbol(
          _vehicle!,
          SymbolOptions(
            geometry: rendered,
            iconRotate: _following ? 0.0 : _renderedHeading,
          ),
        );
      }

      if (_following) {
        final now = DateTime.now();
        if (_lastCameraFrameAt == null ||
            now.difference(_lastCameraFrameAt!) >=
                const Duration(milliseconds: 150)) {
          _lastCameraFrameAt = now;
          final speedKmh = _lastSpeedMps * 3.6;

          // DRIVER POV: MapLibre is still a navigation map (not Street View),
          // but the camera is now pushed close to the road with a near-horizon
          // pitch. The camera looks farther ahead than the vehicle position so
          // the marker stays in the lower third of the screen instead of the
          // centre. When a route is active, the camera follows the road tangent
          // so the lane ahead remains visually stable even while GPS/compass
          // heading is noisy.
          final zoom = speedKmh > 100
              ? 17.55
              : speedKmh > 70
                  ? 17.85
                  : speedKmh > 40
                      ? 18.15
                      : speedKmh > 15
                          ? 18.45
                          : 18.70;
          final tilt = speedKmh > 80
              ? 60.0
              : speedKmh > 35
                  ? 59.0
                  : 57.0;
          final lookAheadMeters = speedKmh > 100
              ? 235.0
              : speedKmh > 70
                  ? 190.0
                  : speedKmh > 40
                      ? 145.0
                      : speedKmh > 15
                          ? 112.0
                          : 88.0;
          final routeHeading = _routeCameraHeading(rendered);
          final cameraHeading = routeHeading == null
              ? _renderedHeading
              : _lerpHeading(_renderedHeading, routeHeading, 0.78);
          final cameraTarget =
              _pointAhead(rendered, cameraHeading, lookAheadMeters);
          await _moveCamera(
            CameraUpdate.newCameraPosition(
              CameraPosition(
                target: cameraTarget,
                zoom: zoom,
                bearing: cameraHeading,
                tilt: tilt,
              ),
            ),
          );
        }
      }
    } catch (_) {
      // A single renderer/platform-channel hiccup must not stall navigation.
    } finally {
      _renderTickBusy = false;
    }
  }

  Future<void> _refreshRoadSnapIfNeeded(LatLng rawPoint) async {
    if (_roadSnapBusy) return;
    final now = DateTime.now();
    final lastAt = _lastRoadSnapAt;
    final lastPoint = _lastRoadSnapRequestPoint;
    if (lastAt != null &&
        now.difference(lastAt) < const Duration(seconds: 2) &&
        lastPoint != null &&
        Geolocator.distanceBetween(
              rawPoint.latitude,
              rawPoint.longitude,
              lastPoint.latitude,
              lastPoint.longitude,
            ) <
            8) {
      return;
    }

    _roadSnapBusy = true;
    _lastRoadSnapAt = now;
    _lastRoadSnapRequestPoint = rawPoint;
    try {
      final snapped = await OpenMapServices.nearestRoad(rawPoint);
      if (snapped == null) return;

      // Never accept a wildly distant road match. A bad GPS fix should freeze
      // the marker at the last verified road position instead of teleporting it
      // hundreds of metres away.
      final accuracy = _lastPosition?.accuracy ?? 25.0;
      final maxAllowedSnapMeters =
          math.min(160.0, math.max(55.0, accuracy * 2.5)).toDouble();
      if (!snapped.distanceMeters.isFinite ||
          snapped.distanceMeters > maxAllowedSnapMeters) {
        return;
      }
      _roadSnapPoint = snapped.point;
      if (_lastPosition != null && mounted) {
        await _onPosition(_lastPosition!);
      }
    } catch (_) {
      // If the snap service is temporarily unavailable, keep the previous road
      // position and try again after the throttle window.
    } finally {
      _roadSnapBusy = false;
    }
  }

  (LatLng, double) _nearestPointOnGeometry(
    LatLng point,
    List<LatLng> geometry,
  ) {
    if (geometry.isEmpty) return (point, double.infinity);
    if (geometry.length == 1) {
      return (
        geometry.first,
        Geolocator.distanceBetween(
          point.latitude,
          point.longitude,
          geometry.first.latitude,
          geometry.first.longitude,
        ),
      );
    }

    const earthRadius = 6371000.0;
    final lat0 = point.latitude * math.pi / 180.0;
    final cosLat = math.max(0.00001, math.cos(lat0)).toDouble();

    (double, double) xy(LatLng p) {
      final x = (p.longitude - point.longitude) *
          math.pi / 180.0 * earthRadius * cosLat;
      final y = (p.latitude - point.latitude) * math.pi / 180.0 * earthRadius;
      return (x, y);
    }

    var bestDistance = double.infinity;
    var bestX = 0.0;
    var bestY = 0.0;
    for (var i = 0; i < geometry.length - 1; i++) {
      final a = xy(geometry[i]);
      final b = xy(geometry[i + 1]);
      final dx = b.$1 - a.$1;
      final dy = b.$2 - a.$2;
      final len2 = dx * dx + dy * dy;
      final t = len2 <= 0.0001
          ? 0.0
          : (-(a.$1 * dx + a.$2 * dy) / len2).clamp(0.0, 1.0).toDouble();
      final nearestX = a.$1 + t * dx;
      final nearestY = a.$2 + t * dy;
      final distance = math.sqrt(nearestX * nearestX + nearestY * nearestY);
      if (distance < bestDistance) {
        bestDistance = distance;
        bestX = nearestX;
        bestY = nearestY;
      }
    }

    final snappedLat =
        point.latitude + (bestY / earthRadius) * 180.0 / math.pi;
    final snappedLon = point.longitude +
        (bestX / (earthRadius * cosLat)) * 180.0 / math.pi;
    return (LatLng(snappedLat, snappedLon), bestDistance);
  }

  Future<void> _refreshTrafficSignalsIfNeeded(LatLng center) async {
    if (_signalsBusy) return;
    final now = DateTime.now();
    final lastCenter = _lastSignalsCenter;
    if (_lastSignalsFetchAt != null &&
        now.difference(_lastSignalsFetchAt!) < const Duration(seconds: 75) &&
        lastCenter != null &&
        Geolocator.distanceBetween(
              center.latitude,
              center.longitude,
              lastCenter.latitude,
              lastCenter.longitude,
            ) <
            500) {
      return;
    }

    _signalsBusy = true;
    _lastSignalsFetchAt = now;
    _lastSignalsCenter = center;
    try {
      final signals = await OpenMapServices.trafficSignalsNear(center);
      if (!mounted) return;
      _trafficSignals = signals;
      await _redrawTrafficSignals();
      _updateNextTrafficSignal(center);
    } catch (_) {
      // Signal positions are supplemental; navigation continues if Overpass is
      // temporarily unavailable.
    } finally {
      _signalsBusy = false;
    }
  }

  Future<void> _redrawTrafficSignals() async {
    final map = _map;
    if (map == null || !_styleReady) return;
    for (final circle in List<Circle>.from(_trafficSignalCircles)) {
      try {
        await map.removeCircle(circle);
      } catch (_) {}
    }
    _trafficSignalCircles.clear();

    for (final signal in _trafficSignals.take(60)) {
      try {
        final circle = await map.addCircle(
          CircleOptions(
            geometry: signal.point,
            circleRadius: 5.5,
            circleColor: '#F5B642',
            circleStrokeColor: '#15110A',
            circleStrokeWidth: 2.0,
            circleOpacity: 0.95,
          ),
        );
        _trafficSignalCircles.add(circle);
      } catch (_) {}
    }
  }

  void _updateNextTrafficSignal(LatLng vehiclePoint) {
    final route = _route;
    if (route == null || route.geometry.isEmpty || _trafficSignals.isEmpty) {
      if (_nextTrafficSignal != null || _distanceToNextTrafficSignal != null) {
        if (mounted) {
          setState(() {
            _nextTrafficSignal = null;
            _distanceToNextTrafficSignal = null;
          });
        }
      }
      return;
    }

    final currentIndex = _nearestRouteVertexIndex(vehiclePoint, route.geometry);
    TrafficSignalInfo? best;
    double bestDistance = double.infinity;
    var bestRouteIndex = 1 << 30;

    for (final signal in _trafficSignals) {
      final distance = Geolocator.distanceBetween(
        vehiclePoint.latitude,
        vehiclePoint.longitude,
        signal.point.latitude,
        signal.point.longitude,
      );
      if (distance > 550) continue;
      final snap = _nearestPointOnGeometry(signal.point, route.geometry);
      if (snap.$2 > 32) continue;
      final routeIndex = _nearestRouteVertexIndex(signal.point, route.geometry);
      if (routeIndex + 2 < currentIndex) continue;
      if (routeIndex < bestRouteIndex ||
          (routeIndex == bestRouteIndex && distance < bestDistance)) {
        best = signal;
        bestDistance = distance;
        bestRouteIndex = routeIndex;
      }
    }

    final changedId = best?.id != _nextTrafficSignal?.id;
    final changedDistance = (_distanceToNextTrafficSignal == null && best != null) ||
        (_distanceToNextTrafficSignal != null &&
            best != null &&
            (bestDistance - _distanceToNextTrafficSignal!).abs() >= 8) ||
        (best == null && _distanceToNextTrafficSignal != null);
    if ((changedId || changedDistance) && mounted) {
      setState(() {
        _nextTrafficSignal = best;
        _distanceToNextTrafficSignal = best == null ? null : bestDistance;
      });
    }
  }

  int _nearestRouteVertexIndex(LatLng point, List<LatLng> geometry) {
    var bestIndex = 0;
    var bestDistance = double.infinity;
    for (var i = 0; i < geometry.length; i++) {
      final d = Geolocator.distanceBetween(
        point.latitude,
        point.longitude,
        geometry[i].latitude,
        geometry[i].longitude,
      );
      if (d < bestDistance) {
        bestDistance = d;
        bestIndex = i;
      }
    }
    return bestIndex;
  }

  void _prepareRouteProgressCache() {
    final route = _route;
    if (route == null || route.geometry.isEmpty) {
      _routeRemainingGeometryMeters = const [];
      _remainingRouteDistanceMeters = null;
      _remainingRouteDurationSeconds = null;
      _lastRouteVertexIndex = 0;
      _lastRouteMatchDistanceMeters = double.infinity;
      return;
    }

    final geometry = route.geometry;
    final remaining = List<double>.filled(geometry.length, 0.0);
    for (var i = geometry.length - 2; i >= 0; i--) {
      remaining[i] = remaining[i + 1] +
          Geolocator.distanceBetween(
            geometry[i].latitude,
            geometry[i].longitude,
            geometry[i + 1].latitude,
            geometry[i + 1].longitude,
          );
    }
    _routeRemainingGeometryMeters = remaining;
    _remainingRouteDistanceMeters = route.distanceMeters;
    _remainingRouteDurationSeconds = route.durationSeconds;
    _lastRouteVertexIndex = 0;
    _lastRouteMatchDistanceMeters = double.infinity;
  }

  int _nearestRouteVertexIndexWindowed(
    LatLng point,
    List<LatLng> geometry,
  ) {
    if (geometry.isEmpty) return 0;
    if (_lastRouteVertexIndex < 0 ||
        _lastRouteVertexIndex >= geometry.length) {
      return _nearestRouteVertexIndex(point, geometry);
    }

    final start = math.max(0, _lastRouteVertexIndex - 45);
    final end = math.min(geometry.length - 1, _lastRouteVertexIndex + 220);
    var bestIndex = start;
    var bestDistance = double.infinity;
    for (var i = start; i <= end; i++) {
      final d = Geolocator.distanceBetween(
        point.latitude,
        point.longitude,
        geometry[i].latitude,
        geometry[i].longitude,
      );
      if (d < bestDistance) {
        bestDistance = d;
        bestIndex = i;
      }
    }

    // If the cached window no longer makes sense (reroute, GPS recovery, or a
    // large jump), fall back to one full scan and re-seed the cache.
    if (bestDistance > 180 || bestIndex == start || bestIndex == end) {
      return _nearestRouteVertexIndex(point, geometry);
    }
    return bestIndex;
  }

  void _updateRouteProgress(LatLng vehiclePoint) {
    final route = _route;
    if (route == null || route.geometry.isEmpty) return;
    if (_routeRemainingGeometryMeters.length != route.geometry.length) {
      _prepareRouteProgressCache();
    }
    if (_routeRemainingGeometryMeters.isEmpty) return;

    final index = _nearestRouteVertexIndexWindowed(vehiclePoint, route.geometry);
    _lastRouteVertexIndex = index;

    final geometryTotal = _routeRemainingGeometryMeters.first;
    if (!geometryTotal.isFinite || geometryTotal <= 0) return;
    final geometryRemaining = _routeRemainingGeometryMeters[index];
    final ratio = (geometryRemaining / geometryTotal).clamp(0.0, 1.0).toDouble();
    final nextDistance = route.distanceMeters * ratio;
    final nextDuration = route.durationSeconds * ratio;

    final distanceChanged = _remainingRouteDistanceMeters == null ||
        (nextDistance - _remainingRouteDistanceMeters!).abs() >= 20;
    final durationChanged = _remainingRouteDurationSeconds == null ||
        (nextDuration - _remainingRouteDurationSeconds!).abs() >= 8;
    _remainingRouteDistanceMeters = nextDistance;
    _remainingRouteDurationSeconds = nextDuration;
    if ((distanceChanged || durationChanged) && mounted) {
      setState(() {});
    }
  }

  double? _routeCameraHeading(LatLng point) {
    final route = _route;
    if (route == null || route.geometry.length < 2) return null;

    // The expensive nearest-route scan is done on GPS updates, not on every
    // render frame. This keeps the camera smooth on long routes.
    if (_lastRouteMatchDistanceMeters > 65) return null;

    final geometry = route.geometry;
    final index =
        _lastRouteVertexIndex.clamp(0, geometry.length - 1).toInt();
    final startIndex = index >= geometry.length - 1 ? geometry.length - 2 : index;
    final endIndex = math.min(geometry.length - 1, startIndex + 3);
    final a = geometry[startIndex];
    final b = geometry[endIndex];

    final lat1 = a.latitude * math.pi / 180.0;
    final lat2 = b.latitude * math.pi / 180.0;
    final deltaLon = (b.longitude - a.longitude) * math.pi / 180.0;
    final y = math.sin(deltaLon) * math.cos(lat2);
    final x = math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(deltaLon);
    final bearing = math.atan2(y, x) * 180.0 / math.pi;
    return _normalizeHeading(bearing);
  }

  LatLng _pointAhead(LatLng from, double bearingDegrees, double meters) {
    if (!bearingDegrees.isFinite || meters <= 0) return from;

    const earthRadius = 6371000.0;
    final angularDistance = meters / earthRadius;
    final bearing = bearingDegrees * math.pi / 180.0;
    final lat1 = from.latitude * math.pi / 180.0;
    final lon1 = from.longitude * math.pi / 180.0;

    final lat2 = math.asin(
      math.sin(lat1) * math.cos(angularDistance) +
          math.cos(lat1) * math.sin(angularDistance) * math.cos(bearing),
    );
    final lon2 = lon1 +
        math.atan2(
          math.sin(bearing) * math.sin(angularDistance) * math.cos(lat1),
          math.cos(angularDistance) - math.sin(lat1) * math.sin(lat2),
        );

    return LatLng(lat2 * 180.0 / math.pi, lon2 * 180.0 / math.pi);
  }

  Future<void> _moveCamera(CameraUpdate update) async {
    final map = _map;
    if (map == null) return;

    _programmaticCameraMove = true;
    try {
      // MapLibre 0.26.x exposes linear easeCamera specifically for continuous
      // GPS tracking. Successive updates keep a constant visual velocity and
      // avoid the stop/start effect of the old ease-in/ease-out animations.
      await map.easeCamera(
        update,
        duration: const Duration(milliseconds: 120),
        interpolation: CameraAnimationInterpolation.linear,
      );
    } finally {
      _programmaticCameraMove = false;
    }
  }

  void _handleCameraMove(CameraPosition _) {
    if (!mounted || _programmaticCameraMove || !_following) return;
    setState(() => _following = false);
  }

  double _distanceToRouteMeters(LatLng point, List<LatLng> geometry) {
    return _nearestPointOnGeometry(point, geometry).$2;
  }

  Future<void> _maybeReroute(Position p) async {
    final route = _route;
    final destination = _destination;
    if (route == null || destination == null || _rerouting) return;

    // Very inaccurate fixes are ignored so a bad GPS sample cannot cause a
    // false reroute.
    if (!p.accuracy.isFinite || p.accuracy > 80) return;

    final distanceToDestination = Geolocator.distanceBetween(
      p.latitude,
      p.longitude,
      destination.lat,
      destination.lon,
    );
    if (distanceToDestination < 60) {
      _offRouteSamples = 0;
      unawaited(_recordTripArrival());
      return;
    }

    final distance = _distanceToRouteMeters(
      LatLng(p.latitude, p.longitude),
      route.geometry,
    );
    final threshold = math.max(35.0, p.accuracy * 1.8);

    if (distance > threshold) {
      _offRouteSamples++;
    } else if (distance < threshold * 0.65) {
      _offRouteSamples = 0;
    }

    if (_offRouteSamples < 3) return;

    final now = DateTime.now();
    if (_lastRerouteAt != null &&
        now.difference(_lastRerouteAt!) < const Duration(seconds: 10)) {
      return;
    }

    _offRouteSamples = 0;
    _lastRerouteAt = now;
    if (mounted) {
      setState(() => _rerouting = true);
    } else {
      _rerouting = true;
    }

    try {
      final routes = await OpenMapServices.routes(
        LatLng(p.latitude, p.longitude),
        LatLng(destination.lat, destination.lon),
      );
      if (!mounted || routes.isEmpty) return;

      setState(() {
        _routeOptions = routes;
        _selectedRouteIndex = 0;
        _following = true;
      });
      _prepareRouteProgressCache();
      await _redrawRoute();

      // Return immediately to navigation view instead of showing another
      // high route overview every time the driver misses a turn.
      if (_lastPosition != null) {
        await _onPosition(_lastPosition!);
      }
      _message('Route updated from your current position');
    } catch (_) {
      // Keep the old route on screen and retry after new GPS samples.
      _message('Could not recalculate the route right now');
    } finally {
      if (mounted) {
        setState(() => _rerouting = false);
      } else {
        _rerouting = false;
      }
    }
  }

  void _onMapCreated(MapLibreMapController controller) {
    _map = controller;
    final revision = _styleRevision;
    final customizedStyle = _resolvedMapStyle != _theme.mapStyle;

    // If a generated game style is rejected by the native renderer, recover
    // automatically to the known upstream style instead of leaving a black
    // screen indefinitely. The second attempt is the provider's original style.
    Future<void>.delayed(const Duration(seconds: 8), () {
      if (!mounted || _styleReady || revision != _styleRevision) return;
      if (!customizedStyle) {
        _message('Map tiles are taking longer than expected to load.');
        return;
      }
      setState(() {
        _resolvedMapStyle = _theme.mapStyle;
        _styleRevision++;
        _map = null;
        _vehicle = null;
        _routeGlowLine = null;
        _routeLine = null;
        _trafficSignalCircles.clear();
      });
    });
  }

  Future<void> _onStyleLoaded() async {
    _styleReady = true;
    try {
      final bytes = await rootBundle.load('assets/icons/vehicle.png');
      await _map?.addImage(
        'vehicle-marker',
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      );
      await _redrawRoute();
      await _redrawTrafficSignals();
      if (_lastPosition != null) await _onPosition(_lastPosition!);
    } catch (_) {
      // Do not trap the app behind a loading screen if an annotation/image
      // refresh fails; the base map can still remain usable.
    } finally {
      await Future<void>.delayed(const Duration(milliseconds: 280));
      if (mounted) setState(() => _mapVisible = true);
    }
  }

  Future<void> _redrawRoute() async {
    final map = _map;
    final route = _route;
    if (map == null || !_styleReady || route == null) return;

    if (_routeGlowLine != null) {
      try {
        await map.removeLine(_routeGlowLine!);
      } catch (_) {}
      _routeGlowLine = null;
    }
    if (_routeLine != null) {
      try {
        await map.removeLine(_routeLine!);
      } catch (_) {}
      _routeLine = null;
    }

    _routeGlowLine = await map.addLine(
      LineOptions(
        geometry: route.geometry,
        lineColor: _theme.routeColor,
        lineWidth: 15,
        lineOpacity: 0.22,
        lineBlur: 3.0,
        lineJoin: 'round',
      ),
    );
    _routeLine = await map.addLine(
      LineOptions(
        geometry: route.geometry,
        lineColor: _theme.routeColor,
        lineWidth: 7,
        lineOpacity: 0.98,
        lineJoin: 'round',
      ),
    );
  }

  Future<void> _searchDestination() async {
    final query = _searchController.text.trim();
    if (query.isEmpty || _busy) return;
    if (query.length > 160) {
      _message('Search is too long. Please use a shorter place or address.');
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() => _busy = true);

    try {
      var results = await OpenMapServices.search(query, bias: _lastPosition);
      if (!mounted) return;

      final p = _lastPosition;
      if (p != null && results.isNotEmpty) {
        results = await OpenMapServices.addTravelEstimates(
          LatLng(p.latitude, p.longitude),
          results,
        );
      }
      if (!mounted) return;

      if (results.isEmpty) {
        _message('No destination found. Try adding a city or street.');
        return;
      }

      final chosen = await showModalBottomSheet<SearchResult>(
        context: context,
        showDragHandle: true,
        backgroundColor: _theme.panel,
        builder: (context) => Directionality(
          textDirection: TextDirection.ltr,
          child: SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: [
                ListTile(
                  leading: Icon(Icons.search, color: _theme.accent),
                  title: Text(
                    'Search results',
                    style: gameDisplayStyle(fontSize: 24),
                  ),
                ),
                ...results.map(
                  (r) => ListTile(
                    leading: Icon(Icons.place, color: _theme.accent),
                    title: Text(
                      r.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    subtitle: Text(
                      [
                        if (r.subtitle != null && r.subtitle!.isNotEmpty)
                          r.subtitle!,
                        if (r.distanceMeters != null)
                          '${(r.distanceMeters! / 1000).toStringAsFixed(1)} km',
                      ].join(' • '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: r.durationSeconds == null
                        ? null
                        : Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                '${(r.durationSeconds! / 60).round()} min',
                                style: TextStyle(
                                  color: _theme.accent,
                                  fontWeight: FontWeight.w900,
                                  fontSize: 16,
                                ),
                              ),
                              Text(
                                _arrivalTime(r.durationSeconds!),
                                style: TextStyle(
                                  color: _theme.foreground.withValues(alpha: 0.7),
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                    onTap: () => Navigator.pop(context, r),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      if (chosen != null) await _buildRoutes(chosen);
    } on TimeoutException {
      _message('Search timed out. Please try again.');
    } catch (_) {
      _message('Search service is unavailable right now.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _buildRoutes(SearchResult destination) async {
    final p = _lastPosition;
    final map = _map;
    if (p == null || map == null || !_styleReady) {
      _message('Waiting for an accurate GPS position.');
      return;
    }

    setState(() => _busy = true);

    try {
      final routes = await OpenMapServices.routes(
        LatLng(p.latitude, p.longitude),
        LatLng(destination.lat, destination.lon),
      );
      if (!mounted || routes.isEmpty) return;

      setState(() {
        _destination = destination;
        _routeOptions = routes;
        _selectedRouteIndex = 0;
        _following = false;
        _offRouteSamples = 0;
        _arrivalAwardedForCurrentRoute = false;
        _lastProgressPoint = null;
      });
      _prepareRouteProgressCache();
      _searchController.clear();

      await _redrawRoute();

      // Enter navigation view immediately. The full-route overview was
      // intentionally removed because it made the live view feel distant
      // and forced the driver to wait before the camera followed the car.
      if (mounted && identical(_destination, destination)) {
        setState(() => _following = true);
        if (_lastPosition != null) await _onPosition(_lastPosition!);
      }
    } on TimeoutException {
      _message('Route calculation timed out. Please try again.');
    } catch (_) {
      _message('Could not calculate a route right now.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _selectRoute(int index) async {
    if (index < 0 || index >= _routeOptions.length) return;
    setState(() {
      _selectedRouteIndex = index;
      _following = false;
      _offRouteSamples = 0;
    });
    _prepareRouteProgressCache();
    await _redrawRoute();
    if (!mounted) return;
    setState(() => _following = true);
    if (_lastPosition != null) await _onPosition(_lastPosition!);
  }

  void _changeTheme(GameThemeSpec theme) {
    if (theme.id == _theme.id) return;
    Navigator.pop(context);
    setState(() {
      _theme = theme;
      _mapStylePrepared = false;
      _mapVisible = false;
      _styleReady = false;
      _map = null;
      _vehicle = null;
      _renderedDisplayPoint = null;
      _routeGlowLine = null;
      _routeLine = null;
      _trafficSignalCircles.clear();
    });
    _usedThemes.add(theme.id);
    unawaited(_saveProgress());
    unawaited(_checkMissions());
    unawaited(_prepareThemeStyle(theme));
  }

  void _showThemeSheet() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: _theme.panel,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.62,
        minChildSize: 0.35,
        maxChildSize: 0.92,
        builder: (context, scrollController) => Directionality(
          textDirection: TextDirection.ltr,
          child: SafeArea(
            child: ListView(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 24),
              children: [
                Text(
                  'Game Themes',
                  style: gameDisplayStyle(fontSize: 28),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Choose the visual world for your navigation.',
                ),
                const SizedBox(height: 14),
                ...gameThemes.map(
                  (theme) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                        side: BorderSide(
                          color: theme.id == _theme.id
                              ? theme.accent
                              : Colors.white12,
                        ),
                      ),
                      tileColor: theme.panel,
                      leading: CircleAvatar(
                        backgroundColor: theme.accent,
                        foregroundColor: Colors.black,
                        child: Icon(theme.icon),
                      ),
                      title: Text(
                        theme.name,
                        style: gameDisplayStyle(fontSize: 20),
                      ),
                      subtitle: Text(theme.tagline),
                      trailing: theme.id == _theme.id
                          ? Icon(Icons.check_circle, color: theme.accent)
                          : const Icon(Icons.chevron_right),
                      onTap: () => _changeTheme(theme),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showReportSheet() {
    const reports = <(IconData, String)>[
      (Icons.traffic, 'Traffic jam'),
      (Icons.block, 'Road closure'),
      (Icons.car_crash, 'Crash'),
      (Icons.construction, 'Roadworks'),
      (Icons.warning_amber_rounded, 'Road hazard'),
      (Icons.car_repair, 'Stopped vehicle'),
      (Icons.water, 'Flooding'),
      (Icons.traffic_outlined, 'Broken traffic light'),
      (Icons.shield_outlined, 'Enforcement activity in the area'),
    ];

    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: _theme.panel,
      builder: (context) => Directionality(
        textDirection: TextDirection.ltr,
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(Icons.campaign, color: _theme.accent),
                    const SizedBox(width: 8),
                    Text(
                      'Road report',
                      style: gameDisplayStyle(fontSize: 26),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: reports
                      .map(
                        (r) => ActionChip(
                          avatar: Icon(r.$1, size: 20, color: _theme.accent),
                          label: Text(r.$2),
                          onPressed: () {
                            if (_lastSpeedMps > 1.5) {
                              Navigator.pop(context);
                              _message('For safety, add road reports only while stopped.');
                              return;
                            }
                            final now = DateTime.now();
                            final xpEligible =
                                r.$2 != 'Enforcement activity in the area' &&
                                (_lastXpEligibleReportAt == null ||
                                    now.difference(_lastXpEligibleReportAt!) >=
                                        const Duration(seconds: 60));
                            setState(() {
                              if (_reports.length >= 100) _reports.removeAt(0);
                              _reports.add(CommunityReport(r.$2));
                              if (xpEligible) {
                                _reportedEvents++;
                                _lastXpEligibleReportAt = now;
                              }
                            });
                            Navigator.pop(context);
                            unawaited(_saveProgress());
                            if (xpEligible) unawaited(_checkMissions());
                            _message(
                              xpEligible
                                  ? 'Report “${r.$2}” saved on this device.'
                                  : 'Report saved. XP report cooldown is active.',
                            );
                          },
                        ),
                      )
                      .toList(),
                ),
                const SizedBox(height: 14),
                Text(
                  'Reports added on this device: ${_reports.length}. For safety, reports are enabled only while stopped. Server sync will later add verification, expiry and trust scoring.',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }


  void _showProgressSheet() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: _theme.panel,
      builder: (context) => DefaultTabController(
        length: 4,
        child: DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.78,
          minChildSize: 0.48,
          maxChildSize: 0.94,
          builder: (context, scrollController) => SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
                  child: _progressHeader(),
                ),
                TabBar(
                  isScrollable: true,
                  labelStyle: gameDisplayStyle(fontSize: 18),
                  unselectedLabelStyle: gameDisplayStyle(
                    fontSize: 18,
                    color: _theme.foreground.withValues(alpha: 0.58),
                  ),
                  tabs: const [
                    Tab(text: 'Missions'),
                    Tab(text: 'Ranks'),
                    Tab(text: 'Rewards'),
                    Tab(text: 'Friends'),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      _missionsTab(scrollController),
                      _ranksTab(),
                      _rewardsTab(),
                      _friendsTab(),
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

  Widget _progressHeader() {
    final rank = _currentRank;
    final next = _nextRank;
    final base = rank.minXp;
    final ceiling = next?.minXp ?? math.max(_xp, base + 1);
    final progress = next == null
        ? 1.0
        : ((_xp - base) / math.max(1, ceiling - base)).clamp(0.0, 1.0).toDouble();

    return Row(
      children: [
        CircleAvatar(
          radius: 27,
          backgroundColor: _theme.accent,
          foregroundColor: Colors.black,
          child: Icon(_selectedReward.icon, size: 28),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                rank.name,
                style: gameDisplayStyle(fontSize: 28),
              ),
              Text(
                '$_xp XP • ${_totalDrivenKm.toStringAsFixed(1)} km • $_completedTrips trips',
                style: TextStyle(
                  color: _theme.foreground.withValues(alpha: 0.72),
                ),
              ),
              const SizedBox(height: 7),
              ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 7,
                  backgroundColor: Colors.white10,
                  color: _theme.accent,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                next == null
                    ? 'Maximum rank reached'
                    : '${next.minXp - _xp} XP to ${next.name}',
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _missionsTab(ScrollController controller) {
    return ListView(
      controller: controller,
      padding: const EdgeInsets.all(14),
      children: [
        Text(
          'Missions complete automatically while you navigate. No interaction is required while driving.',
          style: TextStyle(color: _theme.foreground.withValues(alpha: 0.72)),
        ),
        const SizedBox(height: 10),
        ...gameMissions.map((mission) {
          final value = _missionValue(mission);
          final completed = _claimedMissions.contains(mission.id);
          final progress = (value / mission.target).clamp(0.0, 1.0).toDouble();
          final valueLabel = mission.metric == MissionMetric.distanceKm
              ? '${math.min(value, mission.target).toStringAsFixed(1)} / ${mission.target.toStringAsFixed(0)} km'
              : '${math.min(value, mission.target).toInt()} / ${mission.target.toInt()}';
          return Card(
            color: Colors.white.withValues(alpha: 0.045),
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: completed
                    ? _theme.accent
                    : _theme.accent.withValues(alpha: 0.18),
                foregroundColor: completed ? Colors.black : _theme.accent,
                child: Icon(completed ? Icons.check : mission.icon),
              ),
              title: Text(
                mission.title,
                style: gameDisplayStyle(fontSize: 20),
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(mission.description),
                  const SizedBox(height: 7),
                  LinearProgressIndicator(
                    value: completed ? 1 : progress,
                    minHeight: 5,
                    backgroundColor: Colors.white10,
                    color: _theme.accent,
                  ),
                  const SizedBox(height: 4),
                  Text(valueLabel, style: const TextStyle(fontSize: 11)),
                ],
              ),
              trailing: Text(
                '+${mission.rewardXp} XP',
                style: gameDisplayStyle(
                  fontSize: 18,
                  color: _theme.accent,
                ),
              ),
            ),
          );
        }),
      ],
    );
  }

  Widget _ranksTab() {
    return ListView(
      padding: const EdgeInsets.all(14),
      children: gameRanks.map((rank) {
        final unlocked = _xp >= rank.minXp;
        final current = rank.name == _currentRank.name;
        return ListTile(
          leading: CircleAvatar(
            backgroundColor:
                unlocked ? _theme.accent : Colors.white.withValues(alpha: 0.08),
            foregroundColor: unlocked ? Colors.black : Colors.white38,
            child: Icon(rank.icon),
          ),
          title: Text(
            rank.name,
            style: gameDisplayStyle(
              fontSize: current ? 22 : 19,
              color: unlocked ? null : Colors.white38,
            ),
          ),
          subtitle: Text('${rank.minXp} XP'),
          trailing: current
              ? Icon(Icons.radio_button_checked, color: _theme.accent)
              : unlocked
                  ? const Icon(Icons.check)
                  : const Icon(Icons.lock_outline),
        );
      }).toList(),
    );
  }

  Widget _rewardsTab() {
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        Text(
          'Unlock profile icons as you rank up. Tap an unlocked reward to equip it.',
          style: TextStyle(color: _theme.foreground.withValues(alpha: 0.72)),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: gameRewards.map((reward) {
            final unlocked = _xp >= reward.requiredXp;
            final selected = _selectedRewardId == reward.id;
            return InkWell(
              borderRadius: BorderRadius.circular(18),
              onTap: unlocked
                  ? () {
                      setState(() => _selectedRewardId = reward.id);
                      unawaited(_saveProgress());
                      Navigator.pop(context);
                      _message('${reward.name} equipped');
                    }
                  : null,
              child: Container(
                width: 112,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: selected
                      ? _theme.accent.withValues(alpha: 0.18)
                      : Colors.white.withValues(alpha: 0.045),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: selected ? _theme.accent : Colors.white12,
                  ),
                ),
                child: Column(
                  children: [
                    CircleAvatar(
                      backgroundColor:
                          unlocked ? _theme.accent : Colors.white12,
                      foregroundColor:
                          unlocked ? Colors.black : Colors.white30,
                      child: Icon(unlocked ? reward.icon : Icons.lock),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      reward.name,
                      textAlign: TextAlign.center,
                      style: gameDisplayStyle(fontSize: 18),
                    ),
                    Text(
                      reward.requiredXp == 0
                          ? 'Unlocked'
                          : '${reward.requiredXp} XP',
                      style: const TextStyle(fontSize: 11),
                    ),
                  ],
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }

  Widget _friendsTab() {
    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        Icon(Icons.groups_2, size: 48, color: _theme.accent),
        const SizedBox(height: 12),
        Text(
          'Friends Leaderboard',
          textAlign: TextAlign.center,
          style: gameDisplayStyle(fontSize: 28),
        ),
        const SizedBox(height: 8),
        const Text(
          'The ranking screen is ready, but real friend competition needs GameNav accounts and a backend so XP can sync securely between phones.',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 18),
        Card(
          color: Colors.white.withValues(alpha: 0.045),
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: _theme.accent,
              foregroundColor: Colors.black,
              child: Icon(_selectedReward.icon),
            ),
            title: Text(
              'You',
              style: gameDisplayStyle(fontSize: 20),
            ),
            subtitle: Text(_currentRank.name),
            trailing: Text(
              '$_xp XP',
              style: TextStyle(
                color: _theme.accent,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          'Next backend step: player accounts, friend codes, weekly leagues, anti-cheat checks and synced rewards.',
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  void _showAvoidanceSheet() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: _theme.panel,
      builder: (context) => StatefulBuilder(
        builder: (context, modalSetState) => Directionality(
          textDirection: TextDirection.ltr,
          child: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    leading: Icon(Icons.alt_route, color: _theme.accent),
                    title: const Text(
                      'Route preferences',
                      style: TextStyle(fontSize: 21, fontWeight: FontWeight.bold),
                    ),
                    subtitle: const Text(
                      'Preferences are stored locally. Full route weighting will be connected to the GameNav backend.',
                    ),
                  ),
                  _avoidSwitch('Avoid traffic', avoidTraffic, (v) {
                    modalSetState(() => avoidTraffic = v);
                    setState(() => avoidTraffic = v);
                  }),
                  _avoidSwitch('Avoid road closures', avoidClosures, (v) {
                    modalSetState(() => avoidClosures = v);
                    setState(() => avoidClosures = v);
                  }),
                  _avoidSwitch('Avoid roadworks', avoidRoadworks, (v) {
                    modalSetState(() => avoidRoadworks = v);
                    setState(() => avoidRoadworks = v);
                  }),
                  _avoidSwitch('Avoid hazards', avoidHazards, (v) {
                    modalSetState(() => avoidHazards = v);
                    setState(() => avoidHazards = v);
                  }),
                  _avoidSwitch('Avoid toll roads', avoidTolls, (v) {
                    modalSetState(() => avoidTolls = v);
                    setState(() => avoidTolls = v);
                  }),
                  _avoidSwitch('Avoid unpaved roads', avoidUnpaved, (v) {
                    modalSetState(() => avoidUnpaved = v);
                    setState(() => avoidUnpaved = v);
                  }),
                  const Divider(),
                  _avoidSwitch('Prefer main roads', preferMainRoads, (v) {
                    modalSetState(() => preferMainRoads = v);
                    setState(() => preferMainRoads = v);
                  }),
                  _avoidSwitch('Prefer quieter routes', preferQuietRoads, (v) {
                    modalSetState(() => preferQuietRoads = v);
                    setState(() => preferQuietRoads = v);
                  }),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _avoidSwitch(
    String title,
    bool value,
    ValueChanged<bool> onChanged,
  ) {
    return SwitchListTile(
      activeThumbColor: _theme.accent,
      title: Text(title),
      value: value,
      onChanged: onChanged,
    );
  }

  String _arrivalTime(double durationSeconds) {
    final arrival = DateTime.now().add(
      Duration(seconds: durationSeconds.round()),
    );
    final hour = arrival.hour.toString().padLeft(2, '0');
    final minute = arrival.minute.toString().padLeft(2, '0');
    return 'Arrive $hour:$minute';
  }

  String _routeSummary(RouteResult route) {
    final min = (route.durationSeconds / 60).round();
    return '$min min • ${_arrivalTime(route.durationSeconds)}';
  }

  Widget _navigationSummary() {
    final route = _route;
    if (route == null) return const SizedBox.shrink();
    final remainingDistance =
        _remainingRouteDistanceMeters ?? route.distanceMeters;
    final remainingDuration =
        _remainingRouteDurationSeconds ?? route.durationSeconds;
    final km = remainingDistance / 1000;
    final min = (remainingDuration / 60).ceil();

    // Compact top HUD. Keeping ETA away from the lower navigation viewport
    // guarantees it can never cover the vehicle marker.
    return Material(
      color: _theme.panel.withValues(alpha: 0.94),
      elevation: 6,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '$min min',
              style: TextStyle(
                color: _theme.accent,
                fontSize: 17,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(width: 9),
            Text(
              _arrivalTime(remainingDuration),
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${km.toStringAsFixed(1)} km',
              style: TextStyle(
                fontSize: 12,
                color: _theme.foreground.withValues(alpha: 0.72),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor: _theme.panel,
      ),
    );
  }

  Widget _routeAlternatives() {
    if (_routeOptions.length <= 1) return const SizedBox.shrink();
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: List.generate(_routeOptions.length, (index) {
          final selected = index == _selectedRouteIndex;
          return Padding(
            padding: const EdgeInsets.only(left: 8),
            child: ChoiceChip(
              selected: selected,
              selectedColor: _theme.accent,
              labelStyle: TextStyle(
                color: selected ? Colors.black : Colors.white,
                fontWeight: FontWeight.bold,
              ),
              label: Text('Route ${index + 1} • ${_routeSummary(_routeOptions[index])}'),
              onSelected: (_) => _selectRoute(index),
            ),
          );
        }),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final initialTarget = _lastPosition == null
        ? const LatLng(31.9, 34.8)
        : LatLng(_lastPosition!.latitude, _lastPosition!.longitude);

    return Directionality(
      textDirection: TextDirection.ltr,
      child: Scaffold(
        backgroundColor: _theme.panel,
        body: Stack(
          children: [
            if (_mapStylePrepared)
              MapLibreMap(
                key: ValueKey('${_theme.id}:$_styleRevision'),
                styleString: _resolvedMapStyle,
                initialCameraPosition: CameraPosition(
                  target: initialTarget,
                  zoom: _lastPosition == null ? 9 : 16,
                ),
                onMapCreated: _onMapCreated,
                onStyleLoadedCallback: _onStyleLoaded,
                onCameraMove: _handleCameraMove,
                compassEnabled: false,
              )
            else
              Positioned.fill(
                child: ColoredBox(
                  color: _theme.panel,
                  child: Center(
                    child: CircularProgressIndicator(color: _theme.accent),
                  ),
                ),
              ),
            if (_mapStylePrepared)
              Positioned.fill(child: GameMapFxOverlay(theme: _theme)),
            if (!_mapVisible)
              Positioned.fill(
                child: IgnorePointer(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    color: _theme.panel,
                    alignment: Alignment.center,
                    child: CircularProgressIndicator(color: _theme.accent),
                  ),
                ),
              ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    Material(
                      color: _theme.panel,
                      elevation: 10,
                      borderRadius: BorderRadius.circular(22),
                      child: TextField(
                        controller: _searchController,
                        textInputAction: TextInputAction.search,
                        onSubmitted: (_) => _searchDestination(),
                        style: TextStyle(color: _theme.foreground),
                        decoration: InputDecoration(
                          hintText: 'Where to?',
                          hintStyle: TextStyle(
                            color: _theme.foreground.withValues(alpha: 0.65),
                          ),
                          prefixIcon: Icon(Icons.search, color: _theme.accent),
                          suffixIcon: _busy
                              ? Padding(
                                  padding: const EdgeInsets.all(14),
                                  child: SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: _theme.accent,
                                    ),
                                  ),
                                )
                              : IconButton(
                                  icon: Icon(Icons.arrow_forward, color: _theme.accent),
                                  onPressed: _searchDestination,
                                ),
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 16,
                          ),
                        ),
                      ),
                    ),
                    if (_gpsIssue != null) ...[
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.center,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: _theme.panel,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 7,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.gps_off,
                                  size: 16,
                                  color: _theme.accent,
                                ),
                                const SizedBox(width: 8),
                                Text(_gpsIssue!),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                    if (_rerouting) ...[
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.center,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: _theme.panel,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 7,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: _theme.accent,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                const Text('Recalculating…'),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                    if (_routeOptions.length > 1) ...[
                      const SizedBox(height: 8),
                      _routeAlternatives(),
                    ],
                    if (_route != null) ...[
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: _navigationSummary(),
                      ),
                    ],
                    if (_nextTrafficSignal != null &&
                        _distanceToNextTrafficSignal != null &&
                        _distanceToNextTrafficSignal! <= 320) ...[
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.center,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: _theme.panel,
                            borderRadius: BorderRadius.circular(15),
                            border: Border.all(
                              color: const Color(0x99F5B642),
                              width: 1.2,
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.traffic,
                                  color: Color(0xFFF5B642),
                                  size: 20,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  'Traffic light • ${_distanceToNextTrafficSignal!.round()} m',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                if (_nextTrafficSignal!.remainingSeconds != null) ...[
                                  const SizedBox(width: 8),
                                  Text(
                                    '${_nextTrafficSignal!.remainingSeconds} sec',
                                    style: TextStyle(
                                      color: _theme.accent,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                    const Spacer(),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Column(
                          children: [
                            FloatingActionButton.small(
                              heroTag: 'progress',
                              backgroundColor: _theme.panel,
                              foregroundColor: _theme.accent,
                              onPressed: _showProgressSheet,
                              child: Stack(
                                clipBehavior: Clip.none,
                                children: [
                                  Icon(_selectedReward.icon),
                                  if (_xp > 0)
                                    Positioned(
                                      right: -8,
                                      top: -8,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 5,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: _theme.accent,
                                          borderRadius: BorderRadius.circular(10),
                                        ),
                                        child: Text(
                                          '$_xp',
                                          style: const TextStyle(
                                            color: Colors.black,
                                            fontSize: 8,
                                            fontWeight: FontWeight.w900,
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 10),
                            FloatingActionButton.small(
                              heroTag: 'themes',
                              backgroundColor: _theme.panel,
                              foregroundColor: _theme.accent,
                              onPressed: _showThemeSheet,
                              child: const Icon(Icons.palette),
                            ),
                            const SizedBox(height: 10),
                            FloatingActionButton.small(
                              heroTag: 'avoid',
                              backgroundColor: _theme.panel,
                              foregroundColor: _theme.accent,
                              onPressed: _showAvoidanceSheet,
                              child: const Icon(Icons.tune),
                            ),
                            const SizedBox(height: 10),
                            FloatingActionButton.small(
                              heroTag: 'follow',
                              backgroundColor: _theme.panel,
                              foregroundColor: _theme.accent,
                              onPressed: () {
                                setState(() => _following = true);
                                if (_lastPosition != null) {
                                  _onPosition(_lastPosition!);
                                }
                              },
                              child: const Icon(Icons.my_location),
                            ),
                          ],
                        ),
                        const Spacer(),
                        FloatingActionButton.extended(
                          heroTag: 'report',
                          backgroundColor: _theme.accent,
                          foregroundColor: Colors.black,
                          onPressed: _showReportSheet,
                          icon: const Icon(Icons.campaign),
                          label: const Text(
                            'Report',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
