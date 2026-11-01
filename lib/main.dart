import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:onesignal_flutter/onesignal_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

const Color kBrand = Color(0xFF2C348F);
const String kLogoUrl =
    'https://najemstarcall.com/wp-content/uploads/2026/04/StarCall-Logo-1-450x150-2-1.webp';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
    statusBarBrightness: Brightness.light,
  ));
  runApp(const NajemApp());
}

class NajemApp extends StatelessWidget {
  const NajemApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Najem Starcall',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.amber,
        scaffoldBackgroundColor: Colors.white,
      ),
      home: const MainWebViewScreen(),
    );
  }
}

/// Logo 400x150 (scales down automatically on narrow screens).
class AppLogo extends StatelessWidget {
  const AppLogo({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: SizedBox(
        width: 400,
        height: 150,
        child: Image.network(
          kLogoUrl,
          width: 400,
          height: 150,
          fit: BoxFit.contain,
          gaplessPlayback: true,
          loadingBuilder: (context, child, progress) =>
              progress == null ? child : const SizedBox(width: 400, height: 150),
          errorBuilder: (context, error, stack) => const Center(
            child: Text(
              "Najem Starcall",
              style: TextStyle(
                color: kBrand,
                fontSize: 26,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class MainWebViewScreen extends StatefulWidget {
  const MainWebViewScreen({Key? key}) : super(key: key);

  @override
  State<MainWebViewScreen> createState() => _MainWebViewScreenState();
}

class _MainWebViewScreenState extends State<MainWebViewScreen>
    with WidgetsBindingObserver {
  // Bottom bar tabs: 0 Home, 1 Shop, 2 Alerts (sheet), 3 Account
  // WebView slots:   0 Home, 1 Shop, 2 Account
  static const List<int> _tabToWeb = [0, 1, -1, 2];

  final List<String> _urls = const [
    "https://najemstarcall.com/",
    "https://najemstarcall.com/shop",
    "https://najemstarcall.com/my-account",
  ];

  final List<InAppWebViewController?> _controllers = [null, null, null];
  final List<bool> _loaded = [false, false, false]; // first paint done
  final List<bool> _loading = [false, false, false]; // a navigation is running
  final List<double> _progress = [0, 0, 0];
  final List<bool> _error = [false, false, false]; // main frame failed
  final List<String?> _failedUrl = [null, null, null];
  final List<Timer?> _loadingTimers = [null, null, null];
  final List<DateTime> _lastLeft = [
    DateTime.now(),
    DateTime.now(),
    DateTime.now()
  ];
  late final List<PullToRefreshController> _refreshControllers;

  int _currentTabIndex = 0;
  bool _preloadOthers = false; // Shop + Account load after Home is ready
  bool _splashVisible = true;
  bool _offline = false;
  Timer? _splashTimeout;
  StreamSubscription<List<ConnectivityResult>>? _connSub;

  String? _pendingDeepLink;
  List<Map<String, String>> _notificationHistory = [];

  int get _currentWeb => _tabToWeb[_currentTabIndex];

  final UserScript _appStyleScript = UserScript(
    source: """
      (function() {
        if (document.getElementById('najem-app-style')) return;
        var s = document.createElement('style');
        s.id = 'najem-app-style';
        s.innerHTML = '* { -webkit-tap-highlight-color: transparent; } ' +
          'html, body { overscroll-behavior-y: contain; } ' +
          'body { padding-bottom: 100px !important; }';
        (document.head || document.documentElement).appendChild(s);
      })();
    """,
    injectionTime: UserScriptInjectionTime.AT_DOCUMENT_END,
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _refreshControllers = List.generate(3, (i) {
      return PullToRefreshController(
        settings: PullToRefreshSettings(color: kBrand),
        onRefresh: () async {
          final c = _controllers[i];
          if (c == null) return;
          final url = await c.getUrl();
          if (url != null) {
            await c.loadUrl(urlRequest: URLRequest(url: url));
          } else {
            await c.reload();
          }
        },
      );
    });

    _loadNotificationHistory();
    _initOneSignal();
    _initConnectivity();

    // Never leave the user stuck on the splash screen
    _splashTimeout = Timer(const Duration(seconds: 8), _hideSplash);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _splashTimeout?.cancel();
    _connSub?.cancel();
    for (final t in _loadingTimers) {
      t?.cancel();
    }
    super.dispose();
  }

  // When the app comes back to the foreground, re-check the connection and
  // recover pages that failed while the app was in the background.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkConnectivityNow();
    }
  }

  void _hideSplash() {
    if (!mounted || !_splashVisible) return;
    setState(() {
      _splashVisible = false;
      _preloadOthers = true;
    });
  }

  // ---------------------------------------------------------------------------
  // Connectivity
  // ---------------------------------------------------------------------------
  Future<void> _initConnectivity() async {
    await _checkConnectivityNow();
    _connSub = Connectivity().onConnectivityChanged.listen((results) {
      _applyConnectivity(results);
    });
  }

  Future<void> _checkConnectivityNow() async {
    final results = await Connectivity().checkConnectivity();
    _applyConnectivity(results);
  }

  void _applyConnectivity(List<ConnectivityResult> results) {
    final offline =
        results.isEmpty || results.every((r) => r == ConnectivityResult.none);
    if (!mounted) return;

    final cameBack = _offline && !offline;
    setState(() => _offline = offline);

    // Connection is back: automatically retry every page that failed
    if (cameBack) {
      for (int i = 0; i < 3; i++) {
        if (_error[i] || !_loaded[i]) _retry(i);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Loading state helpers
  // ---------------------------------------------------------------------------
  void _startLoading(int web) {
    _loadingTimers[web]?.cancel();
    // Safety net: never keep the overlay forever
    _loadingTimers[web] = Timer(const Duration(seconds: 12), () {
      if (mounted && _loading[web]) setState(() => _loading[web] = false);
    });
    if (mounted) {
      setState(() {
        _loading[web] = true;
        _progress[web] = 0.05;
        _error[web] = false;
      });
    }
  }

  void _stopLoading(int web) {
    _loadingTimers[web]?.cancel();
    _refreshControllers[web].endRefreshing();
    if (mounted) {
      setState(() {
        _loading[web] = false;
        _progress[web] = 1;
        if (!_error[web]) _loaded[web] = true;
      });
    }
  }

  Future<void> _retry(int web) async {
    final c = _controllers[web];
    if (c == null) return;
    _startLoading(web);
    final target = _failedUrl[web] ?? _urls[web];
    await c.loadUrl(urlRequest: URLRequest(url: WebUri(target)));
  }

  // ---------------------------------------------------------------------------
  // Persistent Storage for Notification History
  // ---------------------------------------------------------------------------
  Future<void> _loadNotificationHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final List<String>? storedHistory =
        prefs.getStringList('notification_history');
    if (storedHistory != null && mounted) {
      setState(() {
        _notificationHistory = storedHistory
            .map((item) => Map<String, String>.from(jsonDecode(item)))
            .toList();
      });
    }
  }

  Future<void> _saveNotificationToHistory(
      String title, String body, String imageUrl, String launchUrl) async {
    final prefs = await SharedPreferences.getInstance();
    final newEntry = {
      'title': title,
      'body': body,
      'image': imageUrl,
      'url': launchUrl,
      'time': DateTime.now().toString().substring(11, 16),
    };

    if (mounted) {
      setState(() {
        _notificationHistory.insert(0, newEntry);
      });
    } else {
      _notificationHistory.insert(0, newEntry);
    }

    final List<String> encodedList =
        _notificationHistory.map((item) => jsonEncode(item)).toList();
    await prefs.setStringList('notification_history', encodedList);
  }

  // ---------------------------------------------------------------------------
  // OneSignal
  // ---------------------------------------------------------------------------
  void _initOneSignal() {
    OneSignal.initialize("b8a319d1-1f12-473f-b555-cc237a551f20");
    OneSignal.Notifications.requestPermission(true);

    OneSignal.Notifications.addForegroundWillDisplayListener((event) {
      final notification = event.notification;
      final imageUrl = notification.bigPicture ?? '';
      final launchUrl = notification.launchUrl ?? '';

      _saveNotificationToHistory(
        notification.title ?? 'Notification',
        notification.body ?? '',
        imageUrl,
        launchUrl,
      );
      event.preventDefault();
      event.notification.display();
    });

    OneSignal.Notifications.addClickListener((event) {
      final notification = event.notification;
      final imageUrl = notification.bigPicture ?? '';
      final launchUrl = notification.launchUrl ?? '';

      _saveNotificationToHistory(
        notification.title ?? 'Notification',
        notification.body ?? '',
        imageUrl,
        launchUrl,
      );

      if (launchUrl.isNotEmpty) {
        _handleDeepLink(launchUrl);
      }
    });
  }

  void _handleDeepLink(String url) {
    int web = 0;
    final lower = url.toLowerCase();
    if (lower.contains('/my-account') ||
        lower.contains('/cart') ||
        lower.contains('/checkout')) {
      web = 2;
    } else if (lower.contains('/shop') ||
        lower.contains('/product') ||
        lower.contains('/product-category')) {
      web = 1;
    }

    final controller = _controllers[web];
    if (controller == null) {
      _pendingDeepLink = url;
      return;
    }

    _startLoading(web);
    controller.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
    final tab = _tabToWeb.indexOf(web);
    if (mounted) {
      setState(() {
        _preloadOthers = true;
        _currentTabIndex = tab;
        _splashVisible = false;
      });
    }
  }

  // ---------------------------------------------------------------------------
  // Navigation & Scheme Interceptor
  // ---------------------------------------------------------------------------
  Future<NavigationActionPolicy> _handleNavigationOverride(
      int web,
      InAppWebViewController controller,
      NavigationAction navigationAction) async {
    final uri = navigationAction.request.url;
    if (uri == null) return NavigationActionPolicy.ALLOW;

    final urlString = uri.toString();

    if (urlString.contains("whatsapp://") ||
        urlString.contains("wa.me") ||
        urlString.contains("api.whatsapp.com")) {
      try {
        await launchUrl(
          Uri.parse(urlString),
          mode: LaunchMode.externalApplication,
        );
      } catch (_) {}
      return NavigationActionPolicy.CANCEL;
    }

    if (!["http", "https", "about", "data", "blob", "file", "javascript"]
        .contains(uri.scheme)) {
      try {
        await launchUrl(Uri.parse(urlString),
            mode: LaunchMode.externalApplication);
      } catch (_) {}
      return NavigationActionPolicy.CANCEL;
    }

    // Show the loader IMMEDIATELY when the user taps a link (e.g. a product),
    // instead of waiting several seconds with a frozen-looking screen.
    if (navigationAction.isForMainFrame && uri.scheme.startsWith("http")) {
      final current = await controller.getUrl();
      final samePage = current != null &&
          current.toString().split('#').first == urlString.split('#').first;
      if (!samePage) _startLoading(web);
    }

    return NavigationActionPolicy.ALLOW;
  }

  // ---------------------------------------------------------------------------
  // Bottom Navigation Handlers
  // ---------------------------------------------------------------------------
  void _onTabTapped(int index) {
    if (index == 2) {
      _showNotificationHistorySheet();
      return;
    }

    HapticFeedback.selectionClick();

    if (index == _currentTabIndex) {
      _controllers[_currentWeb]?.scrollTo(x: 0, y: 0, animated: true);
      return;
    }

    final leaving = _currentWeb;
    _lastLeft[leaving] = DateTime.now();

    setState(() {
      _currentTabIndex = index;
      _preloadOthers = true;
    });

    final web = _currentWeb;
    if (_loaded[web] &&
        !_offline &&
        DateTime.now().difference(_lastLeft[web]).inMinutes >= 10) {
      _controllers[web]?.reload();
      _lastLeft[web] = DateTime.now();
    }
  }

  Future<bool> _handleBack() async {
    final web = _currentWeb;
    // If a page is loading, back cancels the loading overlay first
    if (_loading[web] && _loaded[web]) {
      _controllers[web]?.stopLoading();
      _stopLoading(web);
      return false;
    }
    final c = _controllers[web];
    if (c != null && await c.canGoBack()) {
      c.goBack();
      return false;
    }
    if (_currentTabIndex != 0) {
      setState(() => _currentTabIndex = 0);
      return false;
    }
    return true;
  }

  void _showNotificationHistorySheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Container(
              height: MediaQuery.of(context).size.height * 0.7,
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        "Notification History",
                        style: TextStyle(
                            fontSize: 20, fontWeight: FontWeight.bold),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.pop(context),
                      )
                    ],
                  ),
                  const Divider(),
                  Expanded(
                    child: _notificationHistory.isEmpty
                        ? const Center(
                            child: Text("No past notifications found."),
                          )
                        : ListView.builder(
                            itemCount: _notificationHistory.length,
                            itemBuilder: (context, index) {
                              final item = _notificationHistory[index];
                              final imageUrl = item['image'] ?? '';
                              final targetUrl = item['url'] ?? '';

                              return Card(
                                margin:
                                    const EdgeInsets.symmetric(vertical: 6),
                                child: ListTile(
                                  onTap: () {
                                    if (targetUrl.isNotEmpty) {
                                      Navigator.pop(context);
                                      _handleDeepLink(targetUrl);
                                    }
                                  },
                                  leading: imageUrl.isNotEmpty
                                      ? Image.network(
                                          imageUrl,
                                          width: 50,
                                          height: 50,
                                          fit: BoxFit.cover,
                                          errorBuilder: (context, error,
                                                  stackTrace) =>
                                              const Icon(
                                                  Icons.notifications_active,
                                                  color: Colors.amber),
                                        )
                                      : const Icon(Icons.notifications_active,
                                          color: Colors.amber),
                                  title: Text(item['title'] ?? ''),
                                  subtitle: Text(item['body'] ?? ''),
                                  trailing: Text(
                                    item['time'] ?? '',
                                    style: const TextStyle(
                                        fontSize: 12, color: Colors.grey),
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // WebView factory
  // ---------------------------------------------------------------------------
  Widget _buildWebView(int web) {
    return InAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(_urls[web])),
      initialUserScripts: UnmodifiableListView<UserScript>([_appStyleScript]),
      pullToRefreshController: _refreshControllers[web],
      initialSettings: InAppWebViewSettings(
        // Speed
        cacheEnabled: true,
        cacheMode: CacheMode.LOAD_DEFAULT,
        domStorageEnabled: true,
        databaseEnabled: true,
        javaScriptEnabled: true,
        hardwareAcceleration: true,
        useHybridComposition: true,
        thirdPartyCookiesEnabled: true,
        sharedCookiesEnabled: true,
        mixedContentMode: MixedContentMode.MIXED_CONTENT_COMPATIBILITY_MODE,
        useOnLoadResource: false,
        useShouldInterceptRequest: false,
        // Media
        allowsInlineMediaPlayback: true,
        mediaPlaybackRequiresUserGesture: false,
        // Native feel
        supportZoom: false,
        builtInZoomControls: false,
        displayZoomControls: false,
        verticalScrollBarEnabled: false,
        horizontalScrollBarEnabled: false,
        overScrollMode: OverScrollMode.NEVER,
        disableContextMenu: true,
        allowsBackForwardNavigationGestures: true,
        disallowOverScroll: false,
        transparentBackground: false,
        useShouldOverrideUrlLoading: true,
      ),
      onWebViewCreated: (controller) {
        _controllers[web] = controller;
        final pending = _pendingDeepLink;
        if (pending != null) {
          _pendingDeepLink = null;
          WidgetsBinding.instance
              .addPostFrameCallback((_) => _handleDeepLink(pending));
        }
      },
      shouldOverrideUrlLoading: (controller, action) =>
          _handleNavigationOverride(web, controller, action),
      onLoadStart: (controller, url) {
        if (!_loading[web]) _startLoading(web);
        _error[web] = false;
      },
      onProgressChanged: (controller, progress) {
        final p = progress / 100.0;
        // Only rebuild when the bar visibly moves
        if ((p - _progress[web]).abs() >= 0.05 || progress == 100) {
          if (mounted && !_error[web]) setState(() => _progress[web] = p);
        }
        // Reveal the app as soon as the page is mostly drawn
        if (progress >= 70 && !_loaded[web] && !_error[web]) {
          _loaded[web] = true;
          if (web == 0) _hideSplash();
          if (mounted) setState(() {});
        }
        // Page is readable: drop the blocking overlay early (speed feel)
        if (progress >= 85 && _loading[web] && !_error[web]) {
          _stopLoading(web);
        }
      },
      onLoadStop: (controller, url) {
        if (!_error[web]) {
          _loaded[web] = true;
          if (web == 0) _hideSplash();
        }
        _stopLoading(web);
      },
      onReceivedError: (controller, request, error) {
        _refreshControllers[web].endRefreshing();
        // Ignore cancelled loads and sub-resources (images, scripts...)
        if (request.isForMainFrame != true) return;
        if (error.type == WebResourceErrorType.CANCELLED) return;

        _loadingTimers[web]?.cancel();
        _failedUrl[web] = request.url.toString();
        if (web == 0) _hideSplash();
        if (mounted) {
          setState(() {
            _error[web] = true;
            _loading[web] = false;
          });
        }
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Overlays
  // ---------------------------------------------------------------------------
  Widget _buildOfflineView(int web) {
    return Positioned.fill(
      child: Container(
        color: Colors.white,
        padding: const EdgeInsets.fromLTRB(32, 0, 32, 90),
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const AppLogo(),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: kBrand.withOpacity(0.08),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.wifi_off_rounded,
                  size: 44, color: kBrand),
            ),
            const SizedBox(height: 20),
            const Text(
              "Check your network connection",
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Colors.black87,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              "We couldn't load this page.\nPlease check your internet and try again.",
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: Colors.black54),
            ),
            const SizedBox(height: 24),
            SizedBox(
              height: 48,
              child: ElevatedButton.icon(
                onPressed: () => _retry(web),
                icon: const Icon(Icons.refresh_rounded),
                label: const Text("Try again"),
                style: ElevatedButton.styleFrom(
                  backgroundColor: kBrand,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(24),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoadingOverlay() {
    return Positioned.fill(
      child: Container(
        color: Colors.white.withOpacity(0.85),
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            SizedBox(
              width: 38,
              height: 38,
              child: CircularProgressIndicator(strokeWidth: 3.5, color: kBrand),
            ),
            SizedBox(height: 14),
            Text(
              "Loading, please wait...",
              style: TextStyle(
                color: kBrand,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Main UI Build
  // ---------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final currentWeb = _currentWeb;
    final showError = !_splashVisible &&
        (_error[currentWeb] || (_offline && !_loaded[currentWeb]));
    final showFirstLoader =
        !_splashVisible && !_loaded[currentWeb] && !showError;
    final showNavOverlay = !_splashVisible &&
        _loaded[currentWeb] &&
        _loading[currentWeb] &&
        _progress[currentWeb] < 0.85 &&
        !showError;
    final showTopBar = !_splashVisible &&
        _loading[currentWeb] &&
        !showError &&
        !showNavOverlay;

    return WillPopScope(
      onWillPop: _handleBack,
      child: Scaffold(
        backgroundColor: Colors.white,
        body: SafeArea(
          bottom: false,
          child: Stack(
            children: [
              IndexedStack(
                index: currentWeb,
                children: [
                  _buildWebView(0),
                  _preloadOthers ? _buildWebView(1) : const SizedBox.shrink(),
                  _preloadOthers ? _buildWebView(2) : const SizedBox.shrink(),
                ],
              ),

              // Thin progress bar (page is already usable, still finishing)
              if (showTopBar)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: LinearProgressIndicator(
                    value: _progress[currentWeb].clamp(0.05, 1.0),
                    minHeight: 3,
                    backgroundColor: Colors.transparent,
                    color: Colors.amber,
                  ),
                ),

              // Blocking loader while moving to a new page (e.g. product)
              if (showNavOverlay) _buildLoadingOverlay(),

              // Tab opened before it finished its first load
              if (showFirstLoader) _buildLoadingOverlay(),

              // No internet / failed to load
              if (showError) _buildOfflineView(currentWeb),

              // Small banner when connection drops on an already loaded page
              if (_offline && !showError && !_splashVisible)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: Material(
                    color: Colors.red.shade700,
                    child: const Padding(
                      padding:
                          EdgeInsets.symmetric(vertical: 6, horizontal: 12),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.wifi_off_rounded,
                              color: Colors.white, size: 16),
                          SizedBox(width: 8),
                          Text(
                            "No internet connection",
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

              // Floating bottom bar
              Align(
                alignment: Alignment.bottomCenter,
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding:
                        const EdgeInsets.only(bottom: 6, left: 16, right: 16),
                    child: Container(
                      height: 65,
                      decoration: BoxDecoration(
                        color: kBrand.withOpacity(0.95),
                        borderRadius: BorderRadius.circular(35),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.3),
                            blurRadius: 15,
                            offset: const Offset(0, 5),
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          _buildNavItem(
                              icon: Icons.home_rounded,
                              label: "Home",
                              index: 0),
                          _buildNavItem(
                              icon: Icons.shopping_bag_rounded,
                              label: "Shop",
                              index: 1),
                          _buildNavItem(
                              icon: Icons.notifications_rounded,
                              label: "Alerts",
                              index: 2),
                          _buildNavItem(
                              icon: Icons.person_rounded,
                              label: "Account",
                              index: 3),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

              // Branded splash (logo instead of the star)
              Positioned.fill(
                child: IgnorePointer(
                  ignoring: !_splashVisible,
                  child: AnimatedOpacity(
                    opacity: _splashVisible ? 1 : 0,
                    duration: const Duration(milliseconds: 350),
                    curve: Curves.easeOut,
                    child: Container(
                      color: Colors.white,
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: const [
                          AppLogo(),
                          SizedBox(height: 28),
                          SizedBox(
                            width: 28,
                            height: 28,
                            child: CircularProgressIndicator(
                              strokeWidth: 3,
                              color: kBrand,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNavItem({
    required IconData icon,
    required String label,
    required int index,
  }) {
    final bool isSelected = _currentTabIndex == index;

    return InkWell(
      onTap: () => _onTabTapped(index),
      borderRadius: BorderRadius.circular(30),
      child: SizedBox(
        width: 64,
        height: 65,
        child: Center(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            switchInCurve: Curves.easeOut,
            transitionBuilder: (child, animation) =>
                ScaleTransition(scale: animation, child: child),
            child: isSelected
                ? Container(
                    key: ValueKey('active_$index'),
                    padding: const EdgeInsets.all(10),
                    decoration: const BoxDecoration(
                      color: Colors.amber,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(icon, color: Colors.black, size: 26),
                  )
                : Column(
                    key: ValueKey('idle_$index'),
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, color: Colors.white70, size: 24),
                      const SizedBox(height: 2),
                      Text(
                        label,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}