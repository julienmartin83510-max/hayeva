// Service Worker HAYEVA — Web Push de l'Espace Administration + secours
// hors-ligne "réseau d'abord" (voir fetch plus bas) : le site reste toujours
// à jour quand le réseau répond ; la copie locale ne sert qu'en cas de
// coupure réelle. CACHE_VERSION : à incrémenter pour purger les anciennes
// copies lors d'un déploiement (activate supprime tout autre cache).
var CACHE_VERSION = 'hayeva-v37';

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
// HAYEVA Pro (mode terrain) : toujours RÉSEAU D'ABORD — la version en ligne
// est servie dès que le réseau répond, et une copie est gardée. La copie
// n'est utilisée QUE si le réseau est réellement indisponible (vide
// sanitaire, garage...), pour que l'application s'ouvre quand même et que
// les saisies locales (brouillons d'intervention) restent accessibles.
// Jamais de cache pour Supabase / API (données toujours fraîches).
function sameOriginStatic(req){
  try {
    var u = new URL(req.url);
    return u.origin === self.location.origin && req.method === 'GET' &&
      (/\.(png|jpe?g|webp|svg|ico|json|css|js)$/i.test(u.pathname));
  } catch(e){ return false; }
}
self.addEventListener('fetch', function(event){
  var req = event.request;
  var isAppShell = false;
  if (req.mode === 'navigate'){
    try {
      var p = new URL(req.url).pathname;
      isAppShell = p === '/' || p === '/index.html' || p === '/app' || p.indexOf('/admin/interventions/') === 0;
    } catch(e){}
    if (!isAppShell) return;
  }
  if (isAppShell || sameOriginStatic(req)){
    event.respondWith(
      fetch(req).then(function(res){
        if (res && res.ok){
          var copy = res.clone();
          caches.open(CACHE_VERSION).then(function(c){ c.put(req.mode === 'navigate' ? './' : req, copy); }).catch(function(){});
        }
        return res;
      }).catch(function(){
        return caches.open(CACHE_VERSION).then(function(c){
          return c.match(req.mode === 'navigate' ? './' : req, { ignoreSearch: req.mode === 'navigate' });
        }).then(function(hit){ return hit || Response.error(); });
      })
    );
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
