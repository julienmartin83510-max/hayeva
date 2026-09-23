// Service Worker HAYEVA — gère uniquement les Web Push Notifications de
// l'Espace Administration (nouvelles réservations). Aucun cache offline
// n'est mis en place volontairement : le site reste toujours à jour à
// chaque chargement, sans risque de servir une version périmée du planning
// ou des tarifs.
self.addEventListener('install', function(event){
  self.skipWaiting();
});

self.addEventListener('activate', function(event){
  event.waitUntil(self.clients.claim());
});

self.addEventListener('push', function(event){
  var data = {};
  try { data = event.data ? event.data.json() : {}; } catch (e) { data = {}; }
  var title = data.title || 'HAYEVA';
  var options = {
    body: data.body || '',
    icon: 'images/pwa/icon-192.png',
    badge: 'images/pwa/icon-192.png',
    data: { url: data.url || './#espacePro' },
    tag: data.bookingId ? ('hayeva-booking-' + data.bookingId) : undefined
  };
  event.waitUntil(self.registration.showNotification(title, options));
});

// Appui sur la notification : ramène au premier onglet HAYEVA déjà ouvert
// (navigué vers la demande concernée) plutôt que d'en ouvrir un nouveau à
// chaque fois, sinon ouvre un nouvel onglet si aucun n'est déjà ouvert.
self.addEventListener('notificationclick', function(event){
  event.notification.close();
  var url = (event.notification.data && event.notification.data.url) || './#espacePro';
  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(function(clientsArr){
      for (var i = 0; i < clientsArr.length; i++){
        var c = clientsArr[i];
        if ('focus' in c){
          if ('navigate' in c) c.navigate(url);
          return c.focus();
        }
      }
      if (self.clients.openWindow) return self.clients.openWindow(url);
    })
  );
});
