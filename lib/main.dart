import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:onesignal_flutter/onesignal_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
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
  InAppWebViewController? _webViewController;
  bool _isLoading = true;
  int _currentTabIndex = 0;

  // Local OneSignal Notification History Array
  final List<Map<String, String>> _notificationHistory = [];

  // WooCommerce Base URLs
  final String _homeUrl = "https://najemstarcall.com/";
  final String _shopUrl = "https://najemstarcall.com/shop";
  final String _accountUrl = "https://najemstarcall.com/my-account";

  @override
  void initState() {
    super.initState();
    _initOneSignal();
  }

  // ---------------------------------------------------------------------------
  // OneSignal & Link Handling Configuration
  // ---------------------------------------------------------------------------
  void _initOneSignal() {
    // Replace with your OneSignal App ID
    OneSignal.initialize("YOUR_ONESIGNAL_APP_ID_HERE");
    OneSignal.Notifications.requestPermission(true);

    // Foreground listener: Captures alerts and stores them in local history
    OneSignal.Notifications.addForegroundWillDisplayListener((event) {
      final notification = event.notification;
      setState(() {
        _notificationHistory.insert(0, {
          'title': notification.title ?? 'Notification',
          'body': notification.body ?? '',
          'time': DateTime.now().toString().substring(11, 16),
        });
      });
      event.preventDefault();
      event.notification.display();
    });

    // Notification click listener: Opens links inside the WebView (not Chrome)
    OneSignal.Notifications.addClickListener((event) {
      final launchUrl = event.notification.launchUrl;
      if (launchUrl != null && launchUrl.isNotEmpty) {
        _handleDeepLink(launchUrl);
      }
    });
  }

  void _handleDeepLink(String url) {
    if (_webViewController != null) {
      _webViewController!.loadUrl(
        urlRequest: URLRequest(url: WebUri(url)),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Navigation & Scheme Interceptor (WhatsApp / External Links)
  // ---------------------------------------------------------------------------
  Future<NavigationActionPolicy> _handleNavigationOverride(
      InAppWebViewController controller, NavigationAction navigationAction) async {
    final uri = navigationAction.request.url;
    if (uri == null) return NavigationActionPolicy.ALLOW;

    final urlString = uri.toString();

    // 1. WhatsApp Scheme Interception (whatsapp://, wa.me, api.whatsapp.com)
    if (urlString.contains("whatsapp://") ||
        urlString.contains("wa.me") ||
        urlString.contains("api.whatsapp.com")) {
      
      final Uri whatsappUri = Uri.parse(urlString);
      if (await canLaunchUrl(whatsappUri)) {
        await launchUrl(
          whatsappUri,
          mode: LaunchMode.externalApplication, // Opens external native WhatsApp
        );
      }
      return NavigationActionPolicy.CANCEL; // Stops WebView from stalling
    }

    // 2. Intercept Tel / Mailto schemes
    if (!["http", "https"].contains(uri.scheme)) {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
      return NavigationActionPolicy.CANCEL;
    }

    return NavigationActionPolicy.ALLOW;
  }

  // ---------------------------------------------------------------------------
  // Bottom Navigation Handlers
  // ---------------------------------------------------------------------------
  void _onTabTapped(int index) {
    if (index == 2) {
      // Notification History Modal
      _showNotificationHistorySheet();
      return;
    }

    setState(() {
      _currentTabIndex = index;
    });

    switch (index) {
      case 0:
        _webViewController?.loadUrl(urlRequest: URLRequest(url: WebUri(_homeUrl)));
        break;
      case 1:
        _webViewController?.loadUrl(urlRequest: URLRequest(url: WebUri(_shopUrl)));
        break;
      case 3:
        _webViewController?.loadUrl(urlRequest: URLRequest(url: WebUri(_accountUrl)));
        break;
    }
  }

  void _showNotificationHistorySheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
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
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
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
                          return Card(
                            margin: const EdgeInsets.symmetric(vertical: 6),
                            child: ListTile(
                              leading: const Icon(Icons.notifications_active, color: Colors.amber),
                              title: Text(item['title'] ?? ''),
                              subtitle: Text(item['body'] ?? ''),
                              trailing: Text(
                                item['time'] ?? '',
                                style: const TextStyle(fontSize: 12, color: Colors.grey),
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
  }

  // ---------------------------------------------------------------------------
  // Main UI Build
  // ---------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        if (_webViewController != null && await _webViewController!.canGoBack()) {
          _webViewController!.goBack();
          return false;
        }
        return true;
      },
      child: Scaffold(
        body: SafeArea(
          child: Stack(
            children: [
              // 1, 2 & 3. WebView with Aggressive Caching, DOM Storage & Media Playback Fixes
              InAppWebView(
                initialUrlRequest: URLRequest(url: WebUri(_homeUrl)),
                initialSettings: InAppWebViewSettings(
                  // Caching & DOM Persistence for WooCommerce sessions/carts
                  cacheEnabled: true,
                  domStorageEnabled: true,
                  cacheMode: CacheMode.LOAD_DEFAULT,

                  // Hardware Acceleration & Embedded YouTube Fixes
                  allowsInlineMediaPlayback: true,
                  mediaPlaybackRequiresUserGesture: false,

                  // General Features
                  javaScriptEnabled: true,
                  supportZoom: false,
                  useShouldOverrideUrlLoading: true,
                ),
                onWebViewCreated: (controller) {
                  _webViewController = controller;
                },
                shouldOverrideUrlLoading: _handleNavigationOverride,
                onLoadStart: (controller, url) {
                  setState(() => _isLoading = true);
                },
                onLoadStop: (controller, url) {
                  setState(() => _isLoading = false);
                },
              ),

              // 4. Smart Loading Feedback
              if (_isLoading)
                const Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: LinearProgressIndicator(
                    color: Colors.amber,
                    backgroundColor: Colors.transparent,
                    minHeight: 3,
                  ),
                ),

              // 5. Custom Floating Pill-Shaped Bottom Navigation Bar
              Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 20, left: 16, right: 16),
                  child: Container(
                    height: 65,
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.9),
                      borderRadius: BorderRadius.circular(35),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.25),
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
                          isHighlighted: true,
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
    bool isHighlighted = false,
  }) {
    final bool isSelected = _currentTabIndex == index;

    if (isHighlighted) {
      return GestureDetector(
        onTap: () => _onTabTapped(index),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: const BoxDecoration(
            color: Colors.amber,
            shape: BoxShape.circle,
          ),
          child: Icon(
            icon,
            color: Colors.black,
            size: 26,
          ),
        ),
      );
    }

    return GestureDetector(
      onTap: () => _onTabTapped(index),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            icon,
            color: isSelected ? Colors.amber : Colors.grey,
            size: 24,
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              color: isSelected ? Colors.amber : Colors.grey,
              fontSize: 11,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }
}