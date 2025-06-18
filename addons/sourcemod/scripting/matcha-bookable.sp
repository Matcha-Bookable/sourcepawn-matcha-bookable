#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <ripext>
#include <SteamWorks>
#include <dbi>
#include <morecolors>
#include <env_variables>

// External natives
#include <logstf>
#include <demostf>

#define NAME_LENGTH 16
#define IP_LENGTH 16
#define PASSWORD_LENGTH 10

#define MAX_AFK_PLAYERS 2
#define MAX_AFK_TIME 600.0
#define MAX_SDR_RETRIES 10

// Matcha API endpoints
#define API_UPLOADSERVERINFO_URL ""
#define API_UPDATESERVERSTATUS_URL ""
#define API_UPLOADPLAYERSINFO_URL ""
#define API_UPLOADGAMESINFO_URL ""

// API variables
#define API_SECRET_KEY ""
#define API_START 0
#define API_STOP 1

/*
    Global Variables
*/
char g_hostname[NAME_LENGTH];
char g_mapname[MAX_BUFFER_LENGTH];
int g_playercount;

char g_publicIP[IP_LENGTH];
char g_sdrIP[IP_LENGTH];

int g_publicPort;
int g_sdrPort;
int g_rconPort;
int g_stvPort;

char g_svpassword[PASSWORD_LENGTH + 1];
char g_rconpassword[PASSWORD_LENGTH + 1];

Address g_adrFakeIP;
Address g_adrFakePorts;

Handle g_hAFKTimer;

/*
    Responsible for facilitating the upload of logs and demos
*/
bool g_bLogUploaded = false;
bool g_bDemoUploaded = false;
bool g_bLogRecentlyFailed = false;
bool g_bDemoRecentlyFailed = false;

int g_LogID;
int g_DemoID;

char g_LogURL[128];
char g_DemoURL[256];


/*
    This plugin will simply handle the communication of server status as well as players details with the Matcha API 
    HTTP status 200 = successful

    It also logs the uploaded logstf and demostf details
*/
public Plugin myinfo =
{
    name = "Matcha Bookable",
    author = "avan & aqua",
    description = "Management of Matcha Bookable Servers",
    version = "0.1.2",
    url = "https://discord.gg/8ysCuREbWQ"
};

/*
    Start of Plugin
*/
public void OnPluginStart() {
    // Preparation
    GetAddresses(); // For SDR
    GeneratePasswords(); // Create passwords

    // Commands
    RegConsoleCmd("sm_sdr", CMD_SdrRequest, "Output the SDR string"); // SDR command

    // Final
    CreateTimer(5.0, WaitForSteamInfo, 0, TIMER_REPEAT);
}

public void OnMapStart() {
    UploadMapInfo();
}

public void OnClientConnected() {
    g_playercount++;
    CapturePlayerCount(); // Update count
    SetAFKTimer();
}

/*
    Incrementing playercount here causes inaccuracy, if client crashes while loading playercount would get incremented but not decremented
*/
public void OnClientPostAdminCheck(int client){
    SendPlayerInfo(client); // Send info
}

public void OnClientDisconnect(){
    g_playercount--;
    CapturePlayerCount(); // Update count
    SetAFKTimer();
}

public Action OnServerEmpty(Handle timer){
    UpdateServerStatus(API_STOP); // Call the url when empty
    g_hAFKTimer = INVALID_HANDLE; // Destroy timer
    return Plugin_Stop;
}

/*
    Calls when full logs are uploaded or failed to upload (LOGS.TF)
    Requires at least 4 players in teams and longer than 90 seconds of log capture 
*/
public void LogUploaded(bool success, const char[] logid, const char[] url) {
    if (g_bLogRecentlyFailed && g_bDemoRecentlyFailed) { // if both failed recently
        resetLogAndDemoStatus();
    }

    if (!success) {
        g_bLogRecentlyFailed = true;
        return;
    }

    g_bLogUploaded = true;
    g_bLogRecentlyFailed = false;
    g_LogID = StringToInt(logid, 10);
    strcopy(g_LogURL, sizeof(g_LogURL), url);

    if (g_bDemoRecentlyFailed) { // Demo attempted but failed 
        SendGamesInfo(g_LogID, g_LogURL, -1, "");
        resetLogAndDemoStatus();        
    }

    if (g_bLogUploaded && g_bDemoUploaded) { // Both successfully uploaded
        g_bLogUploaded, g_bDemoUploaded = false;

        SendGamesInfo(g_LogID, g_LogURL, g_DemoID, g_DemoURL);   
        resetLogAndDemoStatus();
    }

    return;
}

