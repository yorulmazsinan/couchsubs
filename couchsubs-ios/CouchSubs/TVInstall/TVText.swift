// SPDX-License-Identifier: AGPL-3.0-only
// Telefondan TV kurulumunun metinleri (Android'deki tvinstall_* metinleriyle aynı; Türkçeleri Localizable.xcstrings'te).
// Bu dosya Android'in strings.xml dosyalarından üretildi.

import Foundation

enum TVText {
    static var anyBody: String { String(localized: "Installs and updates the CouchSubs TV app on your Samsung, LG or Android TV from this phone, without a computer. Looking for the TV on your network; you can change the brand later.") }
    static var title: String { String(localized: "Install the TV app") }
    static var body: String { String(localized: "Installs the CouchSubs TV app on your Samsung TV from this phone, without a computer. The phone and the TV must be on the same Wi-Fi.") }
    static var supported: String { String(localized: "Samsung TVs and smart monitors (2016 and later; 2016–2018 models are experimental).") }
    static var tvs: String { String(localized: "Samsung TVs on the network") }
    static var searching: String { String(localized: "Looking for TVs…") }
    static var none: String { String(localized: "No Samsung TV found. Is the TV on and on the same Wi-Fi? You can also type its address below (on the TV: Settings › General › Network › Network Status).") }
    static var notFound: String { String(localized: "My TV isn't listed") }
    static var address: String { String(localized: "TV's IP address (on the TV under Settings › Network)") }
    static var addressExample: String { String(localized: "e.g. 192.168.1.100") }
    static func addressNotPhone(_ a0: String) -> String { String(format: String(localized: "Not this phone's address. This phone's address: %@"), a0) }
    static var addressIsPhone: String { String(localized: "This address is this phone's; type the TV's address.") }
    static var devOn: String { String(localized: "Developer mode is on") }
    static var devOff: String { String(localized: "Developer mode is off") }
    static func devOtherIp(_ a0: String) -> String { String(format: String(localized: "Host PC IP belongs to another device: %@"), a0) }
    static var stepsTitle: String { String(localized: "Turn on developer mode on the TV") }
    static var step1: String { String(localized: "1. On the TV, open Apps.") }
    static var step2: String { String(localized: "2. Press 1 2 3 4 5 on the remote (or type 12345 on the on-screen keypad). The Developer mode window opens. On some new models this works on Apps › App Settings.") }
    static var step3: String { String(localized: "3. Turn Developer mode On, type this phone's address as Host PC IP and press OK:") }
    static var step4: String { String(localized: "4. Restart the TV: hold the power button on the remote and keep holding until the TV turns off and comes back on with the Samsung logo (about 5 seconds); letting go when it turns off only puts it on standby. If no logo appears, unplug the TV for 30 seconds.") }
    static var phoneIpUnknown: String { String(localized: "Could not find this phone's address; is it on Wi-Fi?") }
    static var signinNote: String { String(localized: "The first install asks you to sign in once with a free Samsung account: Samsung only accepts the app signed with a certificate made for your TV. If the phone's address changes, repeat the Host PC IP step.") }
    static var button: String { String(localized: "Install and open") }
    static var goHome: String { String(localized: "Go to the home screen") }
    static var retry: String { String(localized: "Try again") }
    static var stepConnecting: String { String(localized: "Connecting to the TV…") }
    static var stepReading: String { String(localized: "Reading the TV…") }
    static var stepSignin: String { String(localized: "Waiting for Samsung sign-in…") }
    static var stepCertificate: String { String(localized: "Getting a certificate for your TV from Samsung…") }
    static var stepSigning: String { String(localized: "Signing the app…") }
    static var stepInstalling: String { String(localized: "Installing on the TV… (this can take a minute)") }
    static var stepUninstalling: String { String(localized: "Removing the old copy from the TV…") }
    static var stepLaunching: String { String(localized: "Opening the app on the TV…") }
    static func done(_ a0: String) -> String { String(format: String(localized: "Installed: CouchSubs %@ is opening on the TV."), a0) }
    // Telefondan kuranların çoğunun bilgisayarı yoktur; TV'nin bekleme ekranı hata sanılıyordu (#113, Android ile aynı).
    static var next: String { String(localized: "CouchSubs opens its waiting screen on the TV. Even if it mentions a computer, that is not an error: the TV is waiting for the phone. Now tap Start translating on the home screen; the TV finds this phone by itself.") }
    static func upToDate(_ a0: String) -> String { String(format: String(localized: "CouchSubs %@ is already on the TV; opening it."), a0) }
    static func details(_ a0: String) -> String { String(format: String(localized: "Details: %@"), a0) }
    static var shareLog: String { String(localized: "Share the install log") }
    static var signinTitle: String { String(localized: "Samsung sign-in") }
    static var samsungServer: String { String(localized: "If the TV shows “Unable to connect to Samsung server” (AS400): this warning comes from the TV itself; the TV can't reach Samsung's servers. Check the TV's internet connection, unplug the TV and plug it back in after 30 seconds. To install CouchSubs, enter this device's address as Host PC IP.") }
    static var maintenance: String { String(localized: "If the TV shows “Server under maintenance”, it cannot reach Samsung's servers: check the TV's internet connection and its date and time, restart the TV and try again.") }
    static func errUnreachable(_ a0: String) -> String { String(format: String(localized: "The TV did not accept this phone. In the TV's Developer mode window, check that Host PC IP is this phone's address (%@), then restart the TV fully: hold the power button until the Samsung logo appears (about 5 seconds), or unplug the TV for 30 seconds."), a0) }
    // 26101 reddedilince TV'nin 8001'de söylediği duruma göre (#524, #484).
    static func errOtherNetwork(_ a0: String, _ a1: String) -> String { String(format: String(localized: "The TV (%1$@) and this phone (%2$@) are on different networks, so the TV refuses the phone. Connect both to the same Wi-Fi (not a guest network or a second router), type the phone's new address as Host PC IP on the TV, then restart the TV fully (hold the power button until the Samsung logo appears, about 5 seconds)."), a0, a1) }
    static func errNotRestarted(_ a0: String) -> String { String(format: String(localized: "The TV's settings are right (Developer mode on, Host PC IP %@), but the TV has not fully restarted since then, so it does not accept the phone yet. Hold the power button on the remote until the TV turns off and comes back on with the Samsung logo (about 5 seconds), or unplug the TV for 30 seconds, then try again."), a0) }
    static func errOtherIp(_ a0: String, _ a1: String) -> String { String(format: String(localized: "The TV's Host PC IP is %1$@, but this phone's address is %2$@. In the TV's Developer mode window, set Host PC IP to %2$@, then restart the TV fully (hold the power button until the Samsung logo appears, about 5 seconds)."), a0, a1) }
    static func errDevOff(_ a0: String) -> String { String(format: String(localized: "Developer mode is off on the TV. Turn it on with the steps above, type this phone's address (%@) as Host PC IP, then restart the TV fully (hold the power button until the Samsung logo appears, about 5 seconds)."), a0) }
    static var errTooOld: String { String(localized: "This Samsung TV is too old for the CouchSubs TV app (2016 models and later are supported).") }
    static var errLogin: String { String(localized: "Samsung sign-in did not complete. Try again and finish signing in on the page that opens.") }
    static var errCertificate: String { String(localized: "Samsung did not issue the signing certificate. Try again in a few minutes.") }
    static var errSpace: String { String(localized: "The TV is out of free space. Remove an app you do not use from the TV and try again.") }
    static var errMismatch: String { String(localized: "A CouchSubs TV app signed on another device is still on the TV and could not be removed. On the TV, open Apps, select CouchSubs, delete it and try again.") }
    static var errRejected: String { String(localized: "The TV did not accept the signing certificate. Make sure the TV is connected to the internet (it checks the certificate with Samsung) and its date and time are right (Settings › General › System Manager › Time), then try again. CouchSubs gets a new certificate, so you sign in to Samsung once more.") }
    static var errClock: String { String(localized: "The TV's clock is behind, so the new certificate is not valid for it yet. Set the TV's date and time (Settings › General › System Manager › Time) or wait a few minutes, then try again.") }
    static var errBlocked: String { String(localized: "The TV refuses CouchSubs because an earlier CouchSubs is still registered on it (Tizen error 118, -22), even if it no longer appears among the apps. If CouchSubs is among the TV's apps, delete it there and try again. Otherwise reset Smart Hub (Settings › Support › Device Care › Self Diagnosis › Reset Smart Hub) and try again. Resetting Smart Hub also removes the other apps you downloaded.") }
    static var errConnection: String { String(localized: "The connection to the TV dropped during the install. Keep the TV on and on the same Wi-Fi as this phone, keep the phone's screen on, then try again.") }
    static var errFailed: String { String(localized: "The TV app could not be installed. Try again; if it fails again, send us the install log.") }
    static var errPackageMissing: String { String(localized: "This phone app does not contain the TV package. Update the app and try again.") }
    static var brandSamsung: String { String(localized: "Samsung") }
    static var brandAndroid: String { String(localized: "Android TV") }
    static var brandLg: String { String(localized: "LG") }
    static var lgBody: String { String(localized: "Installs the CouchSubs TV app on your LG TV (webOS) from this phone, without a computer. The phone and the TV must be on the same Wi-Fi.") }
    static var lgSupported: String { String(localized: "Needs LG's Developer Mode app on the TV and a free LG developer account. CouchSubs extends the developer mode session for you.") }
    static var lgTvs: String { String(localized: "LG TVs on the network") }
    static var lgNone: String { String(localized: "No LG TV found. Is the TV on and on the same Wi-Fi? You can also type its address below (on the TV: Settings › General › Network › the connected network).") }
    static var lgPassphrase: String { String(localized: "Passphrase (on the TV screen, 6 characters)") }
    static var lgPassphraseSaved: String { String(localized: "Passphrase (key saved; type it if needed)") }
    static var lgStepsTitle: String { String(localized: "Turn on developer mode on the TV") }
    static var lgStep1: String { String(localized: "1. Create a free LG developer account at webostv.developer.lge.com.") }
    static var lgStep2: String { String(localized: "2. On the TV, install the Developer Mode app from the LG Content Store, open it, sign in with your account and turn on Dev Mode Status. The TV restarts.") }
    static var lgStep3: String { String(localized: "3. Open the Developer Mode app again and turn on Key Server. Leave the app on screen; a 6-character Passphrase appears at the bottom left.") }
    static var lgStep4: String { String(localized: "4. Type the Passphrase above and press Install and open. The passphrase is only needed for the first install.") }
    static func lgTvSays(_ a0: String) -> String { String(format: String(localized: "TV says: %@"), a0) }
    static var lgErrUnreachable: String { String(localized: "The TV did not respond. Make sure the TV is on and on the same Wi-Fi as this phone, and that Dev Mode Status is on in the Developer Mode app.") }
    static var lgErrRestartNeeded: String { String(localized: "The TV's Key Server is on, but its developer connection is closed. After Dev Mode Status is turned on the TV has to restart: press RESTART in the Developer Mode app (or unplug the TV and plug it back in), then open the app again, turn on Key Server and try again.") }
    static var lgErrDevModeOff: String { String(localized: "The TV is on at this address, but developer mode is off. Open the Developer Mode app on the TV: Dev Mode Status must be on (it turns off by itself when its time runs out; turn it on again and the TV restarts). Then turn on Key Server and try again.") }
    static var lgErrTvNotFound: String { String(localized: "No TV responds at this address. The TV may be off, on another Wi-Fi, or its address may have changed. Turn the TV on, check its IP address in the TV's Settings › Network, and pick the right TV from the list above.") }
    static var lgErrKeyServer: String { String(localized: "Key Server is off. Turn it on in the Developer Mode app and keep the app on screen.") }
    static var lgErrPassphrase: String { String(localized: "The passphrase is not correct. Check it on the TV screen.") }
    static var lgErrKeyRefused: String { String(localized: "The TV refused the key. Open Key Server and type the passphrase again.") }
    static var stepPairing: String { String(localized: "Pairing with the TV…") }
    static var stepApprove: String { String(localized: "On the TV, answer Allow to “Allow USB debugging?” (tick “Always allow from this device”).") }
    static var stepKey: String { String(localized: "Getting the developer key from the TV…") }
    static var androidBody: String { String(localized: "Installs the CouchSubs Android TV app on your Android TV or Google TV from this phone, without a computer. The phone and the TV must be on the same Wi-Fi.") }
    static var androidSupported: String { String(localized: "Debugging must be on in the TV's developer options. Leave it on so updates can be installed.") }
    static var androidTvs: String { String(localized: "Android TVs on the network") }
    static var androidNone: String { String(localized: "No Android TV found. Is the TV on and on the same Wi-Fi? You can also type its address below (on the TV: Settings › Network & Internet › the connected network).") }
    static var androidDebugOn: String { String(localized: "TCP 5555 is reachable") }
    static var androidDebugOff: String { String(localized: "TCP 5555 is unreachable; wireless debugging uses a separate port") }
    static var androidMode: String { String(localized: "Connection") }
    static var androidModeNetwork: String { String(localized: "USB/network debugging") }
    static var androidModeWireless: String { String(localized: "Wireless debugging") }
    static var androidAddress: String { String(localized: "TV's IP address (on the TV under Settings › Network)") }
    static var androidAddressWireless: String { String(localized: "TV's IP address and port (e.g. 192.168.1.20:41235)") }
    static var androidPairAddress: String { String(localized: "IP address and port in the pairing window") }
    static var androidPairCode: String { String(localized: "Pairing code (6 digits; leave empty if already paired)") }
    static var androidNeedPort: String { String(localized: "With wireless debugging, type the TV's port too: the “IP address & Port” at the top of the TV's Wireless debugging screen (e.g. 192.168.1.20:41235).") }
    static var androidNeedPairPort: String { String(localized: "Next to the pairing code, type the IP address and port from the pairing window too (e.g. 192.168.1.20:37099).") }
    static var androidStepsTitle: String { String(localized: "Turn on debugging on the TV") }
    static var androidStep1: String { String(localized: "1. Turn on developer options: on the TV, open Settings › System (or Device Preferences) › About and press the Android TV OS build row 7 times.") }
    static var androidStep2: String { String(localized: "2. In Settings › System › Developer options, turn on USB debugging. Some TVs also have “Network debugging” or “ADB over network”; turn that on too.") }
    static var androidStep3: String { String(localized: "3. Press Install and open. When the TV asks “Allow USB debugging?”, tick “Always allow from this device” and choose Allow. If it cannot connect, try the Wireless debugging option (Android 11 and later, Google TV).") }
    static var androidWirelessStep2: String { String(localized: "2. Turn on Developer options › Wireless debugging and open it. Type the “IP address & Port” at the top as the TV's address.") }
    static var androidWirelessStep3: String { String(localized: "3. The first time, press “Pair device with pairing code”; type the IP address and port from that window together with the 6-digit code, and press Install and open while the window is still open.") }
    static var androidReplace: String { String(localized: "Remove the TV's copy and install") }
    static var androidErrUnreachable: String { String(localized: "The TV did not respond. Make sure the TV is on and on the same Wi-Fi as this phone, and that debugging is on in its developer options. With wireless debugging the port changes every time; type the one on the screen.") }
    static var androidTryWireless: String { String(localized: "Try with wireless debugging") }
    static var androidErrLegacyClosed: String { String(localized: "The TV did not answer on the USB/network debugging port (5555). Newer Android TV and Google TV models keep this port closed. On the TV, turn on Developer options › Wireless debugging, then tap the button below.") }
    static var androidErrNotApproved: String { String(localized: "Debugging was not allowed on the TV. Try again and choose Allow on the TV.") }
    static var androidErrNotPaired: String { String(localized: "The TV does not know this phone. With wireless debugging, pair first: press “Pair device with pairing code” on the TV, type the address and the code from that window and try again.") }
    static var androidErrPairing: String { String(localized: "Pairing failed: the code is wrong or the pairing window on the TV closed. Open the window again, type the new code and port and try again.") }
    static var androidErrOtherCopy: String { String(localized: "CouchSubs TV on the TV is signed with another key (0.9.18 and earlier were signed with an old key) or is newer than this phone's, so this version cannot be installed over it. The button below removes the TV's copy and installs the new one; the TV app's settings are deleted. If that fails, on the TV go to Settings › Apps › CouchSubs TV › Uninstall, then press Install and open here.") }
    static var androidErrRemoveManually: String { String(localized: "The old CouchSubs TV could not be removed from the TV, so the new one cannot be installed. Remove it on the TV yourself: Settings › Apps › See all apps › CouchSubs TV › Uninstall. Then press Install and open here.") }
    static var entry: String { String(localized: "Install the TV app from this phone") }
    static var samsungNote: String { String(localized: "Samsung TVs and smart monitors (2016 and later; 2016–2018 models are experimental).") }
    static var androidNote: String { String(localized: "Debugging must be on in the TV's developer options. You can turn it off after the install.") }
    static var lgNote: String { String(localized: "Needs LG's Developer Mode app on the TV and a free LG developer account.") }
    static var lgSessionNote: String { String(localized: "Developer mode stays on for at most 1000 hours. CouchSubs extends it by itself once a day while the phone can reach the TV.") }
    static var updateTitle: String { String(localized: "A new TV app version is available") }
    static func updateVersions(_ a0: String, _ a1: String) -> String { String(format: String(localized: "TV: %@ → this phone: %@"), a0, a1) }
    static var updateButton: String { String(localized: "Update the TV app") }
    static func installedOn(_ a0: String) -> String { String(format: String(localized: "TV app installed on %@"), a0) }
    static var notInstalled: String { String(localized: "Not installed") }
    static var fromPhone: String { String(localized: "Install the TV app from this phone") }
    static var wirelessIos: String { String(localized: "On iPhone, wireless debugging needs this phone's Local Network permission (Settings › CouchSubs).") }
    static var stepPlay: String { String(localized: "The Google Play page opened on the TV: press Install (or Update) with the TV remote. The app opens by itself once it is installed.") }
    static var androidErrPlayCopy: String { String(localized: "CouchSubs on the TV was installed from Google Play and this version could not be installed over it. You can keep using the Play version; Play brings the update itself. To install this version now, the button below removes the TV's copy and installs the new one (the TV app's settings are deleted).") }
}
