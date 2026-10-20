// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/deal_scout"
import topbar from "../vendor/topbar"

function urlB64ToUint8Array(base64String) {
  const padding = '='.repeat((4 - (base64String.length % 4)) % 4);
  const base64 = (base64String + padding).replace(/-/g, '+').replace(/_/g, '/');
  const rawData = window.atob(base64);
  const outputArray = new Uint8Array(rawData.length);
  for (let i = 0; i < rawData.length; ++i) {
    outputArray[i] = rawData.charCodeAt(i);
  }
  return outputArray;
}

function detectDeviceName() {
  const ua = navigator.userAgent;
  if (/iPhone/.test(ua)) return 'Apple iPhone';
  if (/iPad/.test(ua)) return 'Apple iPad';
  if (/Android/.test(ua)) return 'Android Device';
  if (/Macintosh/.test(ua)) return 'Mac Computer';
  if (/Windows/.test(ua)) return 'Windows PC';
  if (/Linux/.test(ua)) return 'Linux Device';
  return 'Web Browser';
}

const PushManagerHook = {
  async mounted() {
    const isSupported = 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window;
    const isStandalone = window.matchMedia('(display-mode: standalone)').matches || window.navigator.standalone === true;
    const isIos = /iPad|iPhone|iPod/.test(navigator.userAgent) && !window.MSStream;

    let permission = isSupported ? Notification.permission : 'unsupported';
    let hasExistingSubscription = false;

    if (isSupported && permission === 'granted') {
      try {
        const reg = await navigator.serviceWorker.ready;
        const sub = await reg.pushManager.getSubscription();
        if (sub) {
          hasExistingSubscription = true;
        }
      } catch (e) {
        console.debug('Error checking subscription: ', e);
      }
    }

    this.pushEvent('push-status', {
      supported: isSupported,
      permission: permission,
      subscribed: hasExistingSubscription,
      is_standalone: isStandalone,
      is_ios: isIos,
    });

    this.handleEvent('request-push-subscription', async ({vapid_public_key}) => {
      if (!isSupported) {
        this.pushEvent('push-error', {message: 'Push notifications are not supported on this browser.'});
        return;
      }

      try {
        const perm = await Notification.requestPermission();
        if (perm !== 'granted') {
          this.pushEvent('push-permission-denied', {});
          return;
        }

        const reg = await navigator.serviceWorker.ready;
        let sub = await reg.pushManager.getSubscription();

        if (!sub) {
          const appServerKey = urlB64ToUint8Array(vapid_public_key);
          sub = await reg.pushManager.subscribe({
            userVisibleOnly: true,
            applicationServerKey: appServerKey,
          });
        }

        const subJson = sub.toJSON();

        this.pushEvent('save-push-subscription', {
          endpoint: sub.endpoint,
          p256dh: subJson.keys.p256dh,
          auth: subJson.keys.auth,
          user_agent: navigator.userAgent,
          device_name: detectDeviceName(),
        });
      } catch (err) {
        console.error('Failed to subscribe to Web Push: ', err);
        this.pushEvent('push-error', {message: err.message || 'Subscription failed.'});
      }
    });
  },
};

const AudioChimeHook = {
  mounted() {
    this.handleEvent("play-chime", () => {
      try {
        const AudioContext = window.AudioContext || window.webkitAudioContext
        if (!AudioContext) return

        const audioCtx = new AudioContext()
        const now = audioCtx.currentTime

        // Gentle Tone 1 (D5)
        const osc1 = audioCtx.createOscillator()
        const gain1 = audioCtx.createGain()
        osc1.type = "sine"
        osc1.frequency.setValueAtTime(587.33, now)
        gain1.gain.setValueAtTime(0.15, now)
        gain1.gain.exponentialRampToValueAtTime(0.001, now + 0.15)
        osc1.connect(gain1)
        gain1.connect(audioCtx.destination)
        osc1.start(now)
        osc1.stop(now + 0.15)

        // Gentle Tone 2 (A5)
        const osc2 = audioCtx.createOscillator()
        const gain2 = audioCtx.createGain()
        osc2.type = "sine"
        osc2.frequency.setValueAtTime(880.0, now + 0.1)
        gain2.gain.setValueAtTime(0.15, now + 0.1)
        gain2.gain.exponentialRampToValueAtTime(0.001, now + 0.3)
        osc2.connect(gain2)
        gain2.connect(audioCtx.destination)
        osc2.start(now + 0.1)
        osc2.stop(now + 0.3)
      } catch (e) {
        // Audio playback may require a user click first
        console.debug("Audio notification suppressed: ", e)
      }
    })
  }
}

async function detectAdBlocker() {
  // 1. Bait element test (detects cosmetic element hiding rules)
  const bait = document.createElement("div")
  bait.className = "adsbox ad-placement pub_300x250 text-ad text-ads banner-ad ad-zone ad_iframe"
  bait.setAttribute("aria-hidden", "true")
  bait.style.cssText = "position:absolute;left:-9999px;top:-9999px;width:1px;height:1px;pointer-events:none;"
  document.body.appendChild(bait)

  await new Promise(r => setTimeout(r, 60))

  const isHidden =
    bait.offsetParent === null ||
    bait.offsetHeight === 0 ||
    bait.offsetWidth === 0 ||
    window.getComputedStyle(bait).display === "none" ||
    window.getComputedStyle(bait).visibility === "hidden"

  bait.remove()

  if (isHidden) return true

  // 2. Network test (detects network-level filters: uBlock, AdGuard, Brave Shields, Pi-hole)
  try {
    await fetch(
      new Request("https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js", {
        method: "HEAD",
        mode: "no-cors",
        cache: "no-store",
      })
    )
    return false
  } catch (_err) {
    return true
  }
}

const AdBlockDetectorHook = {
  async mounted() {
    const banner = this.el
    const dismissBtn = banner.querySelector("#adblock-dismiss-btn")

    if (sessionStorage.getItem("dealscout_adblock_dismissed") === "true") {
      banner.hidden = true
      return
    }

    const isBlocked = await detectAdBlocker()

    if (isBlocked) {
      banner.hidden = false
      window.__dealscoutAdBlockDetected = true
      document.documentElement.classList.add("adblock-active")

      if (dismissBtn) {
        dismissBtn.addEventListener("click", () => {
          banner.hidden = true
          sessionStorage.setItem("dealscout_adblock_dismissed", "true")
        })
      }
    } else {
      banner.hidden = true
    }
  },
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {
    ...colocatedHooks,
    AudioChimeHook,
    PushManager: PushManagerHook,
    AdBlockDetector: AdBlockDetectorHook,
  },
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

// Register Progressive Web App Service Worker
if ("serviceWorker" in navigator) {
  window.addEventListener("load", () => {
    navigator.serviceWorker.register("/sw.js").catch((err) => {
      console.error("ServiceWorker registration failed: ", err)
    })
  })
}