/*
    Calls when demos are uploaded or failed to upload (DEMOS.TF)
    Requires at least 5 minutes of recordings
*/
public int DemoUploaded(bool success, const char[] demoid, const char[] url) {
    if (g_bLogRecentlyFailed && g_bDemoRecentlyFailed) { // if both failed recently
        resetLogAndDemoStatus();
    }

    if (!success) {
        // Sometimes this will get triggered by rup and unrup fast
        // Need to account for this

        // Give it 3 minutes for timeout
        CreateTimer(180.0, Timer_DemoUploadHandle, _);
        return 0;
    }

    g_bDemoUploaded = true;
    g_bDemoRecentlyFailed = false;
    g_DemoID = StringToInt(demoid, 10);
    strcopy(g_DemoURL, sizeof(g_DemoURL), url);

    if (g_bLogRecentlyFailed) { // Logstf attempted but failed
        /*
            Usually the only reason for it to fail is due to the websites being down
            It doesn't matter if demo uploaded, logid is more important
        */
        resetLogAndDemoStatus(); 
    }

    if (g_bLogUploaded && g_bDemoUploaded) {
        g_bLogUploaded, g_bDemoUploaded = false;

        SendGamesInfo(g_LogID, g_LogURL, g_DemoID, g_DemoURL);
        resetLogAndDemoStatus();
    }

    return 0;
}

/*
    Timer callback for accounting false demo upload
    e.g. rup and unrup instantly
*/
public Action Timer_DemoUploadHandle(Handle timer) {
    if (g_bLogRecentlyFailed || g_bLogUploaded) { // If game were actually played
        g_bDemoRecentlyFailed = true;
    }

    return Plugin_Continue; 
}

/*
    Handles the !sdr command
*/
public Action CMD_SdrRequest(int client, int args) {
    // If no SDR
    if (!GetPublicIP(g_publicIP, sizeof(g_publicIP))) {
        MC_PrintToChat(client, 
        "{aqua}No SDR detected on this server.");
        return Plugin_Handled;
    }

    MC_PrintToChat(client, 
    "{aqua}connect %s:%d; password \"%s\"", g_sdrIP, g_sdrPort, g_svpassword);
    return Plugin_Handled;
}

/*
    Generate passwords for server and rcon then apply them
*/
void GeneratePasswords() {
    ConVar svPassword;
    ConVar rconPassword;

    svPassword = FindConVar("sv_password");
    rconPassword = FindConVar("rcon_password");

    // Apply the generated passwords
    GetRandomString(g_svpassword, PASSWORD_LENGTH);
    GetRandomString(g_rconpassword, PASSWORD_LENGTH);
    svPassword.SetString(g_svpassword);
    rconPassword.SetString(g_rconpassword);

    ServerCommand("sv_password %s", g_svpassword);
    ServerCommand("rcon_password %s", g_rconpassword);
}

/*
    Loads the addresses for SDR
*/
void GetAddresses() {
    Handle GameConfig;
    // Load the address file
    GameConfig = LoadGameConfigFile("matcha-bookable"); // addresses

    // Addresses of SDR (not actual IPs)
    g_adrFakeIP = GameConfGetAddress(GameConfig, "g_nFakeIP");
    g_adrFakePorts = GameConfGetAddress(GameConfig, "g_arFakePorts");
}

/*
    Main function for updating global cvars
*/
void GetCvar() {
    // Hostname
    ConVar cvarhostname = FindConVar("hostname");
    cvarhostname.GetString(g_hostname, sizeof(g_hostname));

    // Map
    GetCurrentMap(g_mapname, sizeof(g_mapname));

    // IP Addresses
    GetPublicIP(g_publicIP, sizeof(g_publicIP));
    GetFakeIP(g_sdrIP, sizeof(g_sdrIP));

    // Respective port
    g_publicPort = GetConVarInt(FindConVar("hostport"));
    g_sdrPort = GetFakePort(0);
    g_rconPort= g_publicPort; // assume its the same (99% of the time)
    g_stvPort = GetConVarInt(FindConVar("tv_port"));
    
    // Passwords already applied
    
    // Current Players
    g_playercount = GetClientCount();
}

public Action WaitForSteamInfo(Handle timer, int retry){
    bool gotIP = GetPublicIP(g_publicIP, sizeof(g_publicIP));

    if (g_adrFakeIP && g_adrFakePorts && gotIP){
        PrintToServer("[MatchaAPI] All conditions met, uploading server details (SDR=1) and updating status (START).");
        UploadServerDetails(1);
        UpdateServerStatus(API_START);
        return Plugin_Stop;
    }
    else if (retry == MAX_SDR_RETRIES){
        PrintToServer("[MatchaAPI] Max SDR retries reached, uploading server details (SDR=0).");
        UploadServerDetails(0);
        return Plugin_Stop;
    }
    else{
        PrintToServer("[MatchaAPI] Retrying... (%d/%d)", retry, MAX_SDR_RETRIES);
        retry++;
        return Plugin_Continue;
    }
}

