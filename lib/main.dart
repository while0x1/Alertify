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
import 'package:url_launcher/url_launcher.dart';
import 'dart:ui';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:chart_sparkline/chart_sparkline.dart';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import 'firebase_options.dart';

import 'package:hive_flutter/hive_flutter.dart';


import 'models/mqtt_log.dart';

// Isar will generate this file



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

late Box<MqttLog> logBox;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  await Hive.initFlutter();

    // Register the blueprint you just built
    Hive.registerAdapter(MqttLogAdapter());

    // Open the database box
    logBox = await Hive.openBox<MqttLog>('mqtt_logs');

 // Change this line to point to your new drawable
 const AndroidInitializationSettings initializationSettingsAndroid =
     AndroidInitializationSettings('@drawable/ic_notification');

 const DarwinInitializationSettings initializationSettingsIOS =
     DarwinInitializationSettings();

 const InitializationSettings initializationSettings = InitializationSettings(
   android: initializationSettingsAndroid,
   iOS: initializationSettingsIOS,
 );

 await flutterLocalNotificationsPlugin.initialize(initializationSettings);



  final FirebaseMessaging messaging = FirebaseMessaging.instance;

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

  Future<void> _requestNotificationPermission() async {
      // 1. Request standard Android 13+ notification permission
      final status = await Permission.notification.request();

      if (status.isGranted) {
        print("Notification permission granted by user.");
      } else {
        print("Notification permission denied by user.");
      }

      // 2. Request FCM specific permissions (crucial for iOS and specific Android features)
      await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
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

  // --- NEW: Clear all local data on account deletion ---
    Future<void> clearAllLocalData() async {
      print('Starting local data wipe...');

      // 1. Unsubscribe from all project FCM topics first
      for (var project in projects) {
        try {
          await FirebaseMessaging.instance.unsubscribeFromTopic('project_${project['id']}');
          print('Successfully unsubscribed from deleted project: ${project['id']}');
        } catch (e) {
          print('Error unsubscribing from topic ${project['id']}: $e');
        }
      }

      // 2. Clear the physical storage on the device
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear(); // This completely wipes all Alertify data saved on the phone

      // 3. Reset all in-memory variables back to default
      notifications = [];
      projects = [];
      _deletedMessageIds = [];
      fcmToken = null;
      _userId = null;
      _isNotificationsMuted = false;

      // 4. Force the UI to refresh
      notifyListeners();
      print('Local data wipe complete.');
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

        await _requestNotificationPermission();

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
          await _requestNotificationPermission();

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

            Expanded(
              child: ListView.builder(
                itemCount: provider.projects.length,
                itemBuilder: (context, index) {
                  final project = provider.projects[index];
                  final projectId = project['id']!;
                  final projectName = project['name']!;
                  final bool isCurrentlyLeaving = _leavingProjectIds.contains(projectId);

                  return Card(
                    margin: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 4.0),
                    child: Padding(
                      padding: const EdgeInsets.all(16.0), // Standardizes the inner spacing
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // --- ROW 1: Title and Delete Button (Top Right aligned) ---
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Text(
                                  projectName,
                                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                                ),
                              ),
                              isCurrentlyLeaving
                                  ? const SizedBox(
                                      height: 24.0,
                                      width: 24.0,
                                      child: CircularProgressIndicator(strokeWidth: 2.0),
                                    )
                                  : SizedBox(
                                      // Wrapping in a SizedBox constrains the ripple effect and aligns it perfectly
                                      height: 24,
                                      width: 24,
                                      child: IconButton(
                                        padding: EdgeInsets.zero,
                                        icon: const Icon(Icons.delete, color: Colors.redAccent, size: 20),
                                        onPressed: () async {
                                          setState(() {
                                            _leavingProjectIds.add(projectId);
                                          });
                                          try {
                                            await provider.leaveProject(projectId);
                                            ScaffoldMessenger.of(context).showSnackBar(
                                              SnackBar(content: Text('Left project: $projectName')),
                                            );
                                          } finally {
                                            setState(() {
                                              _leavingProjectIds.remove(projectId);
                                            });
                                          }
                                        },
                                      ),
                                    ),
                            ],
                          ),
                          const SizedBox(height: 8),

                          // --- ROW 2: ID and Copy Icon (Tightly grouped) ---
                          Row(
                            children: [
                              Text('ID: $projectId', style: TextStyle(color: Colors.grey.shade700)),
                              const SizedBox(width: 4),
                              SizedBox(
                                height: 24,
                                width: 24,
                                child: IconButton(
                                  icon: const Icon(Icons.copy, size: 16, color: Colors.grey),
                                  onPressed: () {
                                    _copyToClipboard(context, projectId, 'Project ID');
                                  },
                                  padding: EdgeInsets.zero,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),

                          // --- ROW 3: Live Feed Button (Full width at the bottom) ---
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              icon: const Icon(Icons.sensors, size: 18),
                              label: const Text("Live Feed"),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.blue.shade50,
                                foregroundColor: Colors.blue.shade900,
                                elevation: 0,
                              ),
                              onPressed: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (context) => LiveFeedScreen(projectId: projectId),
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
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
// Ensure FASTAPI_BASE_URL is accessible here, or import it from your constants file.

class UserPage extends StatefulWidget {
  const UserPage({super.key});

  @override
  State<UserPage> createState() => _UserPageState();
}

class _UserPageState extends State<UserPage> {
  bool _isDeleting = false;

  /// Copies text to clipboard and shows a snackbar
  void _copyToClipboard(String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$label copied to clipboard!')),
    );
  }

  /// Safely launches external URLs using the url_launcher package
  Future<void> _launchURL(String urlString) async {
    final Uri url = Uri.parse(urlString);
    try {
      if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
        throw Exception('Could not launch $url');
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error opening link: $e')),
      );
    }
  }

  /// Handles the API call to delete the user data
  Future<void> _performDeleteUserData(String userId, NotificationProvider provider) async {
    setState(() => _isDeleting = true);

    try {
      final response = await http.post(
        Uri.parse('$FASTAPI_BASE_URL/delete-user-data'),
        headers: {
          'Content-Type': 'application/json',
          'X-User-Id': userId,
        },
      ).timeout(const Duration(seconds: 15));

      if (!mounted) return; // Crucial check after an async gap

      if (response.statusCode == 200) {
        // Here you would typically call a method on your provider to wipe SharedPreferences
        // e.g., await provider.clearAllLocalData();

        await provider.clearAllLocalData();

        ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Account and data successfully deleted.')),
        );

        // Optional: Navigate the user back to the loading screen or a "Goodbye" screen
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to delete data. Server code: ${response.statusCode}')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Network error. Please try again.')),
      );
    } finally {
      if (mounted) {
        setState(() => _isDeleting = false);
      }
    }
  }

  /// Displays the final confirmation dialog before deletion
  void _showDeleteConfirmDialog(String userId, NotificationProvider provider) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text("Final Warning"),
        content: const Text(
          "Are you sure? This cannot be undone. All project links, API keys, and alert history will be permanently wiped from our servers.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text("Cancel"),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(dialogContext); // Close the dialog first
              _performDeleteUserData(userId, provider); // Then execute the network call
            },
            child: const Text("DELETE", style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Consumer<NotificationProvider>(
        builder: (context, provider, child) {
          final userId = provider.userId ?? 'Loading...';

          return SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 32.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _buildProfileHeader(userId),
                  const SizedBox(height: 40),
                  _buildLegalSection(),
                  const SizedBox(height: 40),
                  _buildDangerZone(userId, provider),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // --- UI Builder Helper Methods ---

  Widget _buildProfileHeader(String userId) {
    return Column(
      children: [
        const Icon(Icons.person_outline, size: 80, color: Colors.deepPurple),
        const SizedBox(height: 16),
        Text(
          'Your App Identity',
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Text(
          'This ID and your Project code route alerts to your devices.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.grey[600]),
        ),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
          decoration: BoxDecoration(
            color: Colors.grey.shade100,
            borderRadius: BorderRadius.circular(12.0),
            border: Border.all(color: Colors.grey.shade300),
          ),
          child: Row(
            children: [
              Expanded(
                child: SelectableText(
                  userId,
                  style: const TextStyle(
                    fontFamily: 'monospace', // Monospace is great for UUIDs/IDs
                    fontWeight: FontWeight.w600,
                    color: Colors.deepPurple,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.copy_rounded, color: Colors.deepPurple),
                tooltip: 'Copy ID',
                onPressed: () => _copyToClipboard(userId, 'App ID'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildLegalSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Legal & Privacy',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: Colors.grey.shade200),
          ),
          child: ListTile(
            leading: const Icon(Icons.policy_outlined, color: Colors.blueGrey),
            title: const Text('Terms & Conditions'),
            subtitle: const Text('alertify.while0x1.com/terms'),
            trailing: const Icon(Icons.open_in_new_rounded, size: 20, color: Colors.grey),
            onTap: () => _launchURL('https://alertify.while0x1.com/terms'),
          ),
        ),
      ],
    );
  }

  Widget _buildDangerZone(String userId, NotificationProvider provider) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Danger Zone',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold, color: Colors.red.shade700),
        ),
        const SizedBox(height: 12),
        Card(
          color: Colors.red.shade50,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: Colors.red.shade200),
          ),
          child: Padding(
            padding: const EdgeInsets.all(20.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  "Delete your account and data. This action cannot be reversed.",
                  style: TextStyle(fontSize: 14, color: Colors.redAccent),
                ),
                const SizedBox(height: 20),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red.shade600,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  icon: _isDeleting
                      ? const SizedBox(
                          width: 20, height: 20,
                          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)
                        )
                      : const Icon(Icons.delete_forever_rounded),
                  label: Text(_isDeleting ? 'Deleting...' : 'Delete Account & Data'),
                  onPressed: _isDeleting ? null : () => _showDeleteConfirmDialog(userId, provider),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class LiveFeedScreen extends StatefulWidget {
  final String projectId;

  const LiveFeedScreen({Key? key, required this.projectId}) : super(key: key);


  @override
  State<LiveFeedScreen> createState() => _LiveFeedScreenState();


}

class _LiveFeedScreenState extends State<LiveFeedScreen> {
  String userTier = 'pro';

  MqttServerClient? _client;
  bool _isConnected = false;
  bool _isError = false;
  bool _isViewingAllowed = false; // Controls the blur
  int _secondsRemaining = 0;      // Shared timer for "Wait" and "View"
  Timer? _cycleTimer;
  static const int LIVE_MESSAGES = 500;

  Map<String, Map<String, dynamic>> _groupedData = {}; // Stores the latest JSON per UID
  Map<String, List<double>> _sparklineData = {};       // Stores the last 30 values per UID
  Map<String, bool> _isBlinking = {};                  // Controls the green flash
  List<String> _miscFeed = [];                         // The fallback for non-UID messages

  Future<void> _performRelayAction(String topic, String payload) async {
    if (_client == null || _client!.connectionStatus!.state != MqttConnectionState.connected) {
      if (kDebugMode) print("Cannot publish: MQTT not connected");
      return;
    }

    // Define the message
    final builder = MqttClientPayloadBuilder();
    builder.addString(payload);

    if (kDebugMode) {
      print("Publishing to $topic: $payload");
    }

    // Send it!
    _client!.publishMessage(
      topic,
      MqttQos.atLeastOnce,
      builder.payload!,
      retain: false,
    );

    // Success Feedback
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Command sent to $topic'), backgroundColor: Colors.green),
      );
    }
  }

Future<void> _clearProjectCache() async {
    try {
      // 1. Find all database keys that belong ONLY to this specific project
      final keysToDelete = logBox.values
          .where((log) => log.projectId == widget.projectId)
          .map((log) => log.key) // Hive uses an internal 'key' for deletion
          .toList();

      // 2. Delete them all from the hard drive instantly
      await logBox.deleteAll(keysToDelete);

      // 3. Clear the UI state so the screen empties immediately
      setState(() {
        _groupedData.clear();
        _sparklineData.clear();
        _miscFeed.clear();
      });

      // 4. Show the success message
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('History cleared for this project'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } catch (e) {
      if (kDebugMode) {
        print("Error clearing Hive cache: $e");
      }
    }
  }

    Future<void> _fetchUserTier(String userId) async {
        try {
          final response = await http.post(
            Uri.parse('https://alertify.while0x1.com/internal/mqtt-auth'),
            body: jsonEncode({
              'username': widget.projectId,
              'password': userId, // Or your specific secret
            }),
          );

          if (response.statusCode == 200) {
            final data = jsonDecode(response.body);
            final userProps = data['user_properties'] as Map<String, dynamic>?;

                setState(() {
                  userTier = userProps?['tier'] ?? 'free';
                });
                print("User Tier Verified via user_properties: $userTier");
              }
        } catch (e) {
          print("Tier verification failed: $e");
          setState(() => userTier = 'free');
        }
      }

      void _startTierCycle() {
        _cycleTimer?.cancel();

        // Phase 1: The Wait (Blurred)
        setState(() {
          _isViewingAllowed = false;
          _secondsRemaining = 6; // Wait 60 seconds
        });

        _cycleTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
          if (_secondsRemaining > 0) {
            setState(() => _secondsRemaining--);
          } else {
            timer.cancel();
            // Phase 2: The View (Unblurred)
            _startViewWindow();
          }
        });
      }

      void _startViewWindow() {
        setState(() {
          _isViewingAllowed = true;
          _secondsRemaining = 30; // View for 60 seconds
        });

        _cycleTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
          if (_secondsRemaining > 0) {
            setState(() => _secondsRemaining--);
          } else {
            timer.cancel();
            // Restart the cycle back to Blurred
            _startTierCycle();
          }
        });
      }

 Widget _buildGroupedCard(String uid) {
     final data = _groupedData[uid]!;
     final bool isBlinking = _isBlinking[uid] ?? false;
     final String name = data['name']?.toString() ?? 'Device: $uid';

     // 1. Save your awesome AnimatedContainer as a variable
     Widget cardContent = AnimatedContainer(
       duration: const Duration(milliseconds: 500), // Smooth fade out
       margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
       decoration: BoxDecoration(
         color: isBlinking ? Colors.green.shade100 : Colors.white,
         borderRadius: BorderRadius.circular(12),
         border: Border.all(
           color: isBlinking ? Colors.green.shade400 : Colors.grey.shade300,
           width: isBlinking ? 2 : 1
         ),
         boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 4, offset: Offset(0, 2))],
       ),
       child: Padding(
         padding: const EdgeInsets.all(12.0),
         child: Column(
           crossAxisAlignment: CrossAxisAlignment.start,
           children: [
             // Header: Name and Sparkline
             Row(
               mainAxisAlignment: MainAxisAlignment.spaceBetween,
               children: [
                 Text(name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.deepPurple)),

                 // Only draw graph if we have > 1 data point
                 if (_sparklineData[uid] != null && _sparklineData[uid]!.length > 1)
                   SizedBox(
                     width: 80,
                     height: 30,
                     child: Sparkline(
                       data: _sparklineData[uid]!,
                       lineColor: Colors.blue,
                       fillMode: FillMode.below,
                       fillColor: Colors.blue.withOpacity(0.2),
                       useCubicSmoothing: true,
                       cubicSmoothingFactor: 0.2, // Makes the line wavy instead of jagged
                     ),
                   ),
               ],
             ),
             const Divider(),
             // Re-use your existing smart payload, passing the raw JSON back in
             _buildSmartPayload(jsonEncode(data)),
           ],
         ),
       ),
     );

     // 2. Apply the Free Tier Paywall Blur
     // (Assuming userTier and _isBlurred are accessible variables in your state class)
     if (userTier == 'free' && !_isViewingAllowed) {
       return GestureDetector(
         onTap: () {
           // Optional: Show a toast when they tap a blurred card
           ScaffoldMessenger.of(context).showSnackBar(
             const SnackBar(
               content: Text('Upgrade to Pro to view live data!'),
               backgroundColor: Colors.orange,
               duration: Duration(seconds: 2),
             ),
           );
         },
         child: ImageFiltered(
           imageFilter: ImageFilter.blur(sigmaX: 5.0, sigmaY: 5.0),
         child: cardContent,

         ),
       );
     }

     // 3. Return normally for Pro users or during the "unblurred" cycle
     return InkWell(
           onTap: () => _showDeviceHistory(uid, name), // Trigger the history view
           borderRadius: BorderRadius.circular(12),
           child: cardContent,
         );
   }

  void _showPublishDialog(BuildContext context) {
    final topicController = TextEditingController(text: 'alertify/project/${widget.projectId}/cmd');
    final payloadController = TextEditingController(text: '{"uid": "manual_trigger", "value": 1}');

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text("Publish MQTT Message"),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: topicController,
                decoration: const InputDecoration(labelText: "Topic"),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: payloadController,
                decoration: const InputDecoration(labelText: "JSON Payload"),
                maxLines: 3,
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
            ElevatedButton(
              onPressed: () {
                // Assuming you built the _performRelayAction from our API discussion
                _performRelayAction(topicController.text, payloadController.text);
                Navigator.pop(context);
              },
              child: const Text("Send Command"),
            )
          ],
        );
      }
    );
  }



  // Inside class _LiveFeedScreenState
   Widget _buildSmartPayload(String payload) {
     try {
       // Trim to remove hidden whitespace/newlines from the broker
       final cleanPayload = payload.trim();
       final decoded = jsonDecode(cleanPayload);

       if (decoded is Map<String, dynamic>) {
         return Column(
           crossAxisAlignment: CrossAxisAlignment.start,
           mainAxisSize: MainAxisSize.min,
           children: decoded.entries.map((entry) {
             return Padding(
               padding: const EdgeInsets.only(bottom: 2.0),
               child: Row(
                 children: [
                   Text('${entry.key}: ', style: const TextStyle(fontWeight: FontWeight.bold)),
                   Expanded(child: Text(entry.value.toString())),
                 ],
               ),
             );
           }).toList(),
         );
       }
     } catch (e) {
       // If it's not JSON, it hits here and just shows raw text
     }
     return Text(payload);
   }



  @override
  void initState() {
    super.initState();
    _loadHistoryAndConnect();
     // Add this line

  }

  void _loadHistoryFromHive() {
    // Grab all logs for this specific project
    final projectLogs = logBox.values.where((log) => log.projectId == widget.projectId).toList();

    // Sort them by time so the sparkline draws left-to-right correctly
    projectLogs.sort((a, b) => a.timestamp.compareTo(b.timestamp));

    setState(() {
      for (var log in projectLogs) {
        if (log.uid != null) {
          // Restore the latest JSON payload for the card
          _groupedData[log.uid!] = jsonDecode(log.rawJson);

          // Restore the sparkline data
          if (log.numericValue != null) {
            _sparklineData.putIfAbsent(log.uid!, () => []);
            _sparklineData[log.uid!]!.add(log.numericValue!);

            // Keep memory tight
            if (_sparklineData[log.uid!]!.length > 30) {
              _sparklineData[log.uid!]!.removeAt(0);
            }
          }
        }
        else {
                // If UID is null, it's a General Feed message!
                _miscFeed.insert(0, log.rawJson);
                if (_miscFeed.length > 50) _miscFeed.removeLast();
              }
      }
    });
  }

  Future<void> _loadHistoryAndConnect() async {
    // 1. Instantly load the last 50 messages from device memory
    // final prefs = await SharedPreferences.getInstance();
    // final history = prefs.getStringList('live_history_${widget.projectId}') ?? [];
    _loadHistoryFromHive();

    // 2. Fetch the UserId directly from the existing Provider
    final userId = Provider.of<NotificationProvider>(context, listen: false).userId;
    if (userId == null) {
      print("Cannot connect to MQTT: User ID is null");
      setState(() => _isError = true);
      return;
    }

    await _fetchUserTier(userId);

    if (userTier == 'free') {
        _startTierCycle();
    }

    // 3. Fire up the MQTT connection in the background
    _connectToEMQX(userId);
  }

  Future<void> _connectToEMQX(String userId) async {
    // Setup WSS Connection to your Nginx/EMQX broker
    _client = MqttServerClient.withPort(
        'wss://mqtt.while0x1.com/mqtt',
        'flutter_client_${widget.projectId}_${DateTime.now().millisecondsSinceEpoch}',
        443);

    _client!.useWebSocket = true;
    // _client!.secure = true; wss path ensures security
    _client!.websocketProtocols = ['mqtt'];
    _client!.keepAlivePeriod = 45;
    _client!.autoReconnect = true;

    _client!.logging(on: false); // Set to true if you need to debug WebSocket handshakes


    // Auth using the Project ID as username and User ID as password for FastAPI
    final connMess = MqttConnectMessage()
        .authenticateAs(widget.projectId, userId)
        .withClientIdentifier('flutter_${widget.projectId}')
        .startClean(); // Ensure a fresh session

    _client!.connectionMessage = connMess;

    _client!.onDisconnected = () {
          print('MQTT Disconnected');
          if (mounted) {
            setState(() {
              _isConnected = false;
              _isError = true;// Turns cloud grey/red
            });
          }
        };
    _client!.onConnected = () {
          print('MQTT Connected');
          if (mounted) {
            setState(() {
              _isConnected = true; // Turns cloud green
              _isError = false;
            });
          }
        };

        _client!.onAutoReconnect = () {
          print('MQTT Auto-reconnecting...');
          if (mounted) {
            setState(() {
               // Optional: You could add a bool _isReconnecting to show a spinner!
              _isConnected = false;
            });
          }
        };
        // ---

    try {
      print('Connecting to EMQX via WebSockets...');
      await _client!.connect();
    } catch (e) {
      print('MQTT Exception: $e');
      _client!.disconnect();
      if (mounted) setState(() => _isError = true);
      return;
    }

    if (_client!.connectionStatus!.state == MqttConnectionState.connected) {
      print('MQTT Connected successfully!');
      if (mounted) {
        setState(() => _isConnected = true);
      }

      final topic = 'alertify/project/${widget.projectId}/live';
      _client!.subscribe(topic, MqttQos.atMostOnce);

      // Listen for incoming live data
      _client!.updates!.listen((List<MqttReceivedMessage<MqttMessage>> c) {
        final MqttPublishMessage recMess = c[0].payload as MqttPublishMessage;
        final String pt = MqttPublishPayload.bytesToStringAsString(recMess.payload.message);
        //_handleNewMessage(pt);
        _processIncomingMessage(pt);
      });
    } else {
      print('MQTT Connection failed. Status: ${_client!.connectionStatus!.state}');
      if (mounted) setState(() => _isError = true);
    }
  }

 void _processIncomingMessage(String payload) {
     try {
       final decoded = jsonDecode(payload.trim());

       // Sniff for a 'uid'
       if (decoded is Map<String, dynamic> && decoded.containsKey('uid')) {
         final String uid = decoded['uid'].toString();

         // 1. Define and extract the numeric value safely in the correct scope
         double? numericVal;
         if (decoded['value'] != null && decoded['value'] is num) {
            numericVal = (decoded['value'] as num).toDouble();
         }

         // 2. Update the UI State
         setState(() {
           _groupedData[uid] = decoded;
           _isBlinking[uid] = true;

           if (numericVal != null) {
             _sparklineData.putIfAbsent(uid, () => []);
             _sparklineData[uid]!.add(numericVal!);

             // Keep only the last 30 points to save memory in the live view
             if (_sparklineData[uid]!.length > 30) {
               _sparklineData[uid]!.removeAt(0);
             }
           }
         });

         // Turn off the blink effect after 400ms
         Future.delayed(const Duration(milliseconds: 400), () {
           if (mounted) setState(() => _isBlinking[uid] = false);
         });

         // 3. Save to the Hive Database
         final newLog = MqttLog()
           ..uid = uid
           ..name = decoded['name']?.toString()
           ..numericValue = numericVal  // <--- This now correctly references the variable above
           ..rawJson = payload
           ..timestamp = DateTime.now()
           ..projectId = widget.projectId;

         logBox.add(newLog);

       } else {
         // It's JSON, but has no UID. Send to Misc.
         _addToMiscFeed(payload);
         final miscLog = MqttLog()
             ..uid = null // No UID means it belongs to the General Feed
             ..rawJson = payload
             ..timestamp = DateTime.now()
             ..projectId = widget.projectId;

           logBox.add(miscLog);
       }
     } catch (e) {
       // Not JSON at all. Send to Misc.
       _addToMiscFeed(payload);
       final miscLog = MqttLog()
               ..uid = null
               ..rawJson = payload
               ..timestamp = DateTime.now()
               ..projectId = widget.projectId;

             logBox.add(miscLog);
     }
   }

  void _addToMiscFeed(String payload) {
    setState(() {
      _miscFeed.insert(0, payload);
      if (_miscFeed.length > 50) _miscFeed.removeLast(); // Keep misc feed lean
    });
  }

