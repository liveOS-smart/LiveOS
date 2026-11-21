self.addEventListener("install",event=>{
  event.waitUntil(self.skipWaiting());
});

self.addEventListener("activate",event=>{
  event.waitUntil(self.clients.claim());
});

self.addEventListener("notificationclick",event=>{
  event.notification.close();
  const rawUrl=event.notification.data&&event.notification.data.url?event.notification.data.url:"./";
  const target=new URL(rawUrl,self.location.href);
  const safeUrl=target.origin===self.location.origin?target.href:new URL("./",self.location.href).href;
  event.waitUntil((async()=>{
    const clientsList=await self.clients.matchAll({type:"window",includeUncontrolled:true});
    for(const client of clientsList){
      if(client.url.startsWith(self.location.origin)){
        await client.focus();
        if("navigate" in client)await client.navigate(safeUrl);
        return;
      }
    }
    await self.clients.openWindow(safeUrl);
  })());
});

self.addEventListener("push",event=>{
  let payload={};
  try{payload=event.data?event.data.json():{};}catch(_){
    payload={body:event.data?event.data.text():"Du hast eine neue Erinnerung."};
  }
  const title=typeof payload.title==="string"?payload.title:"LiveOS";
  const options={
    body:typeof payload.body==="string"?payload.body:"Du hast eine neue Erinnerung.",
    icon:"./assets/liveos-icon-192.png?v=liveos-v3",
    badge:"./assets/liveos-icon-192.png?v=liveos-v3",
    tag:typeof payload.tag==="string"?payload.tag:"liveos-push",
    data:{url:typeof payload.url==="string"?payload.url:"./"}
  };
  event.waitUntil(self.registration.showNotification(title,options));
});
