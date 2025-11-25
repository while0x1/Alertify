import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:provider/provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:intl/intl.dart';
import 'package:collection/collection.dart'; // For iterableExtension
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart'; // Import for Clipboard

import 'firebase_options.dart';

// Your FastAPI server's base URL (adjust if deployed differently)
const String FASTAPI_BASE_URL = 'https://alertify.while0x1.com';

// --- NEW GLOBAL FUNCTION TO CACHE MESSAGES ---
// This function needs to be outside any class and a top-level function
// because it's called from the background handler.
Future<void> _cacheMessage(RemoteMessage message) async {
  // Ensure Firebase is initialized for background tasks if it hasn't been already
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  final prefs = await SharedPreferences.getInstance();

  // Get current cached messages
  final List<String> cachedMessagesJson = prefs.getStringList('cached_fcm_messages') ?? [];

  // Extract messageId for deduplication, or generate one if missing (though your server should provide it)
  final String? messageId = message.data['messageId'];
  if (messageId == null) {
    print('WARNING: Message received without messageId. Cannot deduplicate accurately. Message: ${message.notification?.title}');
    // If messageId is critical and always expected, you might choose to skip caching this message.
    // For now, we'll proceed but this might lead to duplicates if the server doesn't send messageId.
  }

  // Convert the RemoteMessage to a storable Map
  final Map<String, dynamic> messageMap = {
    'notification': message.notification?.toMap(),
    'data': message.data,
    'messageId': messageId, // Store the messageId explicitly in the cached map
    'receivedTimestamp': DateTime.now().millisecondsSinceEpoch, // When it was received
  };

  // Check for duplicates before adding to cache using messageId
  bool isDuplicate = cachedMessagesJson.any((jsonString) {
    final Map<String, dynamic> existingMessage = jsonDecode(jsonString);
    return existingMessage['messageId'] == messageId && messageId != null;
  });

  if (!isDuplicate) {
    cachedMessagesJson.add(jsonEncode(messageMap));
    await prefs.setStringList('cached_fcm_messages', cachedMessagesJson);
    print('FCM Message cached: ${message.notification?.title} (ID: $messageId)');
  } else {
    print('FCM Message (ID: $messageId) already in cache, skipping.');
  }
}

// Background message handler
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  print('FCM Background Message received: ${message.notification?.title}');
  print('FCM Background Message received. OS handled notification display.');

  // --- MODIFICATION: Cache the message in the background handler ---
  await _cacheMessage(message);
}

// Notification plugin instance
final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

// Function to show notification with default system sound
Future<void> _showNotification(RemoteMessage message) async {
  print('Attempting to show local notification for: ${message.notification?.title}');
  final notification = message.notification;
  final data = message.data;
  final title = notification?.title ?? data['title'] ?? 'No Title';
  final body = notification?.body ?? data['message'] ?? 'No Message';

  const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
    'Alert_channel',
    'Alertify Notifications',
    channelDescription: 'Notifications for Alertify messages',
    importance: Importance.high,
    priority: Priority.high,
    playSound: true, // Uses default system sound
  );

  const DarwinNotificationDetails iOSDetails = DarwinNotificationDetails();
  const NotificationDetails platformDetails = NotificationDetails(
    android: androidDetails,
    iOS: iOSDetails,
  );

  await flutterLocalNotificationsPlugin.show(
    DateTime.now().millisecondsSinceEpoch % 10000,
    title,
    body,
    platformDetails,
  );
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  const AndroidInitializationSettings initializationSettingsAndroid =
      AndroidInitializationSettings('@mipmap/ic_launcher');
  const DarwinInitializationSettings initializationSettingsIOS =
      DarwinInitializationSettings();
  const InitializationSettings initializationSettings = InitializationSettings(
    android: initializationSettingsAndroid,
    iOS: initializationSettingsIOS,
  );
  await flutterLocalNotificationsPlugin.initialize(initializationSettings);

  await Permission.notification.request();

  final FirebaseMessaging messaging = FirebaseMessaging.instance;
  await messaging.requestPermission(
    alert: true,
    badge: true,
    sound: true,
  );
  await messaging.setForegroundNotificationPresentationOptions(
    alert: true,
    badge: true,
    sound: true,
  );

  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  runApp(
    ChangeNotifierProvider(
      create: (_) => NotificationProvider(),
      child: const MyApp(),
    ),
  );
}