/*
    Endpoint: instance/uploadplayersinfo
*/
void SendPlayerInfo(int client) {
    // steamid
    char sid2[32];
    GetClientAuthId(client, AuthId_Steam2, sid2, sizeof(sid2));

    char sid3[32];
    GetClientAuthId(client, AuthId_Steam3, sid3, sizeof(sid3));
    
    // username
    char username[NAME_LENGTH];
    GetClientName(client, username, sizeof(username));

    // ipv4
    char ipv4[IP_LENGTH];
    GetClientIP(client, ipv4, sizeof(ipv4));

    JSONObject requestformat = new JSONObject();
    requestformat.SetInt("port", g_publicPort);
    requestformat.SetString("steamid2", sid2);
    requestformat.SetString("steamid3", sid3);
    requestformat.SetString("username", username);
    requestformat.SetString("ipv4", ipv4);
    requestformat.SetString("map", g_mapname);

    char jsonBuffer[512];
    requestformat.ToString(jsonBuffer, sizeof(jsonBuffer));

    HTTPRequest request = new HTTPRequest(API_UPLOADPLAYERSINFO_URL);
    request.SetHeader("Authorization", "Bearer %s", API_SECRET_KEY); // Need api key to be authorized
    request.SetHeader("Content-Type", "application/json");
    request.Post(requestformat, HandleRequest);

    delete requestformat;
}

/*
    Endpoint: instance/uploadserverinfo
*/
void UploadMapInfo() {
    GetCurrentMap(g_mapname, sizeof(g_mapname));

    // Upload Map name
    JSONObject requestformat = new JSONObject();
    requestformat.SetString("map", g_mapname);

    HTTPRequest request = new HTTPRequest(API_UPLOADSERVERINFO_URL);
    request.SetHeader("Authorization", "Bearer %s", API_SECRET_KEY); // Need api key to be authorized
    request.SetHeader("Content-Type", "application/json");

    request.Post(requestformat, HandleRequest);

    delete requestformat;
}

/*
    Endpoint: instance/uploadserverinfo
*/
void CapturePlayerCount() {
    // Upload player count
    JSONObject requestformat = new JSONObject();
    requestformat.SetInt("players", g_playercount);

    HTTPRequest request = new HTTPRequest(API_UPLOADSERVERINFO_URL);
    request.SetHeader("Authorization", "Bearer %s", API_SECRET_KEY); // Need api key to be authorized
    request.SetHeader("Content-Type", "application/json");
    request.Post(requestformat, HandleRequest);

    delete requestformat;
}

/*
    Endpoint: instance/uploadserverinfo
*/
void UploadServerDetails(int sdr) {
    GetCvar(); // Update the CVAR to latest information

    JSONObject requestformat = new JSONObject();

    // 1 = sdr, 0 = no sdr
    if (sdr) {
        requestformat.SetString("sdr_ipv4", g_sdrIP);
        requestformat.SetInt("sdr_port", g_sdrPort);
    }

    requestformat.SetString("hostname", g_hostname);
    requestformat.SetInt("port", g_publicPort);
    requestformat.SetInt("stv_port", g_stvPort);
    requestformat.SetInt("rcon_port", g_rconPort);
    requestformat.SetString("sv_password", g_svpassword);
    requestformat.SetString("rcon_password", g_rconpassword);
    requestformat.SetString("map", g_mapname);
    requestformat.SetInt("players", g_playercount);

    char jsonBuffer[1024];
    requestformat.ToString(jsonBuffer, sizeof(jsonBuffer));
    PrintToServer("[MatchaAPI] JSON Body: %s", jsonBuffer);

    HTTPRequest request = new HTTPRequest(API_UPLOADSERVERINFO_URL);
    request.SetHeader("Authorization", "Bearer %s", API_SECRET_KEY);
    request.SetHeader("Content-Type", "application/json");
    request.Post(requestformat, HandleRequest);

    delete requestformat;
}

