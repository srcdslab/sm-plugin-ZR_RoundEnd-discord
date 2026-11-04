#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <discordWebhookAPI>

#undef REQUIRE_PLUGIN
#include <zombiereloaded>
#include <AutoRecorder>
#define REQUIRE_PLUGIN

#define PLUGIN_TAG          "[ZR-RoundEnd]"
#define TEAM_T              2
#define TEAM_CT             3
#define ROUND_OUTPUT_SIZE   16384
#define CODE_BLOCK_START    "```txt\n"
#define CODE_BLOCK_END      "\n```"
#define MAX_RETRY_DELAY     60.0
#define DEFAULT_RETRY_DELAY 2.0

ConVar g_cvWebhook, g_cvWebhookRetry, g_cvUsername, g_cvAvatar, g_cvChannelType, g_cvThreadID;

bool g_bPlugin_AutoRecorder;
bool g_bNative_IsDemoRecording, g_bNative_GetDemoRecordCount, g_bNative_GetDemoRecordingTick, g_bNative_GetDemoRecordingTime;

int g_iExpectedRows, g_iReceivedRows;
char g_sRoundHeader[512];
char g_sRoundOutput[ROUND_OUTPUT_SIZE];

ArrayList g_hSendQueue;
bool g_bQueueSending;
char g_sQueueWebhookURL[WEBHOOK_URL_MAX_SIZE];
char g_sQueueThreadID[32];

public Plugin myinfo =
{
	name = "[ZR] RoundEnd Discord",
	author = "Rushaway",
	description = "Sends round-end stats to Discord via webhook.",
	version = "1.2.1",
	url = ""
};

public void OnPluginStart()
{
	g_cvWebhook = CreateConVar("sm_zr_roundend_webhook", "", "Discord webhook URL used for final round-end output.", FCVAR_PROTECTED);
	g_cvWebhookRetry = CreateConVar("sm_zr_roundend_webhook_retry", "3", "Number of retries if webhook sending fails.", FCVAR_PROTECTED);
	g_cvUsername = CreateConVar("sm_zr_roundend_username", "ZR RoundEnd", "Discord webhook username.", FCVAR_PROTECTED);
	g_cvAvatar = CreateConVar("sm_zr_roundend_avatar", "", "Discord webhook avatar URL.", FCVAR_PROTECTED);
	g_cvChannelType = CreateConVar("sm_zr_roundend_channel_type", "0", "Type of your channel: (1 = Thread, 0 = Classic Text channel)", FCVAR_PROTECTED, true, 0.0, true, 1.0);
	g_cvThreadID = CreateConVar("sm_zr_roundend_threadid", "", "If thread_id is provided, messages will be sent in that thread.", FCVAR_PROTECTED);

	AutoExecConfig(true);

	g_hSendQueue = new ArrayList(ByteCountToCells(WEBHOOK_MSG_MAX_SIZE));
}

public void OnAllPluginsLoaded()
{
	g_bPlugin_AutoRecorder = LibraryExists("AutoRecorder");
	VerifyNatives_AutoRecorder();
}

public void OnLibraryAdded(const char[] name)
{
	if (strcmp(name, "AutoRecorder", false) == 0)
	{
		g_bPlugin_AutoRecorder = true;
		VerifyNatives_AutoRecorder();
	}
}

public void OnLibraryRemoved(const char[] name)
{
	if (strcmp(name, "AutoRecorder", false) == 0)
	{
		g_bPlugin_AutoRecorder = false;
		VerifyNatives_AutoRecorder();
	}
}