class AppLoadingScreen extends StatelessWidget {
  const AppLoadingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.deepPurple.shade700,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.notifications_active,
              size: 100.0,
              color: Colors.white,
            ),
            const SizedBox(height: 20),
            const Text(
              'Alertify',
              style: TextStyle(
                color: Colors.white,
                fontSize: 32,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 30),
            const CircularProgressIndicator(
              valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Alertify',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        appBarTheme: AppBarTheme(
          backgroundColor: Colors.deepPurple.shade700,
          foregroundColor: Colors.white,
        ),
      ),
      home: FutureBuilder(
        future: Provider.of<NotificationProvider>(context, listen: false).initialized,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.done) {
            return const MainPage();
          } else {
            return const AppLoadingScreen();
          }
        },
      ),
    );
  }
}

class NotificationProvider with ChangeNotifier {
  List<Map<String, dynamic>> notifications = [];
  List<Map<String, String>> projects = [];
  String? fcmToken;
  bool _isNotificationsMuted = false;
  String? _userId;

  // --- NEW: List to store IDs of deleted messages ---
  List<String> _deletedMessageIds = [];

  bool get isNotificationsMuted => _isNotificationsMuted;
  String? get userId => _userId;

  static const int MAX_MESSAGES_COUNT = 500;
  static const int MAX_DELETED_MESSAGES_COUNT = 1000; // Limit deleted message IDs to prevent excessive storage

  final Completer<void> _initCompleter = Completer<void>();
  Future<void> get initialized => _initCompleter.future;

  NotificationProvider() {
    _initAsyncProcess();
  }

  Future<void> _initAsyncProcess() async {
    await _loadData();
    await _getOrCreateUserId();
    await _setupFCM();
    // --- NEW: Process any messages cached while the app was in the background/closed ---
    await _processCachedNotifications();
    _initCompleter.complete();
  }

  Future<void> _sendFcmTokenToServer(String token) async {
    if (_userId == null) {
      print('WARNING: Cannot send FCM token to server, userId is null. Cannot send FCM token.');
      return;
    }
    try {
      print('DEBUG: Attempting to send FCM token to server at $FASTAPI_BASE_URL/update-fcm-token');
      final response = await http.post(
        Uri.parse('$FASTAPI_BASE_URL/update-fcm-token'),
        headers: <String, String>{
          'Content-Type': 'application/json',
          'X-User-Id': _userId!,
          'X-FCM-Token': token,
        },
        body: jsonEncode({'fcmToken': token}),
      ).timeout(Duration(seconds: kDebugMode ? 45 : 15));

      if (response.statusCode == 200) {
        print('FCM token successfully sent to server. Status: ${response.statusCode}');
      } else {
        print('Failed to send FCM token to server. Status: ${response.statusCode}, Body: ${response.body}');
        try {
            final errorJson = jsonDecode(response.body);
            print('Server Error Details: $errorJson');
        } catch (_) {
            print('Server Error Details (Raw Body, not JSON): ${response.body}');
        }
      }
    } on TimeoutException catch (e) {
      print('ERROR: FCM token send to server timed out after 15 seconds. Exception: $e');
    }
    catch (e) {
      print('ERROR: General error sending FCM token to server. Type: ${e.runtimeType}, Message: $e');
      print('Stack trace: ${StackTrace.current}');
    }
  }

  Future<void> _getOrCreateUserId() async {
    final prefs = await SharedPreferences.getInstance();
    _userId = prefs.getString('userId');
    if (_userId == null) {
      _userId = const Uuid().v4();
      await prefs.setString('userId', _userId!);
      print('New User ID generated: $_userId');
    } else {
      print('Existing User ID: $_userId');
    }
  }

