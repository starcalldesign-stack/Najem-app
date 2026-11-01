import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:onesignal_flutter/onesignal_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

const Color kBrand = Color(0xFF2C348F);

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

class MainWebViewScreen extends StatefulWidget {
  const MainWebViewScreen({Key? key}) : super(key: key);

  @override
  State<MainWebViewScreen> createState() => _MainWebViewScreenState();
}

class _MainWebViewScreenState extends State<MainWebViewScreen> {
  // Bottom bar tabs: 0 Home, 1 Shop, 2 Alerts (sheet), 3 Account
  // WebView slots:   0 Home, 1 Shop, 2 Account
  static const List<int> _tabToWeb = [0, 1, -1, 2];

  final List<String> _urls = const [
    "https://najemstarcall.com/",
    "https://najemstarcall.com/shop",
    "https://najemstarcall.com/my-account",
  ];

  final List<InAppWebViewController?> _controllers = [null, null, null];
  final List<bool> _loaded = [false, false, false];
  final List<DateTime> _lastLeft = [
    DateTime.now(),
    DateTime.now(),
    DateTime.now()
  ];
  late final List<PullToRefreshController> _refreshControllers;

  int _currentTabIndex = 0;
  bool _preloadOthers = false; // Shop + Account load after Home is ready
  bool _splashVisible = true;
  Timer? _splashTimeout;

  // Deep link received before the WebView was ready
  String? _pendingDeepLink;

  List<Map<String, String>> _notificationHistory = [];

  int get _currentWeb => _tabToWeb[_currentTabIndex];

  // Injected into every page: removes tap flash and keeps page content
  // from hiding behind the floating bottom bar.
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

    // Never leave the user stuck on the splash screen
    _splashTimeout = Timer(const Duration(seconds: 8), _hideSplash);
  }

  @override
  void dispose() {
    _splashTimeout?.cancel();
    super.dispose();
  }

  void _hideSplash() {
    if (!mounted || !_splashVisible) return;
    setState(() {
      _splashVisible = false;
      _preloadOthers = true;
    });
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
  // OneSignal & Link Handling Configuration (unchanged behaviour)
  // ---------------------------------------------------------------------------
  void _initOneSignal() {
    OneSignal.initialize("b8a319d1-1f12-473f-b555-cc237a551f20");
    OneSignal.Notifications.requestPermission(true);

    // Foreground listener: Captures alerts, stores them, and displays them
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

    // Notification click listener: Opens links inside the app
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

  /// Opens a link in the most fitting tab (shop links -> Shop, account links
  /// -> Account, everything else -> Home). Works even if the app was just
  /// launched from a notification and the WebView is not ready yet.
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
  // Navigation & Scheme Interceptor (WhatsApp / External Links)
  // ---------------------------------------------------------------------------
  Future<NavigationActionPolicy> _handleNavigationOverride(
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

    return NavigationActionPolicy.ALLOW;
  }

  // ---------------------------------------------------------------------------
  // Bottom Navigation Handlers - instant switching, pages stay alive
  // ---------------------------------------------------------------------------
  void _onTabTapped(int index) {
    if (index == 2) {
      _showNotificationHistorySheet();
      return;
    }

    HapticFeedback.selectionClick();

    // Tapping the active tab scrolls the page to the top
    if (index == _currentTabIndex) {
      _controllers[_currentWeb]
          ?.scrollTo(x: 0, y: 0, animated: true);
      return;
    }

    final leaving = _currentWeb;
    _lastLeft[leaving] = DateTime.now();

    setState(() {
      _currentTabIndex = index;
      _preloadOthers = true;
    });

    // Silently refresh a page that has been in the background for a while
    // (keeps login / cart state fresh) without any loading screen.
    final web = _currentWeb;
    if (_loaded[web] &&
        DateTime.now().difference(_lastLeft[web]).inMinutes >= 10) {
      _controllers[web]?.reload();
      _lastLeft[web] = DateTime.now();
    }
  }

  Future<bool> _handleBack() async {
    final c = _controllers[_currentWeb];
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
                                      Navigator.pop(context); // Close sheet
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
  // WebView factory (one per main tab, kept alive)
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
      shouldOverrideUrlLoading: _handleNavigationOverride,
      onProgressChanged: (controller, progress) {
        // Reveal the app as soon as the page is mostly drawn
        if (progress >= 70 && !_loaded[web]) {
          _loaded[web] = true;
          if (web == 0) _hideSplash();
          if (mounted) setState(() {});
        }
        if (progress == 100) {
          _refreshControllers[web].endRefreshing();
        }
      },
      onLoadStop: (controller, url) {
        _refreshControllers[web].endRefreshing();
        if (!_loaded[web]) {
          _loaded[web] = true;
          if (web == 0) _hideSplash();
          if (mounted) setState(() {});
        }
      },
      onReceivedError: (controller, request, error) {
        _refreshControllers[web].endRefreshing();
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Main UI Build
  // ---------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final currentWeb = _currentWeb;

    return WillPopScope(
      onWillPop: _handleBack,
      child: Scaffold(
        backgroundColor: Colors.white,
        body: SafeArea(
          bottom: false,
          child: Stack(
            children: [
              // All main pages live here and stay in memory => instant switching
              IndexedStack(
                index: currentWeb,
                children: [
                  _buildWebView(0),
                  _preloadOthers ? _buildWebView(1) : const SizedBox.shrink(),
                  _preloadOthers ? _buildWebView(2) : const SizedBox.shrink(),
                ],
              ),

              // Tab opened before it finished loading: clean app-style loader
              if (!_splashVisible && !_loaded[currentWeb])
                Positioned.fill(
                  child: Container(
                    color: Colors.white,
                    alignment: Alignment.center,
                    child: const SizedBox(
                      width: 34,
                      height: 34,
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        color: kBrand,
                      ),
                    ),
                  ),
                ),

              // Floating bottom bar (moved lower)
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
                            index: 0,
                          ),
                          _buildNavItem(
                            icon: Icons.shopping_bag_rounded,
                            label: "Shop",
                            index: 1,
                          ),
                          _buildNavItem(
                            icon: Icons.notifications_rounded,
                            label: "Alerts",
                            index: 2,
                          ),
                          _buildNavItem(
                            icon: Icons.person_rounded,
                            label: "Account",
                            index: 3,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

              // Branded splash shown only on first launch
              Positioned.fill(
                child: IgnorePointer(
                  ignoring: !_splashVisible,
                  child: AnimatedOpacity(
                    opacity: _splashVisible ? 1 : 0,
                    duration: const Duration(milliseconds: 350),
                    curve: Curves.easeOut,
                    child: Container(
                      color: kBrand,
                      alignment: Alignment.center,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: const [
                          Icon(Icons.star_rounded,
                              color: Colors.amber, size: 72),
                          SizedBox(height: 14),
                          Text(
                            "Najem Starcall",
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 0.5,
                            ),
                          ),
                          SizedBox(height: 28),
                          SizedBox(
                            width: 26,
                            height: 26,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              color: Colors.amber,
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

    // The active tab gets the amber circle; the others show icon + label
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
