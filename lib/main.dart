import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:maplibre_gl/maplibre_gl.dart';

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

  const SearchResult(this.name, this.lat, this.lon);
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

class OpenMapServices {
  static const _userAgent = 'GameNav-MVP/0.3 contact@example.invalid';

  static Future<List<SearchResult>> search(String query) async {
    final uri = Uri.https(
      'nominatim.openstreetmap.org',
      '/search',
      {
        'q': query,
        'format': 'jsonv2',
        'limit': '5',
        'countrycodes': 'il',
      },
    );

    final response = await http.get(
      uri,
      headers: {'User-Agent': _userAgent},
    );

    if (response.statusCode != 200) {
      throw Exception('Search failed');
    }

    final data = jsonDecode(response.body) as List<dynamic>;

    return data.map((e) {
      final m = e as Map<String, dynamic>;

      return SearchResult(
        m['display_name']?.toString() ?? 'יעד',
        double.parse(m['lat'].toString()),
        double.parse(m['lon'].toString()),
      );
    }).toList();
  }

  static Future<RouteResult> route(
    LatLng from,
    LatLng to,
  ) async {
    final path =
        '/route/v1/driving/${from.longitude},${from.latitude};${to.longitude},${to.latitude}';

    final uri = Uri.https(
      'router.project-osrm.org',
      path,
      {
        'overview': 'full',
        'geometries': 'geojson',
        'alternatives': 'true',
        'steps': 'true',
      },
    );

    final response = await http.get(uri);

    if (response.statusCode != 200) {
      throw Exception('Routing failed');
    }

    final data =
        jsonDecode(response.body) as Map<String, dynamic>;

    final routes =
        (data['routes'] as List<dynamic>? ?? const []);

    if (routes.isEmpty) {
      throw Exception('No route');
    }

    final route =
        routes.first as Map<String, dynamic>;

    final coordinates =
        ((route['geometry'] as Map<String, dynamic>)['coordinates']
            as List<dynamic>);

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
  }
}

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  static const _demoStyle =
      'https://demotiles.maplibre.org/style.json';

  final _searchController = TextEditingController();

  MapLibreMapController? _map;
  StreamSubscription<Position>? _positionSub;

  Symbol? _vehicle;
  Line? _routeLine;

  Position? _lastPosition;
  SearchResult? _destination;
  RouteResult? _route;

  bool _styleReady = false;
  bool _following = true;
  bool _busy = false;

  String _status = 'מאתר GPS…';

  bool avoidTraffic = true;
  bool avoidClosures = true;
  bool avoidTolls = false;
  bool avoidUnpaved = false;

  @override
  void initState() {
    super.initState();
    _startLocation();
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _startLocation() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      if (mounted) {
        setState(() => _status = 'יש להפעיל שירותי מיקום');
      }
      return;
    }

    var permission =
        await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      permission =
          await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      if (mounted) {
        setState(() => _status = 'אין הרשאת GPS');
      }
      return;
    }

    const settings = LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 3,
    );

    _positionSub =
        Geolocator.getPositionStream(
      locationSettings: settings,
    ).listen(_onPosition);

    try {
      await _onPosition(
        await Geolocator.getCurrentPosition(
          locationSettings: settings,
        ),
      );
    } catch (_) {}
  }

  Future<void> _onPosition(Position p) async {
    _lastPosition = p;

    if (mounted) {
      final kmh =
          (p.speed.isFinite ? p.speed : 0) * 3.6;

      setState(() {
        _status =
            '${kmh.clamp(0, 999).toStringAsFixed(0)} קמ״ש  •  ±${p.accuracy.toStringAsFixed(0)} מ׳';
      });
    }

    final map = _map;

    if (map == null || !_styleReady) {
      return;
    }

    final point =
        LatLng(p.latitude, p.longitude);

    final heading =
        p.heading.isFinite && p.heading >= 0
            ? p.heading
            : 0.0;

    if (_vehicle == null) {
      _vehicle = await map.addSymbol(
        SymbolOptions(
          geometry: point,
          iconImage: 'vehicle-marker',
          iconSize: 0.48,
          iconRotate: heading,
          iconAnchor: 'center',
        ),
      );
    } else {
      await map.updateSymbol(
        _vehicle!,
        SymbolOptions(
          geometry: point,
          iconRotate: heading,
        ),
      );
    }

    if (_following) {
      await map.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(
            target: point,
            zoom: 17,
            bearing: heading,
            tilt: 45,
          ),
        ),
      );
    }
  }

  Future<void> _onStyleLoaded() async {
    _styleReady = true;

    final bytes =
        await rootBundle.load(
      'assets/icons/vehicle.png',
    );

    await _map?.addImage(
      'vehicle-marker',
      Uint8List.view(bytes.buffer),
    );

    if (_lastPosition != null) {
      await _onPosition(_lastPosition!);
    }
  }

  Future<void> _searchDestination() async {
    final query =
        _searchController.text.trim();

    if (query.isEmpty) return;

    setState(() => _busy = true);

    try {
      final results =
          await OpenMapServices.search(query);

      if (!mounted) return;

      if (results.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('לא נמצא יעד'),
          ),
        );
        return;
      }

      final chosen =
          await showModalBottomSheet<SearchResult>(
        context: context,
        builder: (context) => Directionality(
          textDirection: TextDirection.rtl,
          child: SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: [
                const ListTile(
                  title: Text(
                    'בחר יעד',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                ...results.map(
                  (r) => ListTile(
                    leading:
                        const Icon(Icons.place),
                    title: Text(
                      r.name,
                      maxLines: 2,
                      overflow:
                          TextOverflow.ellipsis,
                    ),
                    onTap: () =>
                        Navigator.pop(context, r),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      if (chosen != null) {
        await _buildRoute(chosen);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(
          const SnackBar(
            content:
                Text('שגיאה בחיפוש היעד'),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _buildRoute(
    SearchResult destination,
  ) async {
    final p = _lastPosition;
    final map = _map;

    if (p == null ||
        map == null ||
        !_styleReady) {
      ScaffoldMessenger.of(context)
          .showSnackBar(
        const SnackBar(
          content:
              Text('עדיין אין מיקום GPS'),
        ),
      );
      return;
    }

    setState(() => _busy = true);

    try {
      final result =
          await OpenMapServices.route(
        LatLng(p.latitude, p.longitude),
        LatLng(
          destination.lat,
          destination.lon,
        ),
      );

      if (_routeLine != null) {
        await map.removeLine(_routeLine!);
      }

      _routeLine = await map.addLine(
        LineOptions(
          geometry: result.geometry,
          lineColor: '#D946EF',
          lineWidth: 7,
          lineOpacity: 0.92,
          lineJoin: 'round',
        ),
      );

      setState(() {
        _destination = destination;
        _route = result;
        _following = false;
      });

      await map.animateCamera(
        CameraUpdate.newLatLngBounds(
          LatLngBounds(
            southwest: LatLng(
              result.geometry
                  .map((e) => e.latitude)
                  .reduce(
                    (a, b) => a < b ? a : b,
                  ),
              result.geometry
                  .map((e) => e.longitude)
                  .reduce(
                    (a, b) => a < b ? a : b,
                  ),
            ),
            northeast: LatLng(
              result.geometry
                  .map((e) => e.latitude)
                  .reduce(
                    (a, b) => a > b ? a : b,
                  ),
              result.geometry
                  .map((e) => e.longitude)
                  .reduce(
                    (a, b) => a > b ? a : b,
                  ),
            ),
          ),
          left: 50,
          top: 150,
          right: 50,
          bottom: 180,
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(
          const SnackBar(
            content: Text(
              'לא ניתן לחשב מסלול כרגע',
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  void _showReportSheet() {
    const reports = <(IconData, String)>[
      (Icons.traffic, 'פקק'),
      (Icons.block, 'חסימת כביש'),
      (Icons.car_crash, 'תאונה'),
      (Icons.construction, 'עבודות בדרך'),
      (
        Icons.warning_amber_rounded,
        'מפגע בכביש',
      ),
    ];

    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (context) => Directionality(
        textDirection: TextDirection.rtl,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment:
                  CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'דיווח בדרך',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: reports
                      .map(
                        (r) => ActionChip(
                          avatar: Icon(
                            r.$1,
                            size: 20,
                          ),
                          label: Text(r.$2),
                          onPressed: () {
                            Navigator.pop(context);

                            ScaffoldMessenger.of(
                              context,
                            ).showSnackBar(
                              SnackBar(
                                content: Text(
                                  'דיווח ${r.$2} נשמר מקומית בגרסת ה-MVP',
                                ),
                              ),
                            );
                          },
                        ),
                      )
                      .toList(),
                ),
                const SizedBox(height: 12),
                const Text(
                  'בגרסה עם השרת הדיווחים יאומתו ויופצו לנהגים אחרים באזור.',
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
      builder: (context) =>
          StatefulBuilder(
        builder:
            (context, modalSetState) =>
                Directionality(
          textDirection: TextDirection.rtl,
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const ListTile(
                  title: Text(
                    'הימנעות',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight:
                          FontWeight.bold,
                    ),
                  ),
                ),
                _avoidSwitch(
                  'הימנע מפקקים',
                  'יופעל מול מנוע תנועה שתומך בזמן אמת',
                  avoidTraffic,
                  (v) {
                    modalSetState(
                      () => avoidTraffic = v,
                    );
                    setState(
                      () => avoidTraffic = v,
                    );
                  },
                ),
                _avoidSwitch(
                  'הימנע מחסימות',
                  'ישוקלל מדיווחי GameNav ו-feeds מורשים',
                  avoidClosures,
                  (v) {
                    modalSetState(
                      () => avoidClosures = v,
                    );
                    setState(
                      () => avoidClosures = v,
                    );
                  },
                ),
                _avoidSwitch(
                  'הימנע מכבישי אגרה',
                  null,
                  avoidTolls,
                  (v) {
                    modalSetState(
                      () => avoidTolls = v,
                    );
                    setState(
                      () => avoidTolls = v,
                    );
                  },
                ),
                _avoidSwitch(
                  'הימנע מכבישים לא סלולים',
                  null,
                  avoidUnpaved,
                  (v) {
                    modalSetState(
                      () => avoidUnpaved = v,
                    );
                    setState(
                      () => avoidUnpaved = v,
                    );
                  },
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(
                    20,
                    8,
                    20,
                    20,
                  ),
                  child: Text(
                    'ה-MVP מציג את ההעדפות. ניתוב מתקדם לפי פקקים וחסימות יופעל כאשר backend התנועה יחובר.',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _avoidSwitch(
    String title,
    String? subtitle,
    bool value,
    ValueChanged<bool> onChanged,
  ) =>
      SwitchListTile(
        title: Text(title),
        subtitle:
            subtitle == null
                ? null
                : Text(subtitle),
        value: value,
        onChanged: onChanged,
      );

  String get _routeSummary {
    final r = _route;

    if (r == null) return '';

    final km =
        r.distanceMeters / 1000;

    final min =
        (r.durationSeconds / 60).round();

    return '${km.toStringAsFixed(1)} ק״מ • $min דקות';
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        body: Stack(
          children: [
            MapLibreMap(
              styleString: _demoStyle,
              initialCameraPosition:
                  const CameraPosition(
                target:
                    LatLng(31.9, 34.8),
                zoom: 9,
              ),
              onMapCreated:
                  (c) => _map = c,
              onStyleLoadedCallback:
                  _onStyleLoaded,
              onCameraMove: (_) =>
                  _following = false,
            ),

            SafeArea(
              child: Padding(
                padding:
                    const EdgeInsets.all(12),
                child: Column(
                  children: [
                    Material(
                      elevation: 8,
                      borderRadius:
                          BorderRadius.circular(
                        18,
                      ),
                      child: TextField(
                        controller:
                            _searchController,
                        textInputAction:
                            TextInputAction
                                .search,
                        onSubmitted: (_) =>
                            _searchDestination(),
                        decoration:
                            InputDecoration(
                          hintText:
                              'לאן נוסעים?',
                          prefixIcon:
                              const Icon(
                            Icons.search,
                          ),
                          suffixIcon:
                              _busy
                                  ? const Padding(
                                      padding:
                                          EdgeInsets.all(
                                        14,
                                      ),
                                      child:
                                          SizedBox(
                                        width: 18,
                                        height: 18,
                                        child:
                                            CircularProgressIndicator(
                                          strokeWidth:
                                              2,
                                        ),
                                      ),
                                    )
                                  : IconButton(
                                      icon:
                                          const Icon(
                                        Icons
                                            .arrow_back,
                                      ),
                                      onPressed:
                                          _searchDestination,
                                    ),
                          border:
                              InputBorder.none,
                          contentPadding:
                              const EdgeInsets
                                  .symmetric(
                            horizontal: 16,
                            vertical: 16,
                          ),
                        ),
                      ),
                    ),

                    if (_destination != null) ...[
                      const SizedBox(height: 8),
                      Card(
                        child: ListTile(
                          leading:
                              const Icon(
                            Icons.navigation,
                          ),
                          title: Text(
                            _destination!.name,
                            maxLines: 1,
                            overflow:
                                TextOverflow
                                    .ellipsis,
                          ),
                          subtitle:
                              Text(
                            _routeSummary,
                          ),
                        ),
                      ),
                    ],

                    const Spacer(),

                    Row(
                      crossAxisAlignment:
                          CrossAxisAlignment.end,
                      children: [
                        Column(
                          children: [
                            FloatingActionButton
                                .small(
                              heroTag:
                                  'avoid',
                              onPressed:
                                  _showAvoidanceSheet,
                              child:
                                  const Icon(
                                Icons.tune,
                              ),
                            ),
                            const SizedBox(
                              height: 10,
                            ),
                            FloatingActionButton
                                .small(
                              heroTag:
                                  'follow',
                              onPressed: () {
                                setState(
                                  () =>
                                      _following =
                                          true,
                                );

                                if (_lastPosition !=
                                    null) {
                                  _onPosition(
                                    _lastPosition!,
                                  );
                                }
                              },
                              child:
                                  const Icon(
                                Icons
                                    .my_location,
                              ),
                            ),
                          ],
                        ),

                        const Spacer(),

                        FloatingActionButton
                            .extended(
                          heroTag: 'report',
                          onPressed:
                              _showReportSheet,
                          icon: const Icon(
                            Icons.add_alert,
                          ),
                          label:
                              const Text(
                            'דיווח',
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 10),

                    Card(
                      child: Padding(
                        padding:
                            const EdgeInsets
                                .symmetric(
                          horizontal: 14,
                          vertical: 8,
                        ),
                        child: Text(_status),
                      ),
                    ),
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
