# Installing the CouchSubs TV app

The TV apps are not in the stores yet. Turn on developer mode on your TV and CouchSubs installs the TV app by itself.
Developer mode is free and does not harm the TV. The desktop app shows these steps in its TV step and waits for the TV.

| TV | Status | Guide |
|---|---|---|
| **LG** (webOS 4+) | Tested on a real TV. CouchSubs installs the TV app itself | [LG](#lg-tv) |
| **Samsung** (Tizen, 2019 and later) | Tested on a real TV (75" Neo QLED). CouchSubs installs it; asks for a Samsung sign-in once | [Samsung](#samsung-tv) |
| **Samsung** (Tizen 3.0–4.0, 2017–2018) | Experimental: a user installed the app by hand on a UE43MU7000U (2017) and it worked; CouchSubs' own install is not yet tested on these TVs | [Samsung](#samsung-tv) |
| **Android TV / Google TV** (Vestel, Arçelik, Beko, Grundig, Philips and others) | Tested on a real TV. CouchSubs installs it over the network | [Android TV](#android-tv--google-tv) |
| **Linux models of Vestel, Arçelik, Beko and Grundig, Philips Saphi and Titan OS** | Not supported: we found no way to install apps on them | |

The computer and the TV must be on the same home network.

## LG TV

1. Create a free account at [webostv.developer.lge.com](https://webostv.developer.lge.com) (**SIGN IN › Create Account**).
2. On the TV, install **Developer Mode** from the LG Content Store and sign in with that account.
3. Turn on **Dev Mode Status**. The TV restarts.
4. Open CouchSubs on your computer. In the TV step, pick your TV, press **Connect** and accept the prompt on the TV.
5. Open the Developer Mode app again, turn on **Key Server** and keep the app on screen.
6. Type the 6-character, case-sensitive **Passphrase** shown at the bottom left of the TV into CouchSubs and press **Install on the TV**.

CouchSubs installs later versions by itself and restarts the 1000-hour developer mode session each time you use it. If you
will not use CouchSubs for a long time, press **EXTEND** in the Developer Mode app before the time runs out: when it
expires, developer mode turns off and the TV app is removed.

## Samsung TV

Samsung requires apps to be signed for each TV. CouchSubs does this for you; you only sign in once with a free Samsung
account. Tested on a 75" Neo QLED.

1. In the TV's **Apps** screen press `1 2 3 4 5`, turn **Developer mode** on, enter your computer's address as
   **Host PC IP** (CouchSubs shows it) and restart the TV: hold the remote's power button for about 2 seconds until
   the TV turns off, then turn it on. A short press only puts a Samsung TV on standby.
2. In the TV step of CouchSubs, pick your Samsung TV and press **Connect**.
3. CouchSubs opens Samsung's sign-in page in your browser. Sign in (or create a free account there). If the browser asks to
   allow access to devices on your network, allow it.
4. CouchSubs gets the certificate for your TV, signs the app, installs it and opens it.

If CouchSubs says the TV did not accept this computer, check that **Host PC IP** is your computer's current address and
restart the TV. Manual install with Tizen Studio: see the [Turkish guide](tv-kurulum.md#elle-kurulum).

If the TV keeps switching to HDMI 1 or another source while the CouchSubs TV app is open (also during the install),
turn off **Anynet+ (HDMI-CEC)** and **Auto Source Switching** in **Settings › All Settings › Connection › External
Device Manager**.

If you close CouchSubs while it is installing the TV app, the setup is not marked as finished: next time it opens on
the TV step and continues the install.

## Android TV / Google TV

Tested on a real TV. Some TVs may not give the HDMI picture to other apps: subtitles appear but the picture stays
black. Please report your TV model in [Issues](https://github.com/yorulmazsinan/couchsubs/issues).

1. In **Settings › Device Preferences › About** (Google TV: **Settings › System › About**) press OK on **Build** 7 times.
2. In **Developer options** turn on **USB debugging** (and **Network debugging** if you see it).
3. In the TV step of CouchSubs, select **Android TV / Google TV**. CouchSubs finds the TV on the network.
4. The TV asks whether to allow debugging from this computer: tick **Always allow** and choose **Allow**. CouchSubs installs
   the app and opens it.
5. If there is no picture, press OK for the panel and pick the HDMI input with left and right.

If CouchSubs cannot find the TV, install `CouchSubs-androidtv.apk` from
[Releases](https://github.com/yorulmazsinan/couchsubs/releases) with a USB stick and a file manager on the TV.
