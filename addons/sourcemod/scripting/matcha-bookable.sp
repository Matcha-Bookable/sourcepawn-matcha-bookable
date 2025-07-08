#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <SteamWorks>
#include <dbi>
#include <morecolors>
#include <anyhttp>

// External natives
#include <logstf>
#include <demostf>

#define NAME_LENGTH 16
#define IP_LENGTH 16
#define PASSWORD_LENGTH 10

#define MAX_AFK_PLAYERS 2
#define MAX_AFK_TIME 600.0
#define MAX_SDR_RETRIES 30

// Matcha API endpoints (instance only)
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
int g_retry = 0;

char g_hostname[NAME_LENGTH];
char g_mapname[MAX_BUFFER_LENGTH];
int g_playerCount;

char g_publicIP[IP_LENGTH];
char g_sdrIP[IP_LENGTH];

int g_publicPort;
char g_sdrPort[6];
int g_rconPort;
int g_stvPort;

char g_svpassword[PASSWORD_LENGTH + 1];
char g_rconpassword[PASSWORD_LENGTH + 1];

Handle g_hAFKTimer;

/*
    Responsible for facilitating the upload of logs and demos
*/
bool g_bLogUploaded = false;
bool g_bDemoUploaded = false;
bool g_bLogRecentlyFailed = false;
bool g_bDemoRecentlyFailed = false;

char g_LogID[16];
char g_DemoID[16];

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
    version = "0.1.3",
    url = "https://discord.gg/8ysCuREbWQ"
};

/*
    Start of Plugin
*/
public void OnPluginStart() {
    // Preparation
    GeneratePasswords(); // Create passwords

    // Commands
    RegConsoleCmd("sm_sdr", CMD_SdrRequest, "Output the SDR string"); // SDR command

    // Final
    CreateTimer(10.0, WaitForSteamInfo, 0, TIMER_REPEAT);
}

public void OnMapStart() {
    if (g_publicIP[0] != '\0') {
        UploadMapInfo();
    }
}

public void OnClientConnected() {
    g_playerCount++;
    SetAFKTimer();
}

/*
    Incrementing playercount here causes inaccuracy, if client crashes while loading playercount would get incremented but not decremented
*/
public void OnClientPostAdminCheck(int client){
    if (!IsRealPlayer(client)) {
        return; // fake client
    }
    
    SendPlayerInfo(client); // Send info
}

public void OnClientDisconnect(){
    g_playerCount--;
    SetAFKTimer();
}

public Action OnServerEmpty(Handle timer){
    MC_PrintToChatAll("{red}-- SERVER IS EMPTY, INSTANCE TERMINATING --");
    PrintToServer("-- Server is empty --");
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
    strcopy(g_LogID, sizeof(g_LogID), logid);

    if (g_bDemoRecentlyFailed) { // Demo attempted but failed 
        SendGamesInfo(g_LogID, g_LogURL, _, "");
        resetLogAndDemoStatus();        
    }

    if (g_bLogUploaded && g_bDemoUploaded) { // Both successfully uploaded
        g_bLogUploaded = false;
        g_bDemoUploaded = false;

        SendGamesInfo(g_LogID, g_LogURL, g_DemoID, g_DemoURL);   
        resetLogAndDemoStatus();
    }

    return;
}

