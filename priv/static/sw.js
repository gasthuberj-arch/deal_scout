const CACHE_NAME = 'dealscout-shell-v4';
const OFFLINE_URL = '/offline.html';

const STATIC_ASSETS = [
  '/offline.html',
  '/manifest.webmanifest',
  '/images/icon-192.png',
  '/images/icon-512.png',
  '/images/badge-72.png',
  '/images/badge-96.png',
  '/favicon.ico'
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => {
      return cache.addAll(STATIC_ASSETS);
    })
  );
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((cacheNames) => {
      return Promise.all(
        cacheNames
          .filter((name) => name !== CACHE_NAME)
          .map((name) => caches.delete(name))
      );
    }).then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (event) => {
  const request = event.request;

  // Never intercept non-GET requests (e.g. form POSTs, LiveView longpoll POSTs)
  if (request.method !== 'GET') {
    return;
  }

  const url = new URL(request.url);

  // Never intercept cross-origin requests or Phoenix LiveView / socket endpoints
  if (
    url.origin !== self.location.origin ||
    url.pathname.startsWith('/live') ||
    url.pathname.startsWith('/socket') ||
    url.pathname.startsWith('/phoenix')
  ) {
    return;
  }

  // Handle navigation requests (page visits)
  if (request.mode === 'navigate') {
    event.respondWith(
      fetch(request).catch(() => {
        return caches.match(OFFLINE_URL);
      })
    );
    return;
  }

  // Network-first for CSS/JS assets so updates and dev changes are never stuck in stale SW cache
  if (url.pathname.startsWith('/assets/')) {
    event.respondWith(
      fetch(request).catch(() => caches.match(request))
    );
    return;
  }

  // Cache-first only for pre-cached static shell assets (icons, manifest, favicon)
  if (STATIC_ASSETS.includes(url.pathname)) {
    event.respondWith(
      caches.match(request).then((cachedResponse) => {
        if (cachedResponse) {
          return cachedResponse;
        }
        return fetch(request);
      })
    );
  }
});

// Push notification received
self.addEventListener('push', (event) => {
  let data = {};
  if (event.data) {
    try {
      data = event.data.json();
    } catch (e) {
      data = { title: 'DealScout Alarm', body: event.data.text() };
    }
  }

  const receivedAt = Date.now();
  const sentAt = data.sent_at || receivedAt;
  const clientDelayMs = Math.max(0, receivedAt - sentAt);

  const resolveUrl = (path) => {
    if (!path) return null;
    if (path.startsWith('http://') || path.startsWith('https://')) return path;
    return new URL(path, self.location.origin).href;
  };

  const title = data.title || 'DealScout Deal Alert';
  const iconUrl = resolveUrl(data.icon) || resolveUrl('/images/icon-192.png');
  const badgeUrl = resolveUrl(data.badge) || resolveUrl('/images/badge-72.png');

  const options = {
    body: data.body || 'New deal matching your rules!',
    icon: iconUrl,
    badge: badgeUrl,
    data: {
      url: data.url || '/matches',
      idealo_url: data.idealo_url || null,
      geizhals_url: data.geizhals_url || null
    },
    tag: data.tag || 'deal-alert',
    renotify: true,
    vibrate: [200, 100, 200],
    actions: data.actions || []
  };

  const promises = [self.registration.showNotification(title, options)];

  // Send delivery receipt back to DealScout if tracking_id is present
  if (data.tracking_id) {
    const receiptPromise = fetch('/api/push/receipt', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        tracking_id: data.tracking_id,
        received_at: receivedAt,
        client_delay_ms: clientDelayMs
      })
    }).catch((err) => {
      console.debug('[SW] Receipt ping failed:', err);
    });

    promises.push(receiptPromise);
  }

  event.waitUntil(Promise.all(promises));
});

// Handle token rotation / subscription invalidation from browser push service
self.addEventListener('pushsubscriptionchange', (event) => {
  event.waitUntil(
    self.registration.pushManager.getSubscription().then((sub) => {
      if (!sub) return null;
      // Notify active client windows so PushManagerHook re-registers
      return clients.matchAll({ type: 'window' }).then((clientList) => {
        clientList.forEach((client) => {
          client.postMessage({ type: 'PUSH_SUBSCRIPTION_CHANGED' });
        });
      });
    })
  );
});

// User clicked the notification
self.addEventListener('notificationclick', (event) => {
  event.notification.close();

  let targetUrl = (event.notification.data && event.notification.data.url) || '/matches';

  if (event.action === 'open_idealo' && event.notification.data && event.notification.data.idealo_url) {
    targetUrl = event.notification.data.idealo_url;
  }

  event.waitUntil(
    clients.matchAll({ type: 'window', includeUncontrolled: true }).then((clientList) => {
      for (const client of clientList) {
        if ('focus' in client) {
          if (client.url && client.url.includes(self.location.origin)) {
            client.navigate(targetUrl);
            return client.focus();
          }
        }
      }
      if (clients.openWindow) {
        return clients.openWindow(targetUrl);
      }
    })
  );
});