  Future<void> _loadData() async {
    final prefs = await SharedPreferences.getInstance();
    
    final savedProjectsJson = prefs.getString('projects');
    if (savedProjectsJson != null) {
      projects = List<Map<String, String>>.from(
        (jsonDecode(savedProjectsJson) as List).map((item) => Map<String, String>.from(item)),
      );
    }
    
    for (var project in projects) {
      await FirebaseMessaging.instance.subscribeToTopic('project_${project['id']}');
      print('Subscribed to topic: project_${project['id']}');
    }

    final savedNotifications = prefs.getString('notifications');
    if (savedNotifications != null) {
      notifications = List<Map<String, dynamic>>.from(
        (jsonDecode(savedNotifications) as List)
            .map((item) => Map<String, dynamic>.from(item)),
      );
    }

    // --- NEW: Load deleted message IDs ---
    _deletedMessageIds = prefs.getStringList('deleted_fcm_message_ids') ?? [];

    _isNotificationsMuted = prefs.getBool('isNotificationsMuted') ?? false;

    while (notifications.length > MAX_MESSAGES_COUNT) {
        notifications.removeLast();
    }
    // --- NEW: Trim deleted message IDs if too many ---
    while (_deletedMessageIds.length > MAX_DELETED_MESSAGES_COUNT) {
      _deletedMessageIds.removeAt(0); // Remove oldest
    }

    notifyListeners();
  }

