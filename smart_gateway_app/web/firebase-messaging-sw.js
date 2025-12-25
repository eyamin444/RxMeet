// web/firebase-messaging-sw.js
importScripts('https://www.gstatic.com/firebasejs/9.22.1/firebase-app-compat.js');
importScripts('https://www.gstatic.com/firebasejs/9.22.1/firebase-messaging-compat.js');

// IMPORTANT: copy your web config from lib/firebase_options.dart (web section)
const firebaseConfig = {
  apiKey: "<YOUR_WEB_apiKey>",
  authDomain: "<...>",
  projectId: "<YOUR_PROJECT_ID>",
  storageBucket: "<...>",
  messagingSenderId: "<...>",
  appId: "<...>",
  measurementId: "<...>"
};

// Initialize
firebase.initializeApp(firebaseConfig);
const messaging = firebase.messaging();

// Background message handler
messaging.onBackgroundMessage(function(payload) {
  console.log('[firebase-messaging-sw.js] Received background message ', payload);
  const data = payload.data || {};
  const title = (payload.notification && payload.notification.title) || data.title || data.doctor_name || 'Incoming call';
  const options = {
    body: (payload.notification && payload.notification.body) || data.body || 'Tap to open',
    data: data,
    renotify: true,
    requireInteraction: true, // keep notification visible
    tag: 'incoming-call-' + (data.appointment_id || Date.now())
  };
  // show notification
  self.registration.showNotification(title, options);
});

// notification click
self.addEventListener('notificationclick', function(event) {
  event.notification.close();
  const data = event.notification.data || {};
  const urlToOpen = data.url || '/' ;
  event.waitUntil(clients.openWindow(urlToOpen));
});