void VerifyNatives_AutoRecorder()
{
	g_bNative_IsDemoRecording = g_bPlugin_AutoRecorder && GetFeatureStatus(FeatureType_Native, "AutoRecorder_IsDemoRecording") == FeatureStatus_Available;
	g_bNative_GetDemoRecordCount = g_bPlugin_AutoRecorder && GetFeatureStatus(FeatureType_Native, "AutoRecorder_GetDemoRecordCount") == FeatureStatus_Available;
	g_bNative_GetDemoRecordingTick = g_bPlugin_AutoRecorder && GetFeatureStatus(FeatureType_Native, "AutoRecorder_GetDemoRecordingTick") == FeatureStatus_Available;
	g_bNative_GetDemoRecordingTime = g_bPlugin_AutoRecorder && GetFeatureStatus(FeatureType_Native, "AutoRecorder_GetDemoRecordingTime") == FeatureStatus_Available;
}

/* ZR sends the row count first, then one ZR_OnRoundEndPlayer call per player. */
public void ZR_OnRoundEndStats(int playerCount)
{
	g_iExpectedRows = playerCount;
	g_iReceivedRows = 0;
	g_sRoundOutput[0] = '\0';
	BuildRoundHeader(g_sRoundHeader, sizeof(g_sRoundHeader));

	LogMessage("%s Receiving %d rows", PLUGIN_TAG, playerCount);

	if (playerCount <= 0)
		SendRoundEndToDiscord();
}

public void ZR_OnRoundEndPlayer(int userid, const char[] name, const char[] auth, bool alive, bool zombie)
{
	if (g_iReceivedRows >= g_iExpectedRows)
		return;

	AppendRoundLine(userid, name, auth, alive, zombie);
	g_iReceivedRows++;

	if (g_iReceivedRows == g_iExpectedRows)
	{
		LogMessage("%s Batch complete (%d/%d)", PLUGIN_TAG, g_iReceivedRows, g_iExpectedRows);
		SendRoundEndToDiscord();
	}
}

void BuildRoundHeader(char[] buffer, int maxlen)
{
	char sMap[PLATFORM_MAX_PATH], sTime[32];
	GetCurrentMap(sMap, sizeof(sMap));
	FormatTime(sTime, sizeof(sTime), "%m/%d/%Y @ %H:%M:%S", GetTime());

	int iScoreCT = GetTeamScore(TEAM_CT);
	int iScoreT = GetTeamScore(TEAM_T);

	if (!g_bNative_IsDemoRecording || !AutoRecorder_IsDemoRecording())
	{
		FormatEx(buffer, maxlen, "`%s` *(CT: %d | T: %d) - %s* - Demo: N/A", sMap, iScoreCT, iScoreT, sTime);
		return;
	}

	int iCount = g_bNative_GetDemoRecordCount ? AutoRecorder_GetDemoRecordCount() : 0;
	int iTick = g_bNative_GetDemoRecordingTick ? AutoRecorder_GetDemoRecordingTick() : 0;

	char sStarted[32] = "N/A";
	int iStartTime = g_bNative_GetDemoRecordingTime ? AutoRecorder_GetDemoRecordingTime() : 0;
	if (iStartTime > 0)
		FormatTime(sStarted, sizeof(sStarted), "%d.%m.%Y @ %H:%M", iStartTime);

	FormatEx(buffer, maxlen, "`%s` *(CT: %d | T: %d) - %s* - Demo: %d @ Tick: ≈ %d *(Started %s)*", sMap, iScoreCT, iScoreT, sTime, iCount, iTick, sStarted);
}

void AppendRoundLine(int userid, const char[] name, const char[] auth, bool alive, bool zombie)
{
	char sName[MAX_NAME_LENGTH * 2];
	strcopy(sName, sizeof(sName), name);
	EscapeForCodeBlock(sName, sizeof(sName));

	char sLine[512];
	FormatEx(sLine, sizeof(sLine), "# %d \"%s\" %s %s %s", userid, sName, auth, alive ? "alive" : "dead", zombie ? "zombie" : "human");

	int iLength = strlen(g_sRoundOutput);
	int iNeeded = strlen(sLine) + (iLength > 0 ? 1 : 0);
	if (iLength + iNeeded >= sizeof(g_sRoundOutput))
	{
		LogError("%s Buffer full, cannot append full line without truncation.", PLUGIN_TAG);
		return;
	}

	if (iLength > 0)
		StrCat(g_sRoundOutput, sizeof(g_sRoundOutput), "\n");

	StrCat(g_sRoundOutput, sizeof(g_sRoundOutput), sLine);
}

