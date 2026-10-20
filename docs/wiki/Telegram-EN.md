# Telegram: your bot and fleet

[Polski](https://github.com/parametryczny/Gantrybar/wiki/Telegram-PL) · [Contents](https://github.com/parametryczny/Gantrybar/wiki/Home)

Gantry connects directly to Telegram’s Bot API using your own bot. Enabled alerts and requested camera images pass through Telegram. The computer running Gantry must remain awake and online.

## Set up

1. Open the verified **@BotFather** account in Telegram, send `/newbot` and create a bot.
2. Save the bot token privately. It grants access to the bot; revoke it through BotFather if exposed.
3. Open your new bot, tap **Start** and send a message.
4. Obtain the destination `chat_id`. Telegram’s `getUpdates` response includes it after a message; pause Gantry’s Telegram integration while checking, because only one poller should consume updates.
5. In Gantry’s Telegram settings, enable the integration, enter the token and Chat ID, then send a test.

Do not share a token-bearing URL, logs or screenshots. Configure the intended chat; access is not granted to everyone who finds the bot.

## Everyday use

| Command | Purpose |
| --- | --- |
| `/status` | Select a printer and inspect its state. |
| `/all` | Summarise the fleet. |
| `/spools` | Check rolls running low. |
| `/history` | Review recent prints. |
| `/watch 10m` | Request periodic photos. |
| `/mute 2h` | Mute alerts temporarily. |
| `/help` | Show available commands. |

Printer messages expose available controls, including pause, resume, stop, light and camera photo. Commands remain subject to the printer’s capabilities and enabled control settings.

## If the bot is silent

Check that Gantry is running, the computer is awake and online, the integration is enabled, the Chat ID matches and no other process uses the same bot’s polling loop. Quiet hours and `/mute` can suppress alerts. Never post the token in a support issue.