  Future<void> _saveData() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('projects', jsonEncode(projects));
    await prefs.setString('notifications', jsonEncode(notifications));
    await prefs.setBool('isNotificationsMuted', _isNotificationsMuted);
    // --- NEW: Save deleted message IDs ---
    await prefs.setStringList('deleted_fcm_message_ids', _deletedMessageIds);
  }

  Future<void> toggleNotificationMute(bool newValue) async {
    _isNotificationsMuted = newValue;
    await _saveData();
    notifyListeners();
  }

  int _extractTimestamp(RemoteMessage message) {
    final String? timestampStr = message.data['timestamp'];
    if (timestampStr != null) {
      final int? serverTimestamp = int.tryParse(timestampStr);
      if (serverTimestamp != null) {
        return serverTimestamp;
      }
    }
    return DateTime.now().millisecondsSinceEpoch;
  }

  // --- NEW: Helper to add a message to the UI, with deduplication and deleted check ---
  Future<void> _addOrUpdateNotification(Map<String, dynamic> messageData) async {
    final String? messageId = messageData['messageId'];
    if (messageId == null) {
      print('Warning: Notification data without messageId. Cannot guarantee deduplication.');
    }

    // 1. Check if it's a deleted message
    if (messageId != null && _deletedMessageIds.contains(messageId)) {
      print('Skipping message $messageId: It was previously deleted by the user.');
      return;
    }

    // 2. Check for duplication among existing notifications
    final existingIndex = notifications.indexWhere((n) => n['messageId'] == messageId && messageId != null);

    if (existingIndex != -1) {
      // Message already exists, potentially update it if content changes are expected
      // For now, we'll just skip to avoid visual "flicker" for same message.
      print('Message (ID: $messageId) already present in UI, skipping addition.');
      return;
    } else {
      // Add new message
      //'title': messageData['notification']?['title'] ?? messageData['data']?['title'] ?? 'No Title',
      // 'message': messageData['notification']?['body'] ?? messageData['data']?['message'] ?? 'No Message',
      // Check if message has title and content or is a buggy message
      if (messageData['title'] != 'No Title' && messageData['message'] != 'No Message')
        {
          notifications.insert(0, messageData);
          print('Adding new message to UI: ${messageData['title']} (ID: $messageId)');

        }

      while (notifications.length > MAX_MESSAGES_COUNT) {
        notifications.removeLast();
      }
      await _saveData();
      notifyListeners();
    }
  }

  // --- NEW: Process messages that were cached while the app was not active ---
  Future<void> _processCachedNotifications() async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> cachedMessagesJson = prefs.getStringList('cached_fcm_messages') ?? [];
    List<Map<String, dynamic>> messagesToProcess = [];

    for (String jsonString in cachedMessagesJson) {
      try {
        messagesToProcess.add(jsonDecode(jsonString));
      } catch (e) {
        print('Error decoding cached message JSON: $e');
      }
    }

    // Clear cache immediately after reading
    await prefs.remove('cached_fcm_messages');
    print('Cleared cached FCM messages from SharedPreferences.');

    // Sort messages by receivedTimestamp if available, to process in order
    messagesToProcess.sort((a, b) => (a['receivedTimestamp'] as int? ?? 0)
        .compareTo(b['receivedTimestamp'] as int? ?? 0));

    for (final messageData in messagesToProcess) {
      // Reconstruct a RemoteMessage like object for compatibility or just use the map
      // For _addOrUpdateNotification, we can directly use the map
      final Map<String, dynamic> notificationData = {
        'title': messageData['notification']?['title'] ?? messageData['data']?['title'] ?? 'No Title',
        'message': messageData['notification']?['body'] ?? messageData['data']?['message'] ?? 'No Message',
        'timestamp': _extractTimestamp(RemoteMessage(data: messageData['data'])), // Use helper to extract
        'projectId': messageData['data']?['projectId'],
        'messageId': messageData['messageId'], // Crucial for deduplication
      };
      await _addOrUpdateNotification(notificationData);
    }
    print('Finished processing cached notifications.');
  }

  Future<void> _setupFCM() async {
    final messaging = FirebaseMessaging.instance;

    fcmToken = await messaging.getToken();
    if (fcmToken != null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('fcmToken', fcmToken!);
      print('FCM Token: $fcmToken');
      await _sendFcmTokenToServer(fcmToken!);
    }

    messaging.onTokenRefresh.listen((newToken) async {
      fcmToken = newToken;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('fcmToken', newToken);
      print('FCM Token Refreshed: $newToken');
      await _sendFcmTokenToServer(newToken);
      for (var project in projects) {
        await messaging.subscribeToTopic('project_${project['id']}');
      }
    });

    FirebaseMessaging.onMessage.listen((RemoteMessage message) async {
      print('FCM Foreground Message received: ${message.notification?.title}');
      
      // Extract common message data including messageId
      final String? messageId = message.data['messageId'];
      final Map<String, dynamic> notificationData = {
        'title': message.notification?.title ?? message.data['title'] ?? 'No Title',
        'message': message.notification?.body ?? message.data['message'] ?? 'No Message',
        'timestamp': _extractTimestamp(message),
        'projectId': message.data['projectId'],
        'messageId': messageId, // Pass messageId for deduplication
      };

      // --- MODIFICATION: Add message to UI directly if foreground, or cache if it was meant for background and somehow came here ---
      // This listener typically only fires when the app is in the foreground.
      // We directly add to the UI and then potentially show a local notification.
      await _addOrUpdateNotification(notificationData);

      if (!_isNotificationsMuted) {
        await _showNotification(message);
      } else {
        print('Notifications muted, not showing local notification.');
      }
      // notifyListeners() is called within _addOrUpdateNotification
    });

    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) async {
      print('FCM Message opened app from background: ${message.notification?.title}');
      // --- MODIFICATION: When app opened via notification, process cached messages ---
      // The message that opened the app is often *also* stored in the cache by the background handler.
      // So, processing the cache ensures it's added along with any others received while inactive.
      await _processCachedNotifications();
      // If _processCachedNotifications handles it, we don't need to add it here again.
      // However, if the message was not cached by the background handler (e.g., due to an issue),
      // we should ensure it's still displayed. The _addOrUpdateNotification will deduplicate.
      final String? messageId = message.data['messageId'];
      final Map<String, dynamic> notificationData = {
        'title': message.notification?.title ?? message.data['title'] ?? 'No Title',
        'message': message.notification?.body ?? message.data['message'] ?? 'No Message',
        'timestamp': _extractTimestamp(message),
        'projectId': message.data['projectId'],
        'messageId': messageId,
      };
      await _addOrUpdateNotification(notificationData);
    });

    final initialMessage = await messaging.getInitialMessage();
    if (initialMessage != null) {
      print('FCM App launched from terminated state via message: ${initialMessage.notification?.title}');
      // --- MODIFICATION: When app launched from terminated state via message, process cached messages ---
      // Similar to onMessageOpenedApp, ensure all cached messages are processed.
      await _processCachedNotifications();
      final String? messageId = initialMessage.data['messageId'];
      final Map<String, dynamic> notificationData = {
        'title': initialMessage.notification?.title ?? initialMessage.data['title'] ?? 'No Title',
        'message': initialMessage.notification?.body ?? initialMessage.data['message'] ?? 'No Message',
        'timestamp': _extractTimestamp(initialMessage),
        'projectId': initialMessage.data['projectId'],
        'messageId': messageId,
      };
      await _addOrUpdateNotification(notificationData);
    }
  }

  Future<void> createProject(BuildContext context, String projectName) async {
    if (_userId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Error: User ID not available. Cannot create project.')),
      );
      return;
    }

    try {
      final response = await http.post(
        Uri.parse('$FASTAPI_BASE_URL/create-alertify-project'),
        headers: <String, String>{
          'Content-Type': 'application/json',
          'X-User-Id': _userId!,
        },
        body: jsonEncode({
          'projectName': projectName.isEmpty ? 'Unnamed Project' : projectName,
        }),
      ).timeout(Duration(seconds: kDebugMode ? 45 : 15));

      if (response.statusCode == 200) {
        final Map<String, dynamic> responseBody = jsonDecode(response.body);
        final String newProjectId = responseBody['projectId'];
        final String newProjectName = responseBody['projectName'];

        final projectMap = {'id': newProjectId, 'name': newProjectName};
        projects.add(projectMap);
        await FirebaseMessaging.instance.subscribeToTopic('project_$newProjectId');
        await _saveData();
        notifyListeners();

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('New project created: $newProjectName (ID: $newProjectId)')),
        );
      } else {
        String errorMessage = 'Failed to create project.';
        try {
          final errorBody = jsonDecode(response.body);
          if (errorBody.containsKey('detail')) {
            errorMessage = errorBody['detail'];
          }
        } catch (_) {
          errorMessage = 'Server error: ${response.body}';
        }

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(errorMessage)),
        );
      }
    } on TimeoutException catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Request timed out. Please try again.')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Network error: $e')),
      );
    }
  }

  Future<bool> joinProject(BuildContext context, String projectId, String projectName) async {
    if (projectId.isEmpty || projects.any((p) => p['id'] == projectId)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Project ID cannot be empty or is already joined.')),
      );
      return false;
    }

    if (_userId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Error: User ID not available for subscription check.')),
      );
      return false;
    }

    try {
      final response = await http.post(
        Uri.parse('$FASTAPI_BASE_URL/check-user-subscription'),
        headers: <String, String>{
          'Content-Type': 'application/json',
          'X-User-Id': _userId!,
        },
      );

      if (response.statusCode == 200) {
        final Map<String, dynamic> responseBody = jsonDecode(response.body);
        if (responseBody['has_valid_subscription'] == true) {
          final projectMap = {'id': projectId, 'name': projectName.isEmpty ? projectId : projectName};
          projects.add(projectMap);
          await FirebaseMessaging.instance.subscribeToTopic('project_$projectId');
          await _saveData();
          notifyListeners();
          return true;
        } else {
          _showSubscriptionDeniedDialog(context, responseBody['message'] ?? 'You do not have a valid subscription to join projects.');
          return false;
        }
      } else {
        _showSubscriptionDeniedDialog(context, 'Server error while checking subscription: ${response.statusCode}');
        return false;
      }
    } on TimeoutException catch (_) {
        _showSubscriptionDeniedDialog(context, 'Request timed out. Please try again.');
        return false;
    } catch (e) {
      _showSubscriptionDeniedDialog(context, 'Network error while checking subscription: $e');
      return false;
    }
  }

  void _showSubscriptionDeniedDialog(BuildContext context, String message) {
    showDialog(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text("Subscription Required"),
          content: Text(message),
          actions: <Widget>[
            TextButton(
              child: const Text("OK"),
              onPressed: () {
                Navigator.of(dialogContext).pop();
              },
            ),
          ],
        );
      },
    );
  }

  Future<void> leaveProject(String projectId) async {
    projects.removeWhere((project) => project['id'] == projectId);
    await FirebaseMessaging.instance.unsubscribeFromTopic('project_$projectId');
    await _saveData();
    notifyListeners();
  }

  // --- MODIFICATION: Mark message as deleted using its messageId ---
  Future<void> deleteNotification(int index) async {
    if (index >= 0 && index < notifications.length) {
      final deletedMessage = notifications.removeAt(index);
      final String? messageId = deletedMessage['messageId'];
      if (messageId != null && !_deletedMessageIds.contains(messageId)) {
        _deletedMessageIds.add(messageId);
        // Trim deleted message IDs if necessary
        while (_deletedMessageIds.length > MAX_DELETED_MESSAGES_COUNT) {
          _deletedMessageIds.removeAt(0); // Remove oldest deleted ID
        }
        print('Marked message $messageId as deleted.');
      }
      await _saveData();
      notifyListeners();
    }
  }
}