/* A name containing ``` would close the code block early. */
void EscapeForCodeBlock(char[] buffer, int maxlen)
{
	ReplaceString(buffer, maxlen, "```", "'''");
}

void SendRoundEndToDiscord()
{
	char sWebhookURL[WEBHOOK_URL_MAX_SIZE];
	g_cvWebhook.GetString(sWebhookURL, sizeof(sWebhookURL));
	if (!sWebhookURL[0])
	{
		LogError("%s Missing webhook URL. Set sm_zr_roundend_webhook.", PLUGIN_TAG);
		return;
	}

	char sThreadID[32];
	if (g_cvChannelType.BoolValue)
	{
		g_cvThreadID.GetString(sThreadID, sizeof(sThreadID));
		if (!sThreadID[0])
		{
			LogError("%s Thread mode enabled but sm_zr_roundend_threadid is empty.", PLUGIN_TAG);
			return;
		}
	}

	if (g_bQueueSending)
	{
		LogError("%s Previous Discord batch is still sending, skipping this round-end payload.", PLUGIN_TAG);
		return;
	}

	strcopy(g_sQueueWebhookURL, sizeof(g_sQueueWebhookURL), sWebhookURL);
	strcopy(g_sQueueThreadID, sizeof(g_sQueueThreadID), sThreadID);

	g_hSendQueue.Clear();
	g_hSendQueue.PushString(g_sRoundHeader);
	QueueCodeBlockChunked(g_sRoundOutput);

	g_bQueueSending = true;
	SendNextQueuedMessage(0);
}

/* Splits the rows into ```txt blocks that each fit in one Discord message, without cutting a row. */
void QueueCodeBlockChunked(const char[] text)
{
	int iMaxBody = WEBHOOK_MSG_MAX_SIZE - 1 - strlen(CODE_BLOCK_START) - strlen(CODE_BLOCK_END);

	char sChunk[WEBHOOK_MSG_MAX_SIZE], sLine[512], sMessage[WEBHOOK_MSG_MAX_SIZE];
	int iPos = 0, iLength = strlen(text);

	while (iPos < iLength)
	{
		int iLineLength = FindCharInString(text[iPos], '\n');
		if (iLineLength == -1)
			iLineLength = iLength - iPos;

		strcopy(sLine, iLineLength + 1 < sizeof(sLine) ? iLineLength + 1 : sizeof(sLine), text[iPos]);
		iPos += iLineLength + 1;

		int iChunkLength = strlen(sChunk);
		if (iChunkLength > 0 && iChunkLength + 1 + strlen(sLine) > iMaxBody)
		{
			FormatEx(sMessage, sizeof(sMessage), "%s%s%s", CODE_BLOCK_START, sChunk, CODE_BLOCK_END);
			g_hSendQueue.PushString(sMessage);
			sChunk[0] = '\0';
			iChunkLength = 0;
		}

		if (iChunkLength > 0)
			StrCat(sChunk, sizeof(sChunk), "\n");

		StrCat(sChunk, sizeof(sChunk), sLine);
	}

	if (sChunk[0])
	{
		FormatEx(sMessage, sizeof(sMessage), "%s%s%s", CODE_BLOCK_START, sChunk, CODE_BLOCK_END);
		g_hSendQueue.PushString(sMessage);
	}
}

