import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:onesignal_flutter/onesignal_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

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

  // Notification History List loaded from SharedPreferences
  List<Map<String, String>> _notificationHistory = [];

  // WooCommerce Base URLs
  final String _homeUrl = "https://najemstarcall.com/";
  final String _shopUrl = "https://najemstarcall.com/shop";
  final String _accountUrl = "https://najemstarcall.com/my-account";

  @override
  void initState() {
    super.initState();
    _loadNotificationHistory();
    _initOneSignal();
  }

  // ---------------------------------------------------------------------------
  // Persistent Storage for Notification History
  // ---------------------------------------------------------------------------
  Future<void> _loadNotificationHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final List<String>? storedHistory = prefs.getStringList('notification_history');
    if (storedHistory != null) {
      setState(() {
        _notificationHistory = storedHistory
            .map((item) => Map<String, String>.from(jsonDecode(item)))
            .toList();
      });
    }
  }

  Future<void> _saveNotificationToHistory(String title, String body, String imageUrl, String launchUrl) async {
    final prefs = await SharedPreferences.getInstance();
    final newEntry = {
      'title': title,
      'body': body,
      'image': imageUrl,
      'url': launchUrl,
      'time': DateTime.now().toString().substring(11, 16),
    };

    setState(() {
      _notificationHistory.insert(0, newEntry);
    });

    final List<String> encodedList =
        _notificationHistory.map((item) => jsonEncode(item)).toList();
    await prefs.setStringList('notification_history', encodedList);
  }

  // ---------------------------------------------------------------------------
  // OneSignal & Link Handling Configuration
  // ---------------------------------------------------------------------------
  void _initOneSignal() {
    OneSignal.initialize("b8a319d1-1f12-473f-b555-cc237a551f20");
    OneSignal.Notifications.requestPermission(true);

    // Foreground listener: Captures alerts, stores them, and displays them
    OneSignal.Notifications.addForegroundWillDisplayListener((event) {
      final notification = event.notification;
      final imageUrl = notification.bigPicture ?? notification.launchUrl ?? '';
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

    // Notification click listener: Opens links inside the WebView
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

    if (urlString.contains("whatsapp://") ||
        urlString.contains("wa.me") ||
        urlString.contains("api.whatsapp.com")) {
      final Uri whatsappUri = Uri.parse(urlString);
      if (await canLaunchUrl(whatsappUri)) {
        await launchUrl(
          whatsappUri,
          mode: LaunchMode.externalApplication,
        );
      }
      return NavigationActionPolicy.CANCEL;
    }

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
                              final imageUrl = item['image'] ?? '';
                              final targetUrl = item['url'] ?? '';

                              return Card(
                                margin: const EdgeInsets.symmetric(vertical: 6),
                                child: ListTile(
                                  onTap: () {
                                    if (targetUrl.isNotEmpty) {
                                      Navigator.pop(context); // Close sheet
                                      _handleDeepLink(targetUrl); // Open in WebView
                                    }
                                  },
                                  leading: imageUrl.isNotEmpty
                                      ? Image.network(
                                          imageUrl,
                                          width: 50,
                                          height: 50,
                                          fit: BoxFit.cover,
                                          errorBuilder: (context, error, stackTrace) =>
                                              const Icon(Icons.notifications_active, color: Colors.amber),
                                        )
                                      : const Icon(Icons.notifications_active, color: Colors.amber),
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
              InAppWebView(
                initialUrlRequest: URLRequest(url: WebUri(_homeUrl)),
                initialSettings: InAppWebViewSettings(
                  cacheEnabled: true,
                  domStorageEnabled: true,
                  cacheMode: CacheMode.LOAD_DEFAULT,
                  allowsInlineMediaPlayback: true,
                  mediaPlaybackRequiresUserGesture: false,
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

              // Bottom Navigation Bar with #2c348f styling and responsive touch area
              Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 20, left: 16, right: 16),
                  child: Container(
                    height: 65,
                    decoration: BoxDecoration(
                      color: const Color(0xFF2C348F).withOpacity(0.95), // Updated Color #2c348f
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
      return InkWell(
        onTap: () => _onTabTapped(index),
        borderRadius: BorderRadius.circular(30),
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

    return InkWell(
      onTap: () => _onTabTapped(index),
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              color: isSelected ? Colors.amber : Colors.white70,
              size: 24,
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                color: isSelected ? Colors.amber : Colors.white70,
                fontSize: 11,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}