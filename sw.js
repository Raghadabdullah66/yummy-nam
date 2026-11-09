self.addEventListener('install',function(){self.skipWaiting()});
self.addEventListener('activate',function(e){e.waitUntil(self.clients.claim())});

self.addEventListener('push',function(e){
 e.waitUntil(self.registration.showNotification('Yummy Nom',{
  body:'لا تنسى طلبك! Your order is still waiting in your cart.',
  icon:'./images/cheese-ramyun.png',
  tag:'yummy-nom-reminder',
  renotify:true
 }));
});

self.addEventListener('notificationclick',function(e){
 e.notification.close();
 e.waitUntil(self.clients.matchAll({type:'window',includeUncontrolled:true}).then(function(list){
  for(var i=0;i<list.length;i++){
   if('focus' in list[i])return list[i].focus();
  }
  return self.clients.openWindow('./');
 }));
});