/* Messages go out one at a time so they reach Discord in order. */
void SendNextQueuedMessage(int retries)
{
	if (g_hSendQueue.Length == 0)
	{
		g_bQueueSending = false;
		return;
	}

	char sMessage[WEBHOOK_MSG_MAX_SIZE];
	g_hSendQueue.GetString(0, sMessage, sizeof(sMessage));

	Webhook webhook = new Webhook(sMessage);

	char sUsername[128], sAvatar[256];
	g_cvUsername.GetString(sUsername, sizeof(sUsername));
	g_cvAvatar.GetString(sAvatar, sizeof(sAvatar));

	if (sUsername[0])
		webhook.SetUsername(sUsername);

	if (sAvatar[0])
		webhook.SetAvatarURL(sAvatar);

	DataPack pack = new DataPack();
	pack.WriteCell(retries);

	webhook.Execute(g_sQueueWebhookURL, OnDiscordWebhookExecuted, pack, g_sQueueThreadID);
	delete webhook;
}

void DropQueuedMessage()
{
	if (g_hSendQueue.Length > 0)
		g_hSendQueue.Erase(0);

	SendNextQueuedMessage(0);
}

public void OnDiscordWebhookExecuted(HTTPResponse response, DataPack pack)
{
	pack.Reset();
	int retries = pack.ReadCell();
	delete pack;

	HTTPStatus status = response.Status;
	if (status == HTTPStatus_OK || status == HTTPStatus_NoContent)
	{
		DropQueuedMessage();
		return;
	}

	// A 4xx other than 429 (bad webhook, invalid payload) will fail again: don't retry it.
	if (status >= HTTPStatus_BadRequest && status < HTTPStatus_InternalServerError && status != HTTPStatus_TooManyRequests)
	{
		LogError("%s Failed to send webhook (status: %d)", PLUGIN_TAG, status);
		DropQueuedMessage();
		return;
	}

	int iMaxRetries = g_cvWebhookRetry.IntValue;
	if (retries >= iMaxRetries)
	{
		LogError("%s Failed to send webhook after %d retries (status: %d)", PLUGIN_TAG, retries, status);
		DropQueuedMessage();
		return;
	}

	float fDelay = GetRetryDelaySeconds(response);
	if (fDelay > MAX_RETRY_DELAY)
	{
		LogError("%s Dropping message: Discord asked to wait %.0f sec (status: %d).", PLUGIN_TAG, fDelay, status);
		DropQueuedMessage();
		return;
	}

	LogMessage("%s Webhook failed (status: %d). Retry %d/%d in %.2f sec.", PLUGIN_TAG, status, retries + 1, iMaxRetries, fDelay);

	DataPack timerPack = new DataPack();
	timerPack.WriteCell(retries + 1);
	CreateTimer(fDelay, Timer_RetryDiscordWebhook, timerPack, TIMER_DATA_HNDL_CLOSE);
}

/* Discord gives the delay in a header on 429, and in the JSON body as a fallback. */
float GetRetryDelaySeconds(HTTPResponse response)
{
	char sValue[32];
	float fDelay = 0.0;

	if (response.GetHeader("Retry-After", sValue, sizeof(sValue)))
		fDelay = StringToFloat(sValue);

	if (fDelay <= 0.0 && response.GetHeader("X-RateLimit-Reset-After", sValue, sizeof(sValue)))
		fDelay = StringToFloat(sValue);

	// Only a 429 is sure to carry a JSON body; Data throws on anything else.
	if (fDelay <= 0.0 && response.Status == HTTPStatus_TooManyRequests)
	{
		JSONObject json = view_as<JSONObject>(response.Data);
		if (json != null && json.HasKey("retry_after"))
			fDelay = json.GetFloat("retry_after");
	}

	return fDelay > 0.0 ? fDelay : DEFAULT_RETRY_DELAY;
}

public Action Timer_RetryDiscordWebhook(Handle timer, DataPack pack)
{
	// The pack is freed by TIMER_DATA_HNDL_CLOSE.
	pack.Reset();
	SendNextQueuedMessage(pack.ReadCell());
	return Plugin_Stop;
}
