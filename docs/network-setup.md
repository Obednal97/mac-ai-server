# Phone Wi-Fi setup

**The problem:** you move the Mac somewhere new, with no screen, no keyboard and no Ethernet, and it doesn't know the Wi-Fi there. How do you tell it the password?

**The answer:** plug your phone in with a USB-C cable. The Mac shows a small setup page on your phone, where you pick the Wi-Fi and type its password.

The installer sets this up on every Mac. It needs nothing from you until the day you use it, except one click on **Allow** for Location during the install. That click is explained below.

## How it decides to show the page

A small background service (`local.netsetup`) checks every 10 seconds:

1. **The Mac is online over Wi-Fi or Ethernet:** it does nothing. Networks the Mac already knows are joined by macOS as usual.
2. **The Mac has been offline for 3 minutes and a phone is sharing its connection over USB:** it serves the setup page over that cable. The Mac's Wi-Fi is free to scan, so the page lists nearby networks live.

## Using it

### 1. Get the phone ready

**iPhone:**
1. Open Settings > Personal Hotspot and turn on **Allow Others to Join**.
2. Keep the phone **unlocked on that screen** while you plug it in.
3. If the phone asks "Trust This Computer?", tap **Trust** and enter your passcode.

**Android** (**untested**): turn on **USB tethering** in the phone's network settings. It may work, but nobody has tried it yet.

### 2. Plug it in and wait

Connect the phone to the Mac with a USB-C cable. Wait for the Mac to have been offline for 3 minutes after it started, then about another minute.

### 3. Open the page

Open the phone's browser and go to:

```
http://172.20.10.2
```

That's the Mac's fixed address on an iPhone's cable connection, and the most reliable way in. The machine name also works, but over the cable it doesn't always load (seen with an iPhone in October 2026). On Android, use the name:

```
http://ai-mini.local
```

Use your own machine name.

### What each screen shows

1. **"Connect this Mac mini to your Wi-Fi."** A short explanation, then **Wi-Fi networks the Mac can see**, with signal strength and a lock for networks that need a password. "Looking for networks… This can take up to 30 seconds." **Scan again** refreshes the list.
2. **Tap your network.** A **Password for <name>** box appears, with **Show** to check what you typed. Leave it empty for an open network.
   - Network not listed? Use "Network not listed?" and type its name exactly, including capital letters.
3. **Tap Join.** "Joining … This usually takes 10 to 30 seconds. Keep the cable plugged in."
4. **"Connected to <name>."** "The Mac mini will use this Wi-Fi from now on, even after a restart." Unplug the cable; you can turn off Personal Hotspot. Underneath are the Mac's details on its new network: its **IP address**, its name (`ai-mini.local`), the router, subnet mask, DNS, the Wi-Fi hardware address and, if Tailscale is connected, its Tailscale name and address. Plus the SSH commands, and a tip to reserve the address in your router.

**If the page loses the Mac mid-join.** The moment the Mac gets onto the Wi-Fi, the cable connection often stops answering, so the page may never hear "Connected". After 20 seconds of silence it says so: **"The Mac mini stopped answering over the cable after it started joining…"**, which usually means it worked. To check:
1. turn off Personal Hotspot and unplug the cable;
2. put the phone on the same Wi-Fi;
3. tap **Check**. It opens `http://ai-mini.local` on that Wi-Fi and shows **Connected** with the details above.

The confirmation stays up for **one hour** after a successful join, on every network the Mac is on. During that hour the page only shows the result: choosing a different Wi-Fi works only from the phone on the cable, never from the home network.

The page uses the Mac's own model name ("Mac mini", "Mac Studio", "MacBook Pro"…), or just "Mac" if it can't tell. The examples here use "Mac mini".

If something goes wrong, the page says so in plain words:

| The page says | What to do |
|---|---|
| "That password didn't work." | Check capital letters; tap Show. |
| "The Mac mini can't find <name>." | Check the name, and that the router is on and near the Mac. |
| "Joined, but got no address from the router" | Try again in a minute. If it keeps happening, restart the router. |
| "Can't reach the Mac mini." | Check that the cable is plugged in and Personal Hotspot is on. |
| "Nobody is logged in on the Mac yet…" | Wait a minute after it starts. The Mac logs itself in, and joining needs that. |

## Why it needs Location

macOS hides Wi-Fi network **names** from apps that don't have Location permission. So a small app, **Wi-Fi Setup** (`/Applications/WifiScan.app`), does the scanning and joining in your logged-in session.

The app is built on your Mac during the install. The first time it runs, macOS asks:

> "Wi-Fi Setup" would like to use your location.

Click **Allow**. It's needed once; the app never records where the Mac is. If you missed it: System Settings > Privacy & Security > Location Services, then switch on **Wi-Fi Setup**. `mac-ai-server doctor` checks it:

```
ok network setup service is loaded and WifiScan has Location permission
```

## Other ways to get online

- **Ethernet:** plug a cable from your router in. It always works.
- **A Mac laptop and a USB-C or Thunderbolt cable:** connect the two Macs and `ssh admin@ai-mini.local` over the cable. Then join Wi-Fi from the command line, or use Screen Sharing.
- **A monitor and keyboard:** join Wi-Fi from the menu bar.

There's **no Wi-Fi hotspot** fallback, where the Mac makes its own network for you to join. macOS 27 won't start Internet Sharing without a connection to share, so it can't work. See [decisions-and-gotchas.md](decisions-and-gotchas.md).

## Testing it

To show the setup page as if the Mac were offline with a phone plugged in, plug the phone in and run:

```bash
ai-netsetup-mode tether
```

To go back to normal (a successful join also does this):

```bash
ai-netsetup-mode auto
```

The log is at `/var/log/ai-netsetup.log`:

```bash
tail -f /var/log/ai-netsetup.log
```

## What's been tested

| Part | Status |
|---|---|
| Live scan through the service (network names shown) | Tested |
| iPhone on USB-C reaching the page | `172.20.10.2`: tested. The `.local` name: worked in the first test, failed in a later one |
| Joining a network from the page, with progress and "Connected" | Tested |
| The cable connection dropping as the Mac joins (the page stuck on "Joining…") | Seen in October 2026; the join had worked. Fixed: requests time out, the page explains, and the one-hour confirmation shows the result on the Wi-Fi. Tested in a browser against a stand-in; not yet on a real iPhone. |
| iPhone link coming up by itself | Fixed and tested: macOS sometimes left it down and the iPhone didn't answer DHCP. The service brings it up and falls back to `172.20.10.2`. It retries every 10 seconds if the link drops. |
| Android USB tethering | **Not tested** |
| Wi-Fi hotspot via Internet Sharing | Removed: macOS 27 won't start it without a connection to share |