class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  int _selectedIndex = 0;

  @override
  Widget build(BuildContext context) {
    final List<Widget> pages = [
      const HomePage(),
      const ProjectsPage(),
      const UserPage(),
    ];

    return Scaffold(
      appBar: AppBar(
        leading: const Padding(
          padding: EdgeInsets.only(left: 8.0),
          child: Icon(Icons.notifications_active, size: 28.0),
        ),
        title: const Text('Alertify'),
      ),
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: _selectedIndex,
            onDestinationSelected: (int index) {
              setState(() {
                _selectedIndex = index;
              });
            },
            labelType: NavigationRailLabelType.all,
            destinations: const [
              NavigationRailDestination(
                icon: Icon(Icons.home),
                label: Text('Home'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.group),
                label: Text('Projects'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.person),
                label: Text('User'),
              ),
            ],
          ),
          Expanded(child: pages[_selectedIndex]), // Ensure the page content expands
        ],
      ),
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Consumer<NotificationProvider>(
        builder: (context, provider, child) {
          if (provider.notifications.isEmpty) {
            return const Center(
              child: Text('No messages yet. Join or create a project!'),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.all(16.0),
            itemCount: provider.notifications.length,
            itemBuilder: (context, index) {
              final notification = provider.notifications[index];
              final int? timestampMillis = notification['timestamp'] as int?;
              final String? notificationProjectId = notification['projectId'] as String?;

              String formattedDate = 'No date';
              if (timestampMillis != null) {
                final DateTime date =
                    DateTime.fromMillisecondsSinceEpoch(timestampMillis);
                formattedDate = DateFormat('dd.MM.yy HH:mm').format(date);
              }

              String associatedProjectDisplay = 'Unknown Project';
              if (notificationProjectId != null) {
                final associatedProject = provider.projects.firstWhereOrNull(
                  (p) => p['id'] == notificationProjectId
                );

                if (associatedProject != null) {
                    final name = associatedProject['name'] ?? 'Unnamed Project';
                    associatedProjectDisplay = '$name (${notificationProjectId})';
                } else {
                    associatedProjectDisplay = 'Project ID: $notificationProjectId';
                }
              }

              return Card(
                margin: const EdgeInsets.only(bottom: 16.0),
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '$formattedDate - $associatedProjectDisplay',
                        style: const TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded( // FIX: Expanded for notification title
                            child: Text(
                              notification['title']!,
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete),
                            onPressed: () {
                              Provider.of<NotificationProvider>(context, listen: false)
                                  .deleteNotification(index);
                            },
                          ),
                        ],
                      ),
                      Text(notification['message']!), // Text in a Column will wrap automatically
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class ProjectsPage extends StatefulWidget {
  const ProjectsPage({super.key});

  @override
  State<ProjectsPage> createState() => _ProjectsPageState();
}

class _ProjectsPageState extends State<ProjectsPage> {
  final TextEditingController newProjectNameController = TextEditingController();
  final TextEditingController joinProjectIdController = TextEditingController();

  bool _isCreatingProject = false;
  bool _isJoiningProject = false;
  final Set<String> _leavingProjectIds = {}; // Use a set to track projects being left

  @override
  void dispose() {
    newProjectNameController.dispose();
    joinProjectIdController.dispose();
    super.dispose();
  }

  void _copyToClipboard(BuildContext context, String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$label copied to clipboard!')),
    );
  }

  Future<void> _showJoinProjectDialog(BuildContext context) async {
    final TextEditingController dialogProjectNameController = TextEditingController();
    final TextEditingController dialogProjectIdController = TextEditingController(text: joinProjectIdController.text);

    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('Join Project'),
          content: SingleChildScrollView(
            child: ListBody(
              children: <Widget>[
                TextField(
                  controller: dialogProjectIdController,
                  decoration: const InputDecoration(
                    labelText: 'Project ID (UUID)',
                    hintText: 'e.g., a1b2c3d4',
                  ),
                  enabled: !_isJoiningProject, // Disable while loading
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: dialogProjectNameController,
                  decoration: const InputDecoration(
                    labelText: 'Display Name',
                    hintText: 'e.g., Team Alpha Alerts',
                  ),
                  enabled: !_isJoiningProject, // Disable while loading
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('Cancel'),
              onPressed: _isJoiningProject ? null : () { // Disable cancel while loading
                Navigator.of(dialogContext).pop();
              },
            ),
            TextButton(
              onPressed: _isJoiningProject ? null : () async { // Disable join while loading
                setState(() {
                  _isJoiningProject = true; // Start loading for join dialog
                });
                try {
                  final projectId = dialogProjectIdController.text.trim();
                  final projectName = dialogProjectNameController.text.trim();
                  if (projectId.isNotEmpty) {
                    final success = await Provider.of<NotificationProvider>(
                      context, listen: false
                    ).joinProject(context, projectId, projectName);
                    
                    if (success) {
                      joinProjectIdController.clear();
                      Navigator.of(dialogContext).pop(); // Dismiss dialog only on success
                    }
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Project ID cannot be empty.')),
                    );
                  }
                } finally {
                  setState(() {
                    _isJoiningProject = false; // Stop loading
                  });
                }
              },
              child: _isJoiningProject
                  ? const SizedBox(
                      height: 20.0,
                      width: 20.0,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.0,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.blue), // Adjust color as needed
                      ),
                    )
                  : const Text('Join'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<NotificationProvider>(context);

    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              title: const Text('Mute Notifications'),
              value: provider.isNotificationsMuted,
              onChanged: (bool newValue) {
                provider.toggleNotificationMute(newValue);
              },
              secondary: Icon(provider.isNotificationsMuted ? Icons.notifications_off : Icons.notifications_active),
            ),
            const Divider(),

            Card(
              elevation: 8.0,
              margin: const EdgeInsets.only(bottom: 24.0),
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Create New Project',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: newProjectNameController,
                      decoration: const InputDecoration(
                        labelText: 'New Project Display Name',
                        hintText: 'e.g., My Personal Alerts',
                        border: OutlineInputBorder(),
                      ),
                      enabled: !_isCreatingProject, // Disable while loading
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _isCreatingProject
                            ? null // Disable button if loading
                            : () async {
                                setState(() {
                                  _isCreatingProject = true; // Start loading
                                });
                                try {
                                  final projectName = newProjectNameController.text.trim();
                                  await provider.createProject(context, projectName);
                                  newProjectNameController.clear();
                                } finally {
                                  setState(() {
                                    _isCreatingProject = false; // Stop loading, regardless of success/failure
                                  });
                                }
                              },
                        child: _isCreatingProject
                            ? const SizedBox(
                                height: 20.0,
                                width: 20.0,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.0,
                                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                                ),
                              )
                            : const Text('Create'), // Show spinner or text
                      ),
                    ),
                  ],
                ),
              ),
            ),

            Card(
              elevation: 8.0,
              margin: const EdgeInsets.only(bottom: 24.0),
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Join Existing Project',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: joinProjectIdController,
                      decoration: const InputDecoration(
                        labelText: 'Enter Project ID',
                        hintText: 'e.g., a1b2c3d4',
                        border: OutlineInputBorder(),
                      ),
                      enabled: !_isJoiningProject, // Disable while loading for the main UI
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _isJoiningProject ? null : () { // Disable button if loading
                          _showJoinProjectDialog(context);
                        },
                        child: _isJoiningProject
                            ? const SizedBox(
                                height: 20.0,
                                width: 20.0,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.0,
                                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                                ),
                              )
                            : const Text('Join'),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const Text(
              'Your Projects:',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            Expanded( // FIX: Expanded for ListView.builder in ProjectsPage to take remaining space
              child: ListView.builder(
                itemCount: provider.projects.length,
                itemBuilder: (context, index) {
                  final project = provider.projects[index];
                  final projectId = project['id']!;
                  final projectName = project['name']!;
                  final bool isCurrentlyLeaving = _leavingProjectIds.contains(projectId); // Check if this specific project is leaving

                  return Card(
                    margin: const EdgeInsets.symmetric(vertical: 8.0),
                    child: ListTile(
                      title: Text(projectName), // ListTile title handles its own overflow by wrapping
                      // Subtitle now includes the copy icon
                      subtitle: Row(
                        mainAxisSize: MainAxisSize.min, // Keep row tight
                        children: [
                          Expanded( // FIX: Expanded for Project ID text in subtitle
                            child: Text('ID: $projectId'),
                          ),
                          IconButton(
                            icon: const Icon(Icons.copy, size: 16),
                            onPressed: () {
                              _copyToClipboard(context, projectId, 'Project ID');
                            },
                            padding: EdgeInsets.zero, // Remove default padding
                            constraints: const BoxConstraints(), // Remove default constraints
                          ),
                        ],
                      ),
                      trailing: isCurrentlyLeaving
                          ? const SizedBox(
                              height: 24.0,
                              width: 24.0,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.0,
                              ),
                            )
                          : IconButton(
                              icon: const Icon(Icons.delete),
                              onPressed: () async {
                                setState(() {
                                  _leavingProjectIds.add(projectId); // Add to set when leaving starts
                                });
                                try {
                                  await provider.leaveProject(projectId);
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text('Left project: $projectName')),
                                  );
                                } finally {
                                  setState(() {
                                    _leavingProjectIds.remove(projectId); // Remove from set when done
                                  });
                                }
                              },
                            ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class UserPage extends StatelessWidget {
  const UserPage({super.key});

  // Helper function for copying
  void _copyToClipboard(BuildContext context, String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$label copied to clipboard!')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Consumer<NotificationProvider>(
        builder: (context, provider, child) {
          final userId = provider.userId ?? 'Loading...';
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const Icon(Icons.person, size: 80, color: Colors.deepPurple),
                  const SizedBox(height: 24),
                  Text(
                    'Your Unique App ID',
                    style: Theme.of(context).textTheme.headlineSmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12.0),
                    decoration: BoxDecoration(
                      color: Colors.grey[200],
                      borderRadius: BorderRadius.circular(8.0),
                      border: Border.all(color: Colors.grey[300]!),
                    ),
                    child: Row( // Wrap with Row to add copy icon
                      mainAxisSize: MainAxisSize.min, // To make the row only as wide as its children
                      children: [
                        Expanded( // FIX: Expanded for userId text to prevent overflow
                          child: SelectableText(
                            userId,
                            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: Colors.deepPurple.shade700,
                            ),
                            // TextAlign.center might look odd if text wraps; consider TextAlign.left
                            textAlign: TextAlign.center,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.copy, size: 20),
                          onPressed: () {
                            _copyToClipboard(context, userId, 'User ID');
                          },
                          // Make the button smaller and remove default padding
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'This ID uniquely identifies your app installation on this device.',
                    style: Theme.of(context).textTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'If you uninstall and reinstall the app, this ID will change.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