/*
    Calls when demos are uploaded or failed to upload (DEMOS.TF)
    Requires at least 5 minutes of recordings
*/
public void DemoUploaded(bool success, const char[] demoid, const char[] url) {
    if (g_bLogRecentlyFailed && g_bDemoRecentlyFailed) { // if both failed recently
        resetLogAndDemoStatus();
    }

    if (!success) {
        // Sometimes this will get triggered by rup and unrup fast
        // Need to account for this

        // Give it 3 minutes for timeout
        CreateTimer(180.0, Timer_DemoUploadHandle, _);
        return;
    }

    g_bDemoUploaded = true;
    g_bDemoRecentlyFailed = false;
    strcopy(g_DemoID, sizeof(g_DemoID), demoid); 
    strcopy(g_DemoURL, sizeof(g_DemoURL), url);

    if (g_bLogRecentlyFailed) { // Logstf attempted but failed
        /*
            Usually the only reason for it to fail is due to the websites being down
            It doesn't matter if demo uploaded, logid is more important
        */
        resetLogAndDemoStatus(); 
    }

    if (g_bLogUploaded && g_bDemoUploaded) {
        g_bLogUploaded = false;
        g_bDemoUploaded = false;

        SendGamesInfo(g_LogID, g_LogURL, g_DemoID, g_DemoURL);
        resetLogAndDemoStatus();
    }

    return;
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
    if (StrEqual(g_sdrIP, "?.?.?.?")) {
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
    PrintToServer("[MatchaAPI] Generating passwords...");
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
    PrintToServer("[MatchaAPI] Passwords changed.");
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

    // SDR
    GetFakeIP(g_sdrIP, sizeof(g_sdrIP), g_sdrPort, sizeof(g_sdrPort));

    // Respective port
    g_publicPort = GetConVarInt(FindConVar("hostport"));
    g_rconPort= g_publicPort; // assume its the same (99% of the time)
    g_stvPort = GetConVarInt(FindConVar("tv_port"));
}

public Action WaitForSteamInfo(Handle timer, int retry){
    bool gotIP = GetPublicIP(g_publicIP, sizeof(g_publicIP));
    bool gotFakeIP = GetFakeIP(g_sdrIP, sizeof(g_sdrIP), g_sdrPort, sizeof(g_sdrPort));
    
    g_playerCount = GetPlayerCount();

    if (gotIP && gotFakeIP){
        PrintToServer("[MatchaAPI] All conditions met, uploading server details (SDR=1) and updating status (START).");

        GetCvar();
        UploadServerDetails(1); // Upload the details first before confirming
        
        SetAFKTimer();
        
        return Plugin_Stop;
    }
    else if (g_retry == MAX_SDR_RETRIES){
        PrintToServer("[MatchaAPI] Max SDR retries reached, uploading server details (SDR=0).");

        GetCvar();
        UploadServerDetails(0);
        
        SetAFKTimer();
        
        return Plugin_Stop;
    }
    else{
        PrintToServer("[MatchaAPI] Retrying... (%d/%d)", g_retry, MAX_SDR_RETRIES);
        g_retry++;
        
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

    AnyHttpRequest req = AnyHttp.CreatePost(API_UPLOADPLAYERSINFO_URL);
    req.PutString("apikey", API_SECRET_KEY);
    req.PutString("address", g_publicIP);
    req.PutString("steamid2", sid2);
    req.PutString("steamid3", sid3);
    req.PutString("username", username);
    req.PutString("ipv4", ipv4);
    req.PutString("map", g_mapname);

    AnyHttp.Send(req, HandleRequest);
}

/*
    Endpoint: instance/uploadserverinfo
*/
void UploadMapInfo() {
    GetCvar();
    GetCurrentMap(g_mapname, sizeof(g_mapname));

    // debug
    PrintToServer("[MatchaAPI] Uploading map info...");

    AnyHttpRequest req = AnyHttp.CreatePost(API_UPLOADSERVERINFO_URL);
    req.PutString("apikey", API_SECRET_KEY);
    req.PutString("address", g_publicIP);
    req.PutString("map", g_mapname);

    AnyHttp.Send(req, HandleRequest);
}

/*
    Endpoint: instance/uploadserverinfo
*/
void UploadServerDetails(int sdr) {
    // debug
    PrintToServer("[MatchaAPI] Uploading server details...");

    AnyHttpRequest req = AnyHttp.CreatePost(API_UPLOADSERVERINFO_URL);
    req.PutString("hostname", g_hostname);
    req.PutString("address", g_publicIP);
    
    char stvPortStr[6];
    char rconPortStr[6];
    Format(stvPortStr, sizeof(stvPortStr), "%d", g_stvPort);
    Format(rconPortStr, sizeof(rconPortStr), "%d", g_rconPort);
    
    req.PutString("apikey", API_SECRET_KEY);
    req.PutString("stv_port", stvPortStr);
    req.PutString("rcon_port", rconPortStr);
    req.PutString("sv_password", g_svpassword);
    req.PutString("rcon_password", g_rconpassword);
    req.PutString("map", g_mapname);

    // Add SDR data if available
    if (sdr) {
        // fking trim ts
        TrimString(g_sdrPort);

        req.PutString("sdr_ipv4", g_sdrIP);
        req.PutString("sdr_port", g_sdrPort);
    }

    AnyHttp.Send(req, HandleRequestReady);
}

/*
    Endpoint: instance/updateserverstatus
*/
void UpdateServerStatus(int status) {
    // debug
    PrintToServer("[MatchaAPI] Updating server status...");

    AnyHttpRequest req = AnyHttp.CreatePost(API_UPDATESERVERSTATUS_URL);
    req.PutString("address", g_publicIP);
    
    char statusStr[2];
    Format(statusStr, sizeof(statusStr), "%d", status);

    req.PutString("apikey", API_SECRET_KEY);
    req.PutString("status", statusStr);

    PrintToServer("[MatchaAPI] Sending status update");

    AnyHttp.Send(req, HandleRequest);
}

/*
    Endpoint: instance/uploadgameinfo
*/
void SendGamesInfo(char[] logid, const char[] logurl, char[] demoid = "", const char[] demourl) {
    // debug
    PrintToServer("[MatchaAPI] Sending game info...");

    AnyHttpRequest req = AnyHttp.CreatePost(API_UPLOADGAMESINFO_URL);
    req.PutString("apikey", API_SECRET_KEY);
    req.PutString("address", g_publicIP);
    req.PutString("logid", logid);
    req.PutString("logurl", logurl);

    // Add demo data if valid
    if (demourl[0] != '\0') {
        req.PutString("demoid", demoid);
        req.PutString("demourl", demourl);
    }

    AnyHttp.Send(req, HandleRequest);
}

/*
    Callback for HTTP requests, don't need to read the response. Only the status
*/
void HandleRequest(bool success, const char[] contents, int responseCode) {
    if (!success) {
        PrintToServer("[MatchaAPI] HTTP request failed with response code: %d", responseCode);
        return;
    }

    // Debug
    PrintToServer("[MatchaAPI] HTTP request successful with response code: %d", responseCode);

    // If you need to handle the contents, you can do so here
    // For now, we will just print it
    if (strlen(contents) > 0) {
        PrintToServer("[MatchaAPI] Response contents: %s", contents);
    }
}

/*
    Callback for uploading server info before confirming its ready
*/
void HandleRequestReady(bool success, const char[] contents, int responseCode) {
    if (strlen(contents) > 0) {
        PrintToServer("[MatchaAPI] Response contents: %s", contents);
    }
    
    if (responseCode == 200) {
        UpdateServerStatus(API_START); // Sends the ready status after its updated
        PrintToServer("[MatchaAPI] HTTP request successful with response code: %d", responseCode);
    }
    else {
        UpdateServerStatus(API_STOP);
        PrintToServer("[MatchaAPI] HTTP request failed with response code: %d", responseCode);
    }
}

/*
    Resets the variables controlling logs and demos upload
*/
void resetLogAndDemoStatus() {
    g_bLogUploaded = false;
    g_bDemoUploaded = false;
    g_bLogRecentlyFailed = false;
    g_bDemoRecentlyFailed = false;

    g_LogID = "";
    g_DemoID = "";

    g_LogURL = "";
    g_DemoURL = "";

    PrintToServer("[MatchaAPI] Log and Demo status reset.");
}

void SetAFKTimer(){
    if (g_playerCount < MAX_AFK_PLAYERS && g_hAFKTimer == INVALID_HANDLE){
        g_hAFKTimer = CreateTimer(MAX_AFK_TIME, OnServerEmpty, _);
    }
    if (g_playerCount >= MAX_AFK_PLAYERS && g_hAFKTimer != INVALID_HANDLE){
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

/*
    Return current players
*/
int GetPlayerCount() {
    int count = 0;
    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i) && !IsFakeClient(i)) {
            count++;
        }
    }
    return count;
}

/*
    Steamworks extension for retrieving public ipv4
*/
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

/*
    String separation for retrieving sdr
*/
bool GetFakeIP(char[] ip_buffer, int ip_size, char[] port_buffer, int port_size) {
    /*
        Kidnapped from https://github.com/spiretf/sdrconnect/blob/main/plugin/sdrconnect.sp
    */
    char serverIp[22];
    char status[1024];
    char lines[3][100]; // first 3 lines
    char ips[8][50];
    ServerCommandEx(status, sizeof(status), "status");
    ExplodeString(status, "\n", lines, sizeof(lines), sizeof(lines[]));
    ExplodeString(lines[2], " ", ips, sizeof(ips), sizeof(ips[]));
    strcopy(serverIp, sizeof(serverIp), ips[3]);

    if (StrEqual(serverIp, "?.?.?.?:?")) {
        return false;
    }

    // explode the string to separate the ip and port
    char fakeipSeparate[2][16];

    ExplodeString(serverIp, ":", fakeipSeparate, sizeof(fakeipSeparate), sizeof(fakeipSeparate[]));
    strcopy(ip_buffer, ip_size, fakeipSeparate[0]);
    strcopy(port_buffer, port_size, fakeipSeparate[1]);

    return true;
}
