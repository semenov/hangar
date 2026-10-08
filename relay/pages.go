package main

const pageStyle = `<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  :root { color-scheme: dark; }
  body { font: 17px/1.55 -apple-system, BlinkMacSystemFont, "Inter", sans-serif; margin: 0;
         background: linear-gradient(#1e2866, #090d23) fixed; color: #e7eff6; }
  main { max-width: 640px; margin: 0 auto; padding: 56px 24px 80px; }
  h1 { font-size: 40px; margin: 0 0 8px; letter-spacing: -0.5px; }
  h2 { font-size: 20px; margin: 36px 0 8px; }
  p, li { color: #c6d1e3; }
  a { color: #55b8ff; }
  code, pre { font: 15px ui-monospace, SFMono-Regular, Menlo, monospace; }
  pre { background: rgba(0,0,0,.3); padding: 14px 16px; border-radius: 12px; overflow-x: auto; }
  .mint { color: #4dd9b3; }
  .small { font-size: 14px; color: #8b98b5; }
</style>`

const landingHTML = `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Hangar</title>` + pageStyle + `</head>
<body><main>
<h1>Hangar</h1>
<p>Start, stop and open the <b>Claude Code</b> sessions on your Mac from your iPhone,
and see your subscription limits. Hangar runs Claude Code's Remote Control sessions for each of
your projects; you work in them in the Claude app as usual.</p>

<h2>Set up your Mac</h2>
<pre>brew install semenov/tap/hangar
hangar setup</pre>
<p><code>hangar setup</code> checks that Claude Code is installed and signed in with claude.ai (Pro,
Max, Team or Enterprise), asks where your projects live, starts in the background and shows a QR
code. Scan it with the iPhone camera.</p>

<h2>How it connects</h2>
<p>The Mac and the app talk through this relay, <span class="mint">end-to-end encrypted</span>
(X25519, ChaCha20-Poly1305): the relay passes encrypted frames along and can't read or change them.
The Mac only makes an outgoing connection; it opens no ports.</p>

<p class="small"><a href="https://github.com/semenov/hangar">Source code</a> (MIT) ·
<a href="/privacy">Privacy</a> · Hangar isn't made by or affiliated with Anthropic.</p>
</main></body></html>`

const privacyHTML = `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Hangar privacy</title>` + pageStyle + `</head>
<body><main>
<h1>Privacy</h1>
<p class="small">Last updated October 8, 2026</p>

<p>Hangar is an iPhone app and a Mac command, <code>hangar</code>, that lets you manage Claude Code
sessions on your own Mac.</p>

<h2>What we collect</h2>
<p>Nothing. There are no accounts, analytics, ads or tracking in the app or the Mac command.</p>

<h2>What stays on your devices</h2>
<p>Your projects, sessions, descriptions and limits live on your Mac. The app keeps the Macs you
paired and a cache of what they last showed; its pairing keys are in the iPhone's Keychain.</p>

<h2>The relay</h2>
<p>The app reaches your Mac through a relay at hangar.semenov.ai. Everything the app and the Mac
exchange is end-to-end encrypted; the relay can't read it. To connect the two, it sees your Mac's
random ID, the public keys used to set up encryption, IP addresses, and the size and timing of
encrypted messages. It doesn't store any of it beyond the connection; its server log records only when
a Mac connects and disconnects (with the first characters of its ID), never content.</p>

<h2>Claude</h2>
<p>Sessions are Claude Code's own; what you do in them is covered by Anthropic's terms and privacy
policy, not by Hangar. The Mac command runs <code>claude</code> on your Mac and never sees or stores
your Claude credentials.</p>

<h2>Contact</h2>
<p>Questions: <a href="https://github.com/semenov/hangar/issues">github.com/semenov/hangar/issues</a>.</p>
</main></body></html>`
