if (!(self instanceof ServiceWorkerGlobalScope)) {
  throw new Error('wrong service worker global');
}
if (!(self instanceof WorkerGlobalScope) || !(self instanceof EventTarget)) {
  throw new Error('broken service worker prototype chain');
}
if (self.constructor.name !== 'ServiceWorkerGlobalScope') {
  throw new Error('wrong service worker constructor');
}
if (!(registration instanceof ServiceWorkerRegistration)) {
  throw new Error('missing service worker registration');
}
if (!(serviceWorker instanceof ServiceWorker)) {
  throw new Error('missing service worker handle');
}
if (serviceWorker.scriptURL !== location.href) {
  throw new Error('service worker script URL mismatch');
}

let installFinished = false;

addEventListener('install', (event) => {
  if (!(event instanceof ExtendableEvent) || event.type !== 'install') {
    throw new Error('install is not an ExtendableEvent');
  }
  event.waitUntil(new Promise((resolve) => {
    setTimeout(() => {
      installFinished = true;
      resolve();
    }, 5);
  }));
});

addEventListener('activate', (event) => {
  if (!(event instanceof ExtendableEvent) || !installFinished) {
    throw new Error('activate ran before install waitUntil settled');
  }
  event.waitUntil(Promise.resolve());
});

addEventListener('message', (event) => {
  if (!(event instanceof MessageEvent)) {
    throw new Error('message is not a MessageEvent');
  }
  if (!(event.source instanceof WindowClient) || !(event.source instanceof Client)) {
    throw new Error('message source is not a WindowClient');
  }
  event.source.postMessage({ echo: event.data, sourceType: event.source.type });
});
