# Stealth

How this fork presents itself to a server, what you have to configure, and
where it still differs from Chrome. Everything here was measured against
Google Chrome 151 and Chrome for Testing 151 on the same machine and exit IP;
the captures and the instruments live in `../browser-research/`.

Read [What this does not do](#what-this-does-not-do) before relying on any of
it.

---

## The short version

```bash
# Minimum viable stealth run through a proxy.
lightpanda fetch \
  --http-proxy "$PROXY" \
  --fingerprint-region auto \
  --wait-until networkidle --wait-ms 30000 \
  --dump html "$URL"
```

Four things matter and three of them are easy to get wrong:

1. **`--fingerprint-region auto`** whenever `--http-proxy` is set. Without it
   the clock and the packets tell different stories.
2. **`--wait-ms` is a timeout, not a delay.** The 5 s default silently
   truncates proxied page loads. See [Waiting](#waiting).
3. **`LIGHTPANDA_DISABLE_TELEMETRY=true`**, or every process phones home. See
   [Outbound connections](#outbound-connections-you-did-not-ask-for).
4. Pin `--fingerprint-seed` when a session has to keep one identity.

---

## Identity: machines and regions

The unit of randomness is a **whole machine**, never an individual field.
Seven real configurations, 54 regions.

```bash
lightpanda fetch --fingerprint-list      # names for both
```

```
macbook-pro-14-m2pro   1512x982   10 cores  16GB  Apple M2 Pro
windows-1080p-nvidia   1920x1080  16 cores   8GB  NVIDIA RTX 3060
...
```

| flag | effect |
|---|---|
| `--fingerprint <name>` | pin the machine (UA platform, screen, cores, memory, GPU strings) |
| `--fingerprint-region <name>` | pin the locale (time zone, `navigator.language`, `Accept-Language`) |
| `--fingerprint-region auto` | resolve the proxy exit IP's country and pick the matching region |
| `--fingerprint-seed <int>` | draw both deterministically; logged at startup so a run repeats |

**Why whole machines.** Randomising fields independently produces machines
that do not exist — 10 cores with an Intel UHD 620, 30-bit colour on Windows,
2× DPR on a 1366×768 panel. CreepJS scores the internal contradiction, not the
values, so per-field randomisation is *worse* than one hardcoded profile. If
you add a profile, copy every field from one real device.

**Region must follow the exit.** A machine claiming `Europe/Bucharest` behind
a US exit is a contradiction visible without any JavaScript. `auto` is the
default when `--http-proxy` is set; set it explicitly if you are proxying by
another means.

**Do not cross operating systems.** The machine profiles include Windows
configurations and every *declared* surface follows them correctly — UA,
`navigator.platform` (`Win32`), the UA-CH block (`platform: Windows`,
`platformVersion: 15.0.0`, `architecture: x86`), screen geometry with a
correct 48 px taskbar inset, and an ANGLE D3D11 GPU string. But **font
availability is read from the host**, not the profile. Running
`--fingerprint windows-1080p-nvidia` on macOS, measured with
`FontFace(..., 'local(...)')`:

| probed | result |
|---|---|
| Segoe UI, Calibri, Cambria, Consolas, MS Gothic | all **absent** |
| Helvetica Neue, Menlo, Geneva, Lucida Grande, Skia | all **present** |

A machine claiming Windows with no Segoe UI and a full Apple font set does not
exist, and local-font enumeration is a standard fingerprinting technique. Use
profiles that match the host OS until the font database is driven by the
profile rather than by CoreText.

**Pin the seed to keep an identity.** A cookie jar earned under one identity
should be replayed under the same one. The seed is logged every run:

```
INFO app: fingerprint profile machine=macbook-pro-14-m2pro region=ro-en-gb seed=10651907526303499460
```

---

## Network layer

This is handled for you — no flags — but it is the part that decides most
challenges, so it is worth knowing what is there. All of it is verified
byte-identical to Chrome 151:

- **TLS ClientHello.** JA4 `t13d1518h2_8daaf6152771_4980c97edce0`: same cipher
  list *in order*, same extensions including `trust_anchors` (0xca34) and the
  unregistered 0x12e0 Chrome sends, same groups including the post-quantum
  X25519MLKEM768, same 1263-byte key share, same signature algorithms
  including the three ML-DSA code points, same ECH padding buckets
  {186, 218, 250, 282}.
- **HTTP/2.** SETTINGS, the 15663105 WINDOW_UPDATE, pseudo-header order
  `m,a,s,p`, and the HEADERS `PRIORITY` flag with exclusive dependency on
  stream 0 at weight 256. HPACK encoding matches too.
- **Headers.** 25 headers to Google origins in Chrome's order, including the
  `x-browser-*`/`x-client-data` block and the high-entropy client hints that
  Chrome's Accept-CH preload sends even on a cold fresh-profile request.

These come from build-time patches to vendored libraries —
`tools/boringssl_*`, `tools/curl_h2_patch.zig`,
`tools/nghttp2_chrome_patch.zig`. Each is anchored on exact source text and
**fails the build** if the vendored library moves, which is deliberate: a
dependency bump should stop and make someone re-read the diff rather than
quietly start emitting curl's fingerprint again.

### Known network gap

`accept-encoding` is `gzip, deflate, br` where Chrome sends
`gzip, deflate, br, zstd`. Advertising zstd without vendoring a decoder would
break real responses, so it is deliberately absent until that lands.

---

## Waiting

**`--wait-ms` is the hard deadline for the whole fetch. `--wait-until` only
decides what lets you stop early.** They share one budget.

The default is 5000 ms. Over a residential proxy that is frequently not enough
to receive the response at all, and when the budget expires **the page is
dumped as-is with exit code 0** — you get `<!DOCTYPE html>` and nothing else,
indistinguishable from a genuinely empty page.

Raising it costs nothing. Measured on `example.com`:

```
--wait-until networkidle --wait-ms 26000   ->  returned in 0.28s
```

Use 20–30 s whenever proxied.

| flag | meaning |
|---|---|
| `--wait-until load` | default; document load event |
| `--wait-until networkidle` | network quiescent — what you usually want |
| `--wait-until done` | rides the `--wait-ms` cap on pages with background activity |
| `--wait-selector <q>` / `--wait-script <expr>` | wait for a condition; these *do* raise `error.Timeout` |

---

## Subresources

Nothing but the document is fetched by default. Detectors look at the request
graph, and a client that pulls one document and stops does not look like a
browser:

```bash
--load-resources iframe --load-resources worker \
--load-resources image --load-resources stylesheet
```

`worker` matters more than it looks: reCAPTCHA loads a web worker and reads
`navigator.userAgent`/`userAgentData` inside it, comparing against the page —
a window-vs-worker consistency check. Without `--load-resources worker` the
worker never runs, which is itself anomalous.

**Trap:** worker scripts need `--wait-until networkidle`. With the default
wait the worker is constructed and its script is never fetched, silently.

---

## Outbound connections you did not ask for

Two of four connections on a typical run go somewhere the page did not ask
for:

```
www.google.com          the page
www.gstatic.com         the page
telemetry.lightpanda.io  <-- us
www.cloudflare.com       <-- geo lookup for --fingerprint-region auto
```

```bash
export LIGHTPANDA_DISABLE_TELEMETRY=true
```

Set it. A browser sold on stealth should not be the noisiest thing in your
egress logs, and the connection is trivially correlatable.

`www.cloudflare.com` is the exit-IP country lookup behind
`--fingerprint-region auto`; pin the region explicitly to avoid it.

---

## Cookies

```bash
--cookie-jar out.json      # save on exit
--cookie in.json           # load (read-only)
```

Operationally, from measurements in `../browser-research/`:

- A Google jar is **bound to the country it was minted in**. Any IP in that
  country works; no other country does. Earn and consume in the same country.
- The jar is **not** bound to the fingerprint that earned it. Pinning is for
  reproducibility, not correctness.
- Mint and consume on the **same provider + country pool**. Cross-provider
  inside one country is a gamble.
- Proxy country labels lie. Verify with `cdn-cgi/trace` *through the proxy*
  before attributing any result to a country.

---

## Verifying a change

Do not trust a single run, and never read a block as a fingerprint bug without
a control:

**Always pair with a real Chrome on the same exit, minutes apart.** Exit
reputation is real — Chrome gets blocked on burned IPs too — so a `/sorry`
means nothing on its own.

```bash
# What are we actually sending?
python3 ../browser-research/_tools/chcap.py 8899 out.json   # ClientHello via CONNECT proxy
python3 ../browser-research/_tools/ja4.py out.json          # JA4 from raw bytes
python3 ../browser-research/_tools/h2cap.py LP 8443         # raw HTTP/2 frames

# Which APIs did the page touch, and which did it look for and not find?
lightpanda fetch --trace-webapi ... 2>trace.log
grep 'missing web api' trace.log
```

`--trace-webapi` logs first access and call count per API member per context,
and logs *absent* members too. It is the only honest way to prioritise
compatibility work: point it at a corpus and rank by what is actually read.

**A missing-API probe is not evidence of a gap.** Of 43 such probes on a
Google run, 41 were correct absences — including `navigator.cookieDeprecationLabel`,
which Chrome does not have either, and `$cdc_asdjflasutopfhvcZLmcfl_`, which is
ChromeDriver's injection variable. Implementing those would make you *more*
detectable. Check against a real Chrome before adding anything.

---

## What this does not do

Stated plainly so it is not mis-sold.

**It does not clear Google's SERP gate.** Google decides on the first request,
before any JavaScript runs. Every byte-level layer above now matches Chrome
and it is still challenged where a fresh-profile Chrome on the same IP is not.
Stock Firefox fails the same gate the same way. This is unresolved.

**No renderer.** Canvas raster, WebGL pixels, audio rendering, font metrics
and Blink-grade layout are modelled, not computed. Anything deriving a hash
from real pixels or real glyph measurement will not match Chrome. Closing that
means integrating a Skia/Blink-compatible stack.

**The JS surface is incomplete.** `window` exposes 712 own properties against
Chrome's 1238. Nothing exposed is *wrong* — zero extra globals and zero
descriptor mismatches — but ~526 interfaces are absent. The generated ones
(`src/browser/webapi/generated_interfaces.zig`) reproduce shape only; they are
not implementations. That is safe because they cannot be constructed, so no
behaviour is observable.

**Event handlers do not fire.** The 112 generated `window.onXxx` attributes
store and return a callback so the property enumerates like Chrome's. Nothing
dispatches to them.

**`x-client-data` is a per-install constant.** The value is correctly shaped
but identical across every instance of this build, which makes it a shared
identifier linking your users to each other. Randomise per profile before
shipping to more than one user.

**Driving it is detectable in ways this does not cover.** CDP attachment,
timing of interactions, and mouse/keyboard synthesis are separate problems.
