# Sopos

A tiny, fast Sonos remote for iOS: pick a station from your Sonos Favorites, play/pause, volume.
It talks to the speaker directly over your Wi-Fi (UPnP on port 1400), no Sonos cloud.

## Setup

1. In the official Sonos app, add the Sonos Radio stations you like to **Sonos Favorites**.
2. On a Mac: open `Sopos.xcodeproj` in Xcode (16 or newer).
3. Select the *Sopos* target → *Signing & Capabilities* → choose your Team (a free Apple ID works).
   If the bundle id is taken, change it to anything unique.
4. Plug in your iPhone, select it as run destination, press ▶.
   On the phone, allow *Local Network* access when asked.

With a free Apple ID the app stops launching after 7 days; just run it again from Xcode.