/*
    Endpoint: instance/updateserverstatus
*/
void UpdateServerStatus(int status) {
    JSONObject requestformat = new JSONObject();
    requestformat.SetInt("port", g_publicPort);
    requestformat.SetInt("status", status);

    char jsonBuffer[256];
    requestformat.ToString(jsonBuffer, sizeof(jsonBuffer));
    PrintToServer("[MatchaAPI] JSON Body: %s", jsonBuffer);

    HTTPRequest request = new HTTPRequest(API_UPDATESERVERSTATUS_URL);
    request.SetHeader("Authorization", "Bearer %s", API_SECRET_KEY);
    request.SetHeader("Content-Type", "application/json");
    request.Post(requestformat, HandleRequest);

    delete requestformat;
}

/*
    Endpoint: instance/uploadgameinfo
*/
void SendGamesInfo(int logid, const char[] logurl, int demoid, const char[] demourl) {
    JSONObject requestformat = new JSONObject();
    
    requestformat.SetInt("port", g_publicPort);

    // logid is the PK, therefore must be valid
    requestformat.SetInt("logid", logid);
    requestformat.SetString("logurl", logurl);

    if (demoid > 0 && demourl) { // If demoid and url are valid
        requestformat.SetInt("demoid", demoid);
        requestformat.SetString("demourl", demourl);
    }

    HTTPRequest request = new HTTPRequest(API_UPLOADGAMESINFO_URL);

    request.SetHeader("Authorization", "Bearer %s", API_SECRET_KEY); // Need api key to be authorized
    request.SetHeader("Content-Type", "application/json");

    request.Post(requestformat, HandleRequest);
}

/*
    Callback for HTTP requests, don't need to read the response. Only the status
    Documentation: https://forums.alliedmods.net/showthread.php?t=298024
*/
void HandleRequest(HTTPResponse response, any value) {
    if (response.Status != HTTPStatus_OK) {
        PrintToServer("[MatchaAPI] HTTP Request failed with status %d", response.Status);
        return;
    }

    PrintToServer("[MatchaAPI] HTTP status: %d", response.Status);
}

/*
    Resets the variables controlling logs and demos upload
*/
void resetLogAndDemoStatus() {
    g_bLogUploaded = false;
    g_bDemoUploaded = false;
    g_bLogRecentlyFailed = false;
    g_bDemoRecentlyFailed = false;

    g_LogID = 0;
    g_DemoID = 0;

    g_LogURL = "";
    g_DemoURL = "";

    PrintToServer("[MatchaAPI] Log and Demo status reset.");
}

void SetAFKTimer(){
    if (g_playercount < MAX_AFK_PLAYERS && g_hAFKTimer == INVALID_HANDLE){
        g_hAFKTimer = CreateTimer(MAX_AFK_TIME, OnServerEmpty, _);
    }
    if (g_playercount >= MAX_AFK_PLAYERS && g_hAFKTimer != INVALID_HANDLE){
        CloseHandle(g_hAFKTimer);
        g_hAFKTimer = INVALID_HANDLE;
    }
}

/*
    Tool for generating random string
*/
void GetRandomString(char[] buffer, int len){
    static char charList[] = "abcdefghijklmnopqrstuvwxyz0123456789";
    
    for (int i = 0; i <= len; i++){
        // Using GetURandomInt is "safer" for random number generation
        char randomChar;
        do {
            randomChar = charList[GetURandomInt() % (sizeof(charList) - 1)];
        } while (IsCharInArray(randomChar, buffer, i));
        
        buffer[i] = randomChar;
    }

    // Strings need to be null-terminated
    buffer[len] = '\0';
}

/*
    Helper function for checking if a character is in the string
*/
bool IsCharInArray(char c, char[] array, int size) {
    for (int i = 0; i < size; i++) {
        if (array[i] == c) {
            return true;
        }
    }
    return false;
}

bool GetPublicIP(char[] buffer, int size){
    int ipaddr[4];
    SteamWorks_GetPublicIP(ipaddr);

    if (ipaddr[0] != '\0'){
        Format(buffer, size, "%d.%d.%d.%d", ipaddr[0], ipaddr[1], ipaddr[2], ipaddr[3]);
        return true;
    }
    else{
        return false;
    }
}

void GetFakeIP(char[] buffer, int size){
    if (!g_adrFakeIP) {
        buffer[0] = '\0';
    }
    int ipaddr = LoadFromAddress(g_adrFakeIP, NumberType_Int32);

    int octet1 = (ipaddr >> 24) & 255;
    int octet2 = (ipaddr >> 16) & 255;
    int octet3 = (ipaddr >> 8) & 255;
    int octet4 = ipaddr & 255;

    Format(buffer, size, "%d.%d.%d.%d", octet1, octet2, octet3, octet4);
}

int GetFakePort(int num) {
    if (!g_adrFakePorts || num < 0 || num >= 2){
        return 0;
    }
    return LoadFromAddress(g_adrFakePorts + (num * 0x2), NumberType_Int16);
}