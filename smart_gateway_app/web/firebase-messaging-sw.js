
// web/firebase-messaging-sw.js
importScripts('https://www.gstatic.com/firebasejs/9.22.1/firebase-app-compat.js');
importScripts('https://www.gstatic.com/firebasejs/9.22.1/firebase-messaging-compat.js');

firebase.initializeApp({
  apiKey: "<API_KEY>",
  authDomain: "rxmeet-3f5b6.firebaseapp.com",
  projectId: "rxmeet-3f5b6",
  messagingSenderId: "935659627808",
  appId: "1:935659627808:web:2177eff6c431c7eceb6345",
});

const messaging = firebase.messaging();

function stringifyData(obj) {
  const safe = {};
  if (!obj) return safe;
  Object.keys(obj).forEach(key => {
    try {
      const v = obj[key];
      safe[key] = (typeof v === 'string') ? v : JSON.stringify(v);
    } catch (e) {
      safe[key] = String(obj[key]);
    }
  });
  return safe;
}
// ensure new SW becomes active and controls pages immediately
self.addEventListener('install', (event) => {
  // activate immediately
  self.skipWaiting();
});
self.addEventListener('activate', (event) => {
  // claim clients so the SW controls open pages without a reload
  event.waitUntil(self.clients.claim());
});


messaging.onBackgroundMessage(function(payload) {
  console.log('[firebase-messaging-sw.js] Received background message', payload);

  const safeData = stringifyData(payload.data);

  const title = (payload.notification && payload.notification.title) || safeData.title || 'Incoming call';
  const body = (payload.notification && payload.notification.body) || safeData.body || 'Doctor is calling';

  const options = {
    body: body,
    data: safeData,
    tag: 'incoming-call',
    renotify: true,
  };

  // Show a visible notification (so background/closed works).
  self.registration.showNotification(title, options);

  // ALSO post a message to all open client windows so the page can react immediately.
  self.clients.matchAll({ includeUncontrolled: true, type: 'window' }).then(clientList => {
    clientList.forEach(client => {
      try {
        client.postMessage({ __fcm_from_sw: true, payload: safeData });
      } catch (err) {
        console.warn('SW->client postMessage failed', err);
      }
    });
  });

  return;
});

self.addEventListener('notificationclick', function(event) {
  const data = event.notification?.data || {};
  event.notification.close();
  event.waitUntil(
    clients.matchAll({ type: 'window', includeUncontrolled: true }).then(windowClients => {
      for (const client of windowClients) {
        // try to focus an existing client
        if (client.url && 'focus' in client) {
          client.postMessage({ __fcm_from_sw_click: true, payload: data });
          return client.focus();
        }
      }
      // or open a new one
      return clients.openWindow('/');
    })
  );
});
