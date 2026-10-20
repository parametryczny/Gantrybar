# Web dashboard: local network and your own hosting

[Polski](https://github.com/parametryczny/Gantrybar/wiki/Web-dashboard-PL) · [Contents](https://github.com/parametryczny/Gantrybar/wiki/Home)

Gantry provides two different viewing methods. A local address does not become an internet address when you leave Wi-Fi.

| Mode | Where it works | Must remain available |
| --- | --- | --- |
| local preview server | local network | the Gantry computer and access to its address |
| own-hosting bridge | also outside Wi-Fi | Gantry, internet and PHP/HTTPS hosting |

## LAN viewing

Enable **Preview server** in Settings and use the address displayed by the app. The phone must be on a network able to reach the computer. The local panel is read-only; the computer's firewall may block connections.

Printer Details do not need to remain open. The computer must stay running and reachable.

## Generate a hosting package

Open the own-page and bridge settings in Gantry.

1. Choose **Generate website package…**.
2. Enter the final HTTPS address, such as `https://example.com/gantry/`.
3. Store the website password in your password manager. The generator uses the app's bridge key or prepares one when needed.
4. Save the ZIP and upload its **extracted contents**, including `.htaccess`, to PHP hosting.
5. Give PHP write access to the data directory.
6. Enable the bridge in Gantry; begin with **View only**.
7. Sign in and check the last-synchronisation time.

Generation neither publishes the site nor enables the bridge. The ZIP contains the configuration key: do not leave the archive itself in a public hosting directory. It stores a password hash; the bridge key is kept server-side in PHP, not in JavaScript.

PHP 7.4 or later is required. Apache can use the included `.htaccess`; Nginx needs equivalent access restrictions for `config.php` and `data/`.

## Data and control scope

Basic fleet status and additional data are separate scopes. Enable extra sharing to send Farm, history, costs, Spoolbase and maintenance. Cameras can send frames to hosting while a signed-in user views Monitoring.

**View only** does not permit commands. Optional control is limited by both the app and the printer. Viewing Farm or Spoolbase does not mean browser-based inventory editing or file uploading.

Phones use bottom navigation and stacked cards; desktop navigation is on the side.

## Updating and login

Preserve your `config.php` and `data/` when updating. Replace the current website files together, especially `index.php`, `api.php`, `lib.php` and `dashboard.php`, then sign in again.

If login shows a “Sign in” JSON response at `api.php?action=login`, check that the update is complete and that the site address and directory agree. Never include a password or key in a bug report.

Safari displays the domain in its address bar; a website cannot replace it with its own name. An app name can be used when adding the page to the home screen.

## Remembered login and printer preferences

Select **Remember me for 30 days** on the login page. Without it, sessions have a 12-hour limit. Logging out or changing the password invalidates access. A phone home-screen shortcut may need a first login separately from Safari; remembered sessions then work in the same way.

The app’s hidden-EXT preference is passed to both the LAN dashboard and hosting bridge. Update the app and hosted website files to receive the fix.

When remote control is enabled, the header light button offers **All lights off / All lights on** for connected, supported printers. Read-only mode does not permit these commands.

The service workspace does not yet expose checklist, problem or parts forms on the web. In-service status is considered when displaying Farm printer compatibility.
