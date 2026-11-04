# sm-plugin-ZR_RoundEnd-discord

### Send the Zombie:Reloaded round-end player list to a Discord channel or thread.

At every round end, the plugin posts a header line, then one line per player in code blocks split to fit Discord's 2000-character limit:

```
`ze_example_map` *(CT: 4 | T: 2) - 08/21/2026 @ 02:18:22* - Demo: 1 @ Tick: ≈ 108158 *(Started 21.08.2026 @ 01:51)*
# 2275 "Player One" [U:1:123456789] dead zombie
# 2243 "Player Two" [U:1:987654321] alive human
# 9 "SourceTV" BOT dead human
```

Messages are sent one at a time, so they reach Discord in order. On a rate limit (HTTP 429) the plugin waits for the delay Discord asks for; other failures are retried `sm_zr_roundend_webhook_retry` times.

## Requirements

- [Zombie:Reloaded](https://github.com/srcdslab/sm-plugin-zombiereloaded) with the round-end API (`ZR_OnRoundEndStats` and `ZR_OnRoundEndPlayer`). The player id format follows `zr_roundend_authid_type`.
- The [REST in Pawn](https://github.com/ErikMinekus/sm-ripext) extension, used through [DiscordWebhookAPI](https://github.com/srcdslab/sm-plugin-DiscordWebhookAPI).
- Optional: [AutoRecorder](https://github.com/srcdslab/sm-plugin-AutoRecorder) for the demo number, tick and start time. Without it, the header shows `Demo: N/A`.

## ConVars

| ConVar | Default | Description |
|---|---|---|
| `sm_zr_roundend_webhook` | `""` | Discord webhook URL. |
| `sm_zr_roundend_webhook_retry` | `3` | Number of retries if sending fails. |
| `sm_zr_roundend_username` | `ZR RoundEnd` | Webhook username. |
| `sm_zr_roundend_avatar` | `""` | Webhook avatar URL. |
| `sm_zr_roundend_channel_type` | `0` | `1` = thread, `0` = classic text channel. |
| `sm_zr_roundend_threadid` | `""` | Thread ID, required when `sm_zr_roundend_channel_type` is `1`. |

The config file is `cfg/sourcemod/plugin.zr_roundend_discord.cfg`.
