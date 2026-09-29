// Service Worker HAYEVA — gère uniquement les Web Push Notifications de
// l'Espace Administration (nouvelles réservations). Aucun cache offline
// n'est mis en place volontairement : le site reste toujours à jour à
// chaque chargement, sans risque de servir une version périmée du planning
// ou des tarifs.
//
// CACHE_VERSION : jamais utilisé pour mettre en cache quoi que ce soit
// aujourd'hui (voir ci-dessus) — posé ici pour qu'une éventuelle future
// stratégie de cache ait immédiatement un identifiant de version à faire
// évoluer, et que activate() ait un nom de cache "à soi" à protéger lors du
// nettoyage ci-dessous plutôt que de devoir le découvrir a posteriori.
var CACHE_VERSION = 'hayeva-v1';

self.addEventListener('install', function(event){
  self.skipWaiting();
});

self.addEventListener('activate', function(event){
  event.waitUntil(
    caches.keys().then(function(names){
      // Supprime tout cache d'une version précédente (aucun n'existe
      // normalement puisque ce service worker n'en crée aucun — filet de
      // sécurité si une version future en introduit un, pour ne jamais
      // laisser un iPhone conserver un ancien cache après déploiement).
      return Promise.all(names.filter(function(n){ return n !== CACHE_VERSION; }).map(function(n){ return caches.delete(n); }));
    }).then(function(){ return self.clients.claim(); })
  );
});

// Navigation (chargement de page/rechargement, y compris /admin/
// interventions/:id) : toujours réseau d'abord, jamais de cache — un iPhone
// ne doit jamais recharger un ancien index.html après un déploiement. Si le
// réseau échoue réellement (coupure), laisser passer l'erreur normale du
// navigateur plutôt que de servir un HTML périmé depuis un cache qui de
// toute façon n'existe pas ici.
self.addEventListener('fetch', function(event){
  if (event.request.mode === 'navigate'){
    event.respondWith(fetch(event.request));
  }
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