//  Future<void> _handleNewMessage(String payload) async {

  void _showDeviceHistory(String uid, String deviceName) {
      // 1. Query Hive instantly for this specific device
      final history = logBox.values
          .where((log) => log.uid == uid && log.projectId == widget.projectId)
          .toList();

      // Sort newest to oldest for the timeline list
      history.sort((a, b) => b.timestamp.compareTo(a.timestamp));

      // Grab the last 100 points so the UI doesn't lag if they have left it running for days
      final displayHistory = history.take(100).toList();

      // Extract just the numbers for the big top chart (needs to be oldest to newest)
      final List<double> chartData = displayHistory
          .map((e) => e.numericValue)
          .where((val) => val != null)
          .cast<double>()
          .toList()
          .reversed
          .toList();

      showModalBottomSheet(
        context: context,
        isScrollControlled: true, // Allows it to take up more than half the screen
        backgroundColor: Colors.transparent, // We make the background transparent so we can use a custom rounded container
        builder: (context) {
          return DraggableScrollableSheet(
            initialChildSize: 0.65, // Starts at 65% of the screen
            minChildSize: 0.4,
            maxChildSize: 0.9, // Can be dragged up to 90% of the screen
            builder: (_, controller) {
              return Container(
                decoration: const BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                  boxShadow: [BoxShadow(blurRadius: 10, color: Colors.black26)],
                ),
                child: Column(
                  children: [
                    // --- Drag Handle ---
                    Center(
                      child: Container(
                        margin: const EdgeInsets.only(top: 12, bottom: 16),
                        height: 5,
                        width: 50,
                        decoration: BoxDecoration(
                          color: Colors.grey.shade300,
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),

                    // --- Header ---
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            deviceName,
                            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.deepPurple),
                          ),
                          Chip(
                            label: Text('${displayHistory.length} records'),
                            backgroundColor: Colors.deepPurple.shade50,
                          )
                        ],
                      ),
                    ),
                    const Divider(height: 30),

                    // --- Big Historical Chart ---
                    if (chartData.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                        child: SizedBox(
                          height: 100,
                          width: double.infinity,
                          child: Sparkline(
                            data: chartData,
                            lineColor: Colors.deepPurple,
                            fillMode: FillMode.below,
                            fillColor: Colors.deepPurple.withOpacity(0.1),
                            lineWidth: 3,
                            useCubicSmoothing: true,
                            cubicSmoothingFactor: 0.2,
                          ),
                        ),
                      ),

                    // --- The Timeline List ---
                    Expanded(
                      child: ListView.builder(
                        controller: controller, // Connects the list scroll to the bottom sheet drag
                        itemCount: displayHistory.length,
                        itemBuilder: (context, index) {
                          final log = displayHistory[index];
                          // Format the timestamp nicely (e.g. 14:32:05)
                          final timeString = "${log.timestamp.hour.toString().padLeft(2, '0')}:"
                                             "${log.timestamp.minute.toString().padLeft(2, '0')}:"
                                             "${log.timestamp.second.toString().padLeft(2, '0')}";

                          return ListTile(
                            leading: CircleAvatar(
                              backgroundColor: Colors.grey.shade100,
                              child: Icon(Icons.history, color: Colors.grey.shade600, size: 18),
                            ),
                            title: Text(
                              log.numericValue != null ? "Value: ${log.numericValue}" : "Status Update",
                              style: const TextStyle(fontWeight: FontWeight.bold),
                            ),
                            subtitle: Text(
                            log.name ?? "System Event",
                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: Colors.grey.shade800),
                            ),
                            trailing: Text(
                              timeString,
                              style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.deepPurple),
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
  @override
  void dispose() {
    _cycleTimer?.cancel();
    // CRITICAL: Prevent ghost connections on the OCI instance when user swipes back
    if (_client != null && _client!.connectionStatus?.state == MqttConnectionState.connected) {
      print('Disconnecting MQTT Client...');

      _client!.onDisconnected = null;
      _client!.onConnected = null;
      _client!.onSubscribed = null;

      _client!.disconnect();

    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
          backgroundColor: Colors.grey.shade100,
          appBar: AppBar(
            title: const Text('Live Feed & Control'),
            backgroundColor: Colors.deepPurple.shade700,
          ),

          // THE FAB GOES RIGHT HERE. NOWHERE ELSE.
          floatingActionButton: FloatingActionButton(
            onPressed: () => _showPublishDialog(context),
            backgroundColor: Colors.deepPurple,
            child: const Icon(Icons.send, color: Colors.white),
          ),
      body: Column(
        children: [
  // --- ROW: Title and Clear Button ---
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text("Live MQTT Data", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                    TextButton.icon(
                      onPressed: _clearProjectCache,
                      icon: const Icon(Icons.delete_sweep, color: Colors.redAccent),
                      label: const Text("Clear Cache", style: TextStyle(color: Colors.redAccent)),
                    ),
                  ],
                ),
              ),
           if (userTier == 'free')
             Container(
               width: double.infinity,
               color: _isViewingAllowed ? Colors.green.shade100 : Colors.orange.shade100,
               padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
               child: Row(
                 children: [
                   Icon(
                     _isViewingAllowed ? Icons.visibility : Icons.visibility_off,
                     size: 18,
                     color: _isViewingAllowed ? Colors.green : Colors.orange,
                   ),
                   const SizedBox(width: 8),
                   Expanded(
                     child: Text(
                       _isViewingAllowed
                         ? "Free Window Active: Log visibility ends in ${_secondsRemaining}s"
                         : "Free Tier: Data blurred. Unlocking in ${_secondsRemaining}s",
                       style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                     ),
                   ),
                 ],
               ),
             ),

            Expanded(
              child: (_groupedData.isEmpty && _miscFeed.isEmpty)
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _isError
                              ? const Icon(Icons.error_outline, color: Colors.red, size: 48)
                              : const CircularProgressIndicator(),
                          const SizedBox(height: 16),
                          Text(
                            _isError ? "Connection failed." : "Waiting for MQTT data...",
                            style: const TextStyle(color: Colors.grey),
                          ),
                        ],
                      ),
                    )
                  : CustomScrollView(
                      slivers: [
                        // --- SECTION 1: The Grouped SCADA Dashboard ---
                        if (_groupedData.isNotEmpty)
                          SliverPadding(
                            padding: const EdgeInsets.all(8.0),
                            sliver: SliverList(
                              delegate: SliverChildBuilderDelegate(
                                (context, index) {
                                  String uid = _groupedData.keys.elementAt(index);
                                  return _buildGroupedCard(uid);
                                },
                                childCount: _groupedData.length,
                              ),
                            ),
                          ),

                        // --- SECTION 2: General Feed Header ---
                        if (_miscFeed.isNotEmpty)
                          const SliverToBoxAdapter(
                            child: Padding(
                              padding: EdgeInsets.only(left: 16.0, top: 24.0, bottom: 8.0),
                              child: Text("GENERAL FEED", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey, letterSpacing: 1.2)),
                            ),
                          ),

                        // --- SECTION 3: The Misc Messages ---
                                    if (_miscFeed.isNotEmpty)
                                      SliverList(
                                        delegate: SliverChildBuilderDelegate(
                                          (context, index) {

                                            // 1. Create the clickable card
                                            Widget miscCard = GestureDetector(
                                              onTap: () {
                                                // SECURE THE POPUP: Don't show data if they are currently blurred!
                                                if (userTier == 'free' && !_isViewingAllowed) {
                                                  ScaffoldMessenger.of(context).showSnackBar(
                                                    SnackBar(
                                                      content: Text('Live view unlocks in $_secondsRemaining seconds! Upgrade to Pro to bypass.'),
                                                      backgroundColor: Colors.orange,
                                                      duration: const Duration(seconds: 2),
                                                    ),
                                                  );
                                                  return; // Stop here, don't open the dialog
                                                }

                                                // Pro User (or active view window): Show the full raw text
                                                showDialog(
                                                  context: context,
                                                  builder: (context) => AlertDialog(
                                                    title: const Text("Raw Log Details", style: TextStyle(color: Colors.deepPurple)),
                                                    content: SingleChildScrollView(
                                                      child: Text(_miscFeed[index], style: const TextStyle(fontFamily: 'monospace')),
                                                    ),
                                                    actions: [
                                                      TextButton(
                                                        onPressed: () => Navigator.pop(context),
                                                        child: const Text("Close"),
                                                      )
                                                    ],
                                                  ),
                                                );
                                              },
                                              child: Card(
                                                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                                                color: Colors.grey.shade50,
                                                child: ListTile(
                                                  leading: const Icon(Icons.code, color: Colors.grey),
                                                  subtitle: Text(
                                                    _miscFeed[index],
                                                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                                                    maxLines: 2, // Truncates the text
                                                    overflow: TextOverflow.ellipsis,
                                                  ),
                                                ),
                                              ),
                                            );

                                            // 2. Apply the Visual Blur Layer
                                            if (userTier == 'free' && !_isViewingAllowed) {
                                              return ImageFiltered(
                                                imageFilter: ImageFilter.blur(sigmaX: 5.0, sigmaY: 5.0),
                                                child: miscCard,
                                              );
                                            }

                                            // 3. Return normally
                                            return miscCard;
                                          },
                                          childCount: _miscFeed.length,
                                        ),
                                      ),
                      ],
                    ),
            ),


          // The Content (Spinner or Data List)

        ],
      ),
    );
  }
}
