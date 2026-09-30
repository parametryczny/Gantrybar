# Security policy

## Supported version

Security fixes are provided for the newest published version of BambuBar.

## Reporting a vulnerability

Please do not publish access codes, printer serial numbers, local IP addresses or vulnerability details in a public issue. Use GitHub's private vulnerability reporting for this repository when available, or contact the maintainer through the GitHub profile.

## Local data

- the **Local** build stores access codes in the application's local preferences; protect the Mac with FileVault and a strong login password
- the **Keychain** build stores access codes in the user's macOS Keychain
- the GNU/Linux build stores Bambu access codes and PrusaLink/Moonraker API keys in the desktop Secret Service through `secret-tool`; it refuses to save them in plain text when no compatible keyring is available
- the Raspberry Pi kiosk configuration panel uses a locally generated HTTPS certificate, a rotating on-screen pairing code, an HttpOnly session cookie, CSRF checks and login rate limiting; it is intended only for a trusted LAN
- bulk-import CSV files contain access codes in plain text by design; delete the source CSV after a successful import
- printer names, serial numbers, local IP addresses and ordering are stored in the application's local preferences (on GNU/Linux: `~/.config/gantry/config.json`, mode `0600`)
- printer certificate fingerprints are stored in local preferences; fingerprints are not secret credentials
- BambuBar communicates directly with printers and does not send printer data to this repository or to a BambuBar service
- Bambu Studio configuration is read only after the user selects **Import printers and codes**

## Network trust model

Bambu Lab printers expose MQTT over TLS using device-local certificates that are not rooted in the macOS public trust store. BambuBar uses trust on first use (TOFU): it records the first certificate presented for each printer and rejects later connections when that certificate unexpectedly changes.

The first connection must still take place on a trusted local network. If printer firmware legitimately replaces a certificate, verify that the printer and network are trusted, then remove and add that printer again to accept its new certificate. Certificate pinning reduces later man-in-the-middle risk but cannot authenticate an already-hostile first connection.
