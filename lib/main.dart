import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

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
    tagline: 'עיר פתוחה • בהשראת משחקי פשע אורבניים',
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
    tagline: 'מערב פרוע • בהשראת משחקי Frontier',
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
    tagline: 'לילה • ניאון • שנות ה־80',
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
    tagline: 'עתידני • HUD דיגיטלי',
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
    tagline: 'נהיגה לילית • מינימליסטי',
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
    tagline: 'מפה בהירה וברורה',
    mapStyle: 'https://tiles.openfreemap.org/styles/positron',
    accent: Color(0xFF3F72FF),
    panel: Color(0xEE10131A),
    foreground: Colors.white,
    routeColor: '#3F72FF',
    icon: Icons.map,
  ),
];

class CommunityReport {
  final String type;
  final DateTime createdAt;

  CommunityReport(this.type) : createdAt = DateTime.now();
}

class OpenMapServices {
  static const _userAgent =
      'GameNav/0.4.7 (https://github.com/MrDauss/GameNav)';

  static Future<List<SearchResult>> search(
    String query, {
    Position? bias,
  }) async {
    Object? photonError;

    try {
      final params = <String, String>{
        'q': query,
        'limit': '7',
        'lang': 'he',
        'countrycode': 'IL',
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
              'Accept-Language': 'he,en;q=0.8',
            },
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body) as Map<String, dynamic>;
        final features = decoded['features'] as List<dynamic>? ?? const [];
        final results = <SearchResult>[];

        for (final raw in features) {
          final feature = raw as Map<String, dynamic>;
          final geometry = feature['geometry'] as Map<String, dynamic>?;
          final properties = feature['properties'] as Map<String, dynamic>?;
          final coordinates = geometry?['coordinates'] as List<dynamic>?;
          if (coordinates == null || coordinates.length < 2) continue;

          final lon = (coordinates[0] as num).toDouble();
          final lat = (coordinates[1] as num).toDouble();
          final props = properties ?? const <String, dynamic>{};
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
        'countrycodes': 'il',
        'accept-language': 'he,en',
      });

      final response = await http
          .get(
            uri,
            headers: {
              'User-Agent': _userAgent,
              'Accept': 'application/json',
              'Accept-Language': 'he,en;q=0.8',
            },
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        throw Exception('Nominatim HTTP ${response.statusCode}');
      }

      final data = jsonDecode(response.body) as List<dynamic>;
      final results = data.map((e) {
        final m = e as Map<String, dynamic>;
        final displayName = m['display_name']?.toString() ?? 'יעד';
        final label = _shortNominatimLabel(displayName);
        return SearchResult(
          label.$1,
          double.parse(m['lat'].toString()),
          double.parse(m['lon'].toString()),
          subtitle: label.$2,
        );
      }).toList();

      if (results.isNotEmpty) return results;
    } catch (e) {
      throw Exception('Search providers failed: $photonError / $e');
    }

    return const [];
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
    return 'יעד';
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
    if (parts.isEmpty) return ('יעד', null);
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

    return RoadSnapResult(
      LatLng(
        (location[1] as num).toDouble(),
        (location[0] as num).toDouble(),
      ),
      (waypoint['distance'] as num?)?.toDouble() ?? 0,
    );
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
      'steps': 'true',
    });

    final response = await http
        .get(uri, headers: {'User-Agent': _userAgent})
        .timeout(const Duration(seconds: 15));

    if (response.statusCode != 200) {
      throw Exception('Routing HTTP ${response.statusCode}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final routes = data['routes'] as List<dynamic>? ?? const [];
    if (routes.isEmpty) throw Exception('No route');

    return routes.map((raw) {
      final route = raw as Map<String, dynamic>;
      final geometry = route['geometry'] as Map<String, dynamic>;
      final coordinates = geometry['coordinates'] as List<dynamic>;
      final points = coordinates.map((c) {
        final p = c as List<dynamic>;
        return LatLng(
          (p[1] as num).toDouble(),
          (p[0] as num).toDouble(),
        );
      }).toList();

      return RouteResult(
        points,
        (route['distance'] as num).toDouble(),
        (route['duration'] as num).toDouble(),
      );
    }).toList();
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
    unawaited(WakelockPlus.enable());
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
    // Keep the display awake whenever the navigation Activity is active.
    // Android also receives FLAG_KEEP_SCREEN_ON in MainActivity as a native
    // fallback, so a transient lifecycle event cannot switch the screen off.
    if (state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive) {
      unawaited(WakelockPlus.enable());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _positionSub?.cancel();
    _compassSub?.cancel();
    _renderTimer?.cancel();
    unawaited(WakelockPlus.disable());
    _searchController.dispose();
    super.dispose();
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
      if (mounted) setState(() => _gpsIssue = 'יש להפעיל שירותי מיקום');
      return;
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      if (mounted) setState(() => _gpsIssue = 'אין הרשאת GPS');
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
    _targetHeading = _preferredHeading(p);

    // STRICT ROAD LOCK. The raw GPS point is never drawn. During navigation
    // use the route geometry as the primary map-matching surface. If that
    // cannot produce a plausible point, keep the last confirmed road point
    // while a fresh nearest-road match is requested.
    LatLng? displayPoint;
    final route = _route;
    if (route != null && route.geometry.isNotEmpty) {
      final nearest = _nearestPointOnGeometry(rawPoint, route.geometry);
      final maxSnapDistance = math.max(90.0, p.accuracy * 2.8);
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
        now.difference(lastAt) < const Duration(milliseconds: 800) &&
        lastPoint != null &&
        Geolocator.distanceBetween(
              rawPoint.latitude,
              rawPoint.longitude,
              lastPoint.latitude,
              lastPoint.longitude,
            ) <
            4) {
      return;
    }

    _roadSnapBusy = true;
    _lastRoadSnapAt = now;
    _lastRoadSnapRequestPoint = rawPoint;
    try {
      final snapped = await OpenMapServices.nearestRoad(rawPoint);
      if (snapped == null) return;

      // Strict road lock prefers a confirmed drivable road over raw GPS.
      // Reject only clearly implausible matches; for normal residential GPS
      // drift this still allows the marker to snap out of a building and onto
      // the nearest road.
      if (snapped.distanceMeters > 750) return;
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

  double? _routeCameraHeading(LatLng point) {
    final route = _route;
    if (route == null || route.geometry.length < 2) return null;

    final nearest = _nearestPointOnGeometry(point, route.geometry);
    // Do not force the old route direction when the car is genuinely far from
    // it (for example during a reroute).
    if (nearest.$2 > 55) return null;

    final geometry = route.geometry;
    final index = _nearestRouteVertexIndex(point, geometry);
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
        duration: const Duration(milliseconds: 170),
        interpolation: CameraAnimationInterpolation.linear,
      );
    } finally {
      await Future<void>.delayed(const Duration(milliseconds: 35));
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
      await _redrawRoute();

      // Return immediately to navigation view instead of showing another
      // high route overview every time the driver misses a turn.
      if (_lastPosition != null) {
        await _onPosition(_lastPosition!);
      }
      _message('המסלול עודכן לפי המיקום החדש');
    } catch (_) {
      // Keep the old route on screen and retry after new GPS samples.
      _message('לא הצלחתי לחשב מסלול מחדש כרגע');
    } finally {
      if (mounted) {
        setState(() => _rerouting = false);
      } else {
        _rerouting = false;
      }
    }
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
        _message('לא נמצא יעד. נסה להוסיף עיר או רחוב.');
        return;
      }

      final chosen = await showModalBottomSheet<SearchResult>(
        context: context,
        showDragHandle: true,
        backgroundColor: _theme.panel,
        builder: (context) => Directionality(
          textDirection: TextDirection.rtl,
          child: SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: [
                ListTile(
                  leading: Icon(Icons.search, color: _theme.accent),
                  title: const Text(
                    'תוצאות חיפוש',
                    style: TextStyle(fontWeight: FontWeight.bold),
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
                          '${(r.distanceMeters! / 1000).toStringAsFixed(1)} ק״מ',
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
                                '${(r.durationSeconds! / 60).round()} דק׳',
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
      _message('שירות החיפוש לא הגיב בזמן. נסה שוב.');
    } catch (_) {
      _message('לא ניתן להתחבר לשירות החיפוש כרגע.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _buildRoutes(SearchResult destination) async {
    final p = _lastPosition;
    final map = _map;
    if (p == null || map == null || !_styleReady) {
      _message('עדיין אין מיקום GPS מדויק.');
      return;
    }

    setState(() => _busy = true);

    try {
      final routes = await OpenMapServices.routes(
        LatLng(p.latitude, p.longitude),
        LatLng(destination.lat, destination.lon),
      );

      setState(() {
        _destination = destination;
        _routeOptions = routes;
        _selectedRouteIndex = 0;
        _following = false;
        _offRouteSamples = 0;
      });
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
      _message('חישוב המסלול ארך יותר מדי זמן. נסה שוב.');
    } catch (_) {
      _message('לא ניתן לחשב מסלול כרגע.');
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
          textDirection: TextDirection.rtl,
          child: SafeArea(
            child: ListView(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 24),
              children: [
                const Text(
                  'Game Themes',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 4),
                const Text(
                  'גלול למעלה ולמטה ובחר את עולם המשחק של הניווט.',
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
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      subtitle: Text(theme.tagline),
                      trailing: theme.id == _theme.id
                          ? Icon(Icons.check_circle, color: theme.accent)
                          : const Icon(Icons.chevron_left),
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
      (Icons.traffic, 'פקק'),
      (Icons.block, 'חסימת כביש'),
      (Icons.car_crash, 'תאונה'),
      (Icons.construction, 'עבודות בדרך'),
      (Icons.warning_amber_rounded, 'מפגע בכביש'),
      (Icons.car_repair, 'רכב תקוע'),
      (Icons.water, 'הצפה'),
      (Icons.traffic_outlined, 'רמזור תקול'),
      (Icons.shield_outlined, 'פעילות אכיפה באזור'),
    ];

    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: _theme.panel,
      builder: (context) => Directionality(
        textDirection: TextDirection.rtl,
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
                    const Text(
                      'דיווח בדרך',
                      style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
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
                            setState(() => _reports.add(CommunityReport(r.$2)));
                            Navigator.pop(context);
                            _message('דיווח “${r.$2}” נשמר בגרסת הניסוי.');
                          },
                        ),
                      )
                      .toList(),
                ),
                const SizedBox(height: 14),
                Text(
                  'דיווחים שנוספו במכשיר: ${_reports.length}. בגרסת השרת נוסיף אימות “עדיין שם / כבר לא”, תפוגה אוטומטית וניקוד אמינות.',
                ),
              ],
            ),
          ),
        ),
      ),
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
          textDirection: TextDirection.rtl,
          child: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    leading: Icon(Icons.alt_route, color: _theme.accent),
                    title: const Text(
                      'הימנעות והעדפות מסלול',
                      style: TextStyle(fontSize: 21, fontWeight: FontWeight.bold),
                    ),
                    subtitle: const Text(
                      'ההעדפות נשמרות באפליקציה; שילוב מלא בחישוב המסלול יגיע עם מנוע GameNav backend.',
                    ),
                  ),
                  _avoidSwitch('הימנע מפקקים', avoidTraffic, (v) {
                    modalSetState(() => avoidTraffic = v);
                    setState(() => avoidTraffic = v);
                  }),
                  _avoidSwitch('הימנע מחסימות', avoidClosures, (v) {
                    modalSetState(() => avoidClosures = v);
                    setState(() => avoidClosures = v);
                  }),
                  _avoidSwitch('הימנע מעבודות בדרך', avoidRoadworks, (v) {
                    modalSetState(() => avoidRoadworks = v);
                    setState(() => avoidRoadworks = v);
                  }),
                  _avoidSwitch('הימנע ממפגעים', avoidHazards, (v) {
                    modalSetState(() => avoidHazards = v);
                    setState(() => avoidHazards = v);
                  }),
                  _avoidSwitch('הימנע מכבישי אגרה', avoidTolls, (v) {
                    modalSetState(() => avoidTolls = v);
                    setState(() => avoidTolls = v);
                  }),
                  _avoidSwitch('הימנע מכבישים לא סלולים', avoidUnpaved, (v) {
                    modalSetState(() => avoidUnpaved = v);
                    setState(() => avoidUnpaved = v);
                  }),
                  const Divider(),
                  _avoidSwitch('העדף כבישים ראשיים', preferMainRoads, (v) {
                    modalSetState(() => preferMainRoads = v);
                    setState(() => preferMainRoads = v);
                  }),
                  _avoidSwitch('העדף מסלול רגוע', preferQuietRoads, (v) {
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
    return 'הגעה $hour:$minute';
  }

  String _routeSummary(RouteResult route) {
    final min = (route.durationSeconds / 60).round();
    return '$min דק׳ • ${_arrivalTime(route.durationSeconds)}';
  }

  Widget _navigationSummary() {
    final route = _route;
    if (route == null) return const SizedBox.shrink();
    final km = route.distanceMeters / 1000;
    final min = (route.durationSeconds / 60).round();

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
              '$min דק׳',
              style: TextStyle(
                color: _theme.accent,
                fontSize: 17,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(width: 9),
            Text(
              _arrivalTime(route.durationSeconds),
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${km.toStringAsFixed(1)} ק״מ',
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
              label: Text('דרך ${index + 1} • ${_routeSummary(_routeOptions[index])}'),
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
      textDirection: TextDirection.rtl,
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
                onMapCreated: (c) => _map = c,
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
                          hintText: 'לאן נוסעים?',
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
                                  icon: Icon(Icons.arrow_back, color: _theme.accent),
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
                                const Text('מחשב מסלול מחדש…'),
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
                                  'רמזור • ${_distanceToNextTrafficSignal!.round()} מ׳',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                if (_nextTrafficSignal!.remainingSeconds != null) ...[
                                  const SizedBox(width: 8),
                                  Text(
                                    '${_nextTrafficSignal!.remainingSeconds} שנ׳',
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
                            'דיווח',
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
