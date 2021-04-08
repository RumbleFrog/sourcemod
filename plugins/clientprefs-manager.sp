/**
 * vim: set ts=4 :
 * =============================================================================
 * SourceMod Clientprefs Manager
 * Creates a map vote when the required number of players have requested one.
 *
 * SourceMod (C)2004-2014 AlliedModders LLC.  All rights reserved.
 * =============================================================================
 *
 * This program is free software; you can redistribute it and/or modify it under
 * the terms of the GNU General Public License, version 3.0, as published by the
 * Free Software Foundation.
 * 
 * This program is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more
 * details.
 *
 * You should have received a copy of the GNU General Public License along with
 * this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 * As a special exception, AlliedModders LLC gives you permission to link the
 * code of this program (as well as its derivative works) to "Half-Life 2," the
 * "Source Engine," the "SourcePawn JIT," and any Game MODs that run on software
 * by the Valve Corporation.  You must obey the GNU General Public License in
 * all respects for all other code used.  Additionally, AlliedModders LLC grants
 * this exception to all derivative works.  AlliedModders LLC defines further
 * exceptions, found in LICENSE.txt (as of this writing, version JULY-31-2007),
 * or <http://www.sourcemod.net/license.php>.
 *
 * Version: $Id$
 */

#include <sourcemod>
#include <clientprefs>

#pragma semicolon 1
#pragma newdecls required

#define COOKIE_MAX_NAME_LENGTH 30
#define COOKIE_MAX_DESC_LENGTH 255
#define COOKIE_MAX_VALUE_LENGTH 100

public Plugin myinfo =
{
	name = "Clientprefs Manager",
	author = "AlliedModders LLC",
	description = "Provides API access to clientprefs",
	version = SOURCEMOD_VERSION,
	url = "http://www.sourcemod.net/"
};

Database g_DB;
GlobalForward g_hOnClientCookiesCached;
bool g_bLateLoaded;

enum Driver
{
    Driver_MySQL,
    Driver_SQLite,
    Driver_PgSQL,
}

enum CookieState
{
    Unknown = 0,
    Loaded,
    Pending,
}

enum struct CookieData
{
    char value[COOKIE_MAX_VALUE_LENGTH + 1];
    bool changed;
    int timestamp;
}

enum struct ICookie
{
    char name[COOKIE_MAX_NAME_LENGTH + 1];
    char description[COOKIE_MAX_DESC_LENGTH + 1];
    
    // Auto incremental field
    int db_id;

    // Array of CookieData
    ArrayList data;

    CookieAccess access;
}

enum struct CookieMonster
{
    // Map of ICookie
    StringMap cookies;

    // Each AL contains strings of cookie keys that the client has loaded
    ArrayList client_data[MAXPLAYERS + 1];

    CookieState state[MAXPLAYERS + 1];

    bool FindCookie(const char[] name, ICookie cookie)
    {
        return this.cookies.GetArray(name, cookie, sizeof ICookie);
    }

    void AppendCookieData(const char[] name, CookieData data)
    {
        ICookie cookie;

        this.FindCookie(name, cookie);
        cookie.data.PushArray(data);
        
        this.SetCookie(name, cookie);
    }

    void SetCookie(const char[] name, ICookie cookie)
    {
        this.cookies.SetArray(name, cookie, sizeof ICookie);
    }

    void SetState(int client, CookieState state)
    {
        this.state[client] = state;
    }

    CookieState GetState(int client)
    {
        return this.state[client];
    }

    void CreateCookie(const char[] name, const char[] description, CookieAccess access)
    {
        ICookie cookie;

        if (this.FindCookie(name, cookie))
        {
            strcopy(cookie.description, sizeof ICookie::description, description);
            cookie.access = access;

            this.SetCookie(name, cookie);

            return;
        }

        cookie.access = access;
        cookie.data = new ArrayList(sizeof CookieData);
        cookie.db_id = -1;
        strcopy(cookie.name, sizeof ICookie::name, name);
        strcopy(cookie.description, sizeof ICookie::description, description);

        this.SetCookie(name, cookie);
        
        InsertCookie(cookie);
    }
}

Driver g_driver;
CookieMonster g_CookieMonster;

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    // TODO: Natives

    RegPluginLibrary("clientprefs");

    g_bLateLoaded = late;

    return APLRes_Success;
}

public void OnPluginStart()
{
    g_hOnClientCookiesCached = new GlobalForward("OnClientCookiesCached", ET_Ignore, Param_Cell);

    g_CookieMonster.cookies = new StringMap();

    for (int i = 1; i < MaxClients; i += 1)
        g_CookieMonster.client_data[i] = new ArrayList(ByteCountToCells(COOKIE_MAX_NAME_LENGTH + 1));

    if (SQL_CheckConfig("clientprefs"))
        Database.Connect(OnDatabaseConnect, "clientprefs");
    else
        Database.Connect(OnDatabaseConnect, "storage-local");
}

public void OnDatabaseConnect(Database db, const char[] error, any data)
{
    if (db == null)
        SetFailState("Unable to connect to database: %s", error);

    g_DB = db;

    DBDriver driver = db.Driver;

    char identifier[16];
    driver.GetIdentifier(identifier, sizeof identifier);

    delete driver;

    if (strcmp(identifier, "sqlite") == 0)
    {
        g_driver = Driver_SQLite;

        db.Query(
            OnTableCreate,
            "CREATE TABLE IF NOT EXISTS sm_cookies  \
            ( \
                id INTEGER PRIMARY KEY AUTOINCREMENT, \
                name varchar(30) NOT NULL UNIQUE, \
                description varchar(255), \
                access INTEGER \
            )"
        );

        db.Query(
            OnTableCreate,
            "CREATE TABLE IF NOT EXISTS sm_cookie_cache \
            ( \
                player varchar(65) NOT NULL, \
                cookie_id int(10) NOT NULL, \
                value varchar(100), \
                timestamp int, \
                PRIMARY KEY (player, cookie_id) \
            )"
        );
    }
    else if (strcmp(identifier, "mysql") == 0)
    {
        g_driver = Driver_MySQL;

        db.Query(
            OnTableCreate,
            "CREATE TABLE IF NOT EXISTS sm_cookies \
            ( \
                id INTEGER unsigned NOT NULL auto_increment, \
                name varchar(30) NOT NULL UNIQUE, \
                description varchar(255), \
                access INTEGER, \
                PRIMARY KEY (id) \
            )"
        );

        db.Query(
            OnTableCreate,
            "CREATE TABLE IF NOT EXISTS sm_cookie_cache \
            ( \
                player varchar(65) NOT NULL, \
                cookie_id int(10) NOT NULL, \
                value varchar(100), \
                timestamp int NOT NULL, \
                PRIMARY KEY (player, cookie_id) \
            )"
        );
    }
    else if (strcmp(identifier, "pgsql") == 0)
    {
        g_driver = Driver_PgSQL;

        db.Query(
            OnTableCreate,
            "CREATE TABLE IF NOT EXISTS sm_cookies \
            ( \
                id serial, \
                name varchar(30) NOT NULL UNIQUE, \
                description varchar(255), \
                access INTEGER, \
                PRIMARY KEY (id) \
            )"
        );

        db.Query(
            OnTableCreate,
            "CREATE TABLE IF NOT EXISTS sm_cookie_cache \
            ( \
                player varchar(65) NOT NULL, \
                cookie_id int NOT NULL, \
                value varchar(100), \
                timestamp int NOT NULL, \
                PRIMARY KEY (player, cookie_id) \
            )"
        );

        db.Query(
            OnTableCreate,
            "CREATE OR REPLACE FUNCTION add_or_update_cookie(in_player VARCHAR(65), in_cookie INT, in_value VARCHAR(100), in_time INT) RETURNS VOID AS \
                $$ \
                BEGIN \
                    LOOP \
                    UPDATE sm_cookie_cache SET value = in_value, timestamp = in_time WHERE player = in_player AND cookie_id = in_cookie; \
                    IF found THEN \
                        RETURN; \
                    END IF; \
                    BEGIN \
                        INSERT INTO sm_cookie_cache (player, cookie_id, value, timestamp) VALUES (in_player, in_cookie, in_value, in_time); \
                        RETURN; \
                    EXCEPTION WHEN unique_violation THEN \
                    END; \
                    END LOOP; \
                END; \
                $$ LANGUAGE plpgsql;"
        );
    }
    else
        SetFailState("Unsupported driver \"%s\"", identifier);

    if (g_bLateLoaded)
    {
        char auth[32];

        for (int i = 1; i < MaxClients; i += 1)
        {
            CookieState state = g_CookieMonster.GetState(i);

            if (state != Unknown)
                continue;

            if (!IsClientAuthorized(i))
                continue;

            if (!GetClientAuthId(i, AuthId_Steam2, auth, sizeof auth))
                continue;

            OnClientAuthorized(i, auth);
        }
    }
}

public void OnTableCreate(Database db, DBResultSet results, const char[] error, any data)
{
    if (results == null)
        SetFailState("Unable to create tables/function: %s", error);
}

public void OnClientAuthorized(int client, const char[] auth)
{
    g_CookieMonster.SetState(client, Pending);
    LoadClientCookies(client, auth);
}

public void OnClientDisconnect(int client)
{
    char auth[32];

    if (!GetClientAuthId(client, AuthId_Steam2, auth, sizeof auth))
        return;

    ICookie cookie;
    CookieData data;

    char name[COOKIE_MAX_NAME_LENGTH + 1];

    for (int i = 0; i < g_CookieMonster.client_data[client].Length; i += 1)
    {
        g_CookieMonster.client_data[client].GetString(i, name, sizeof name);
        g_CookieMonster.FindCookie(name, cookie);

        cookie.data.GetArray(client, data);

        if (!data.changed || cookie.db_id == -1)
            continue;

        InsertCookieData(client, cookie.db_id, data);
    }

    g_CookieMonster.SetState(client, Unknown);
    g_CookieMonster.client_data[client].Clear();
}

void InsertCookie(ICookie cookie)
{
    char query[256];

    switch (g_driver)
    {
        case Driver_MySQL:
            g_DB.Format(
                query,
                sizeof query,
                "INSERT IGNORE INTO sm_cookies (name, description, access) \
				VALUES (\"%s\", \"%s\", %d)",
                cookie.name,
                cookie.description,
                cookie.access
            );
        case Driver_SQLite:
            g_DB.Format(
                query,
                sizeof query,
                "INSERT OR IGNORE INTO sm_cookies (name, description, access) \
				VALUES ('%s', '%s', %d)",
                cookie.name,
                cookie.description,
                cookie.access
            );
        case Driver_PgSQL:
            g_DB.Format(
                query,
                sizeof query,
                "INSERT INTO sm_cookies (name, description, access) \
				VALUES ('%s', '%s', %d)",
                cookie.name,
                cookie.description,
                cookie.access
            );
    }

    DataPack p = new DataPack();
    p.WriteString(cookie.name);

    g_DB.Query(OnCookieInserted, query, p);
}

public void OnCookieInserted(Database db, DBResultSet results, const char[] error, DataPack p)
{
    char name[COOKIE_MAX_NAME_LENGTH + 1];
    p.ReadString(name, sizeof name);

    delete p;

    if (results == null)
        return;

    ICookie cookie;
    g_CookieMonster.FindCookie(name, cookie);
    cookie.db_id = results.InsertId;
    g_CookieMonster.SetCookie(name, cookie);
}

void InsertCookieData(int client, int cookie_id, CookieData data)
{
    char auth[32];

    if (!GetClientAuthId(client, AuthId_Steam2, auth, sizeof auth))
        return;
    
    char query[512];

    switch (g_driver)
    {
        case Driver_MySQL:
            g_DB.Format(
                query,
                sizeof query,
                "INSERT INTO sm_cookie_cache (player, cookie_id, value, timestamp) 	\
                VALUES (\"%s\", %d, \"%s\", %d)									\
                ON DUPLICATE KEY UPDATE											\
                value = \"%s\", timestamp = %d",
                auth,
                cookie_id,
                data.value,
                data.timestamp
            );
        case Driver_SQLite:
            g_DB.Format(
                query,
                sizeof query,
                "INSERT OR REPLACE INTO sm_cookie_cache						\
                (player, cookie_id, value, timestamp)						\
                VALUES ('%s', %d, '%s', %d)",
                auth,
                cookie_id,
                data.value,
                data.timestamp
            );
        case Driver_PgSQL:
            g_DB.Format(
                query,
                sizeof query,
                "SELECT add_or_update_cookie ('%s', %d, '%s', %d)",
                auth,
                cookie_id,
                data.value,
                data.timestamp
            );
    }

    g_DB.Query(OnCookieDataInserted, query);
}

// Previous clientprefs ext didn't care about insertion errors, not sure if we should start handling it now.
public void OnCookieDataInserted(Database db, DBResultSet results, const char[] error, any data) {}

void LoadClientCookies(int client, const char[] auth)
{
    char query[1024];

    g_DB.Format(
        query,
        sizeof query,
        "SELECT sm_cookies.name, sm_cookie_cache.value, sm_cookies.description, \
            sm_cookies.access, sm_cookie_cache.timestamp 	\
            FROM sm_cookies				\
            JOIN sm_cookie_cache		\
            ON sm_cookies.id = sm_cookie_cache.cookie_id \
            WHERE player = '%s'",
        auth
    );

    g_DB.Query(OnClientCookieLoaded, query, GetClientUserId(client));
}

public void OnClientCookieLoaded(Database db, DBResultSet results, const char[] error, int user_id)
{
    if (results == null)
        return;

    int client;

    if (!(client = GetClientOfUserId(user_id)))
        return;

    DBResult res;
    ICookie cookie;

    CookieAccess access;
    CookieData cookie_data;
    char name[COOKIE_MAX_NAME_LENGTH + 1], description[COOKIE_MAX_DESC_LENGTH + 1];

    while(results.MoreRows && results.FetchRow())
    {
        results.FetchString(0, name, sizeof name);
        results.FetchString(1, cookie_data.value, sizeof CookieData::value);
        
        cookie_data.timestamp = results.FetchInt(4, res);
        cookie_data.timestamp = res == DBVal_Data ? cookie_data.timestamp : 0;

        if (!g_CookieMonster.FindCookie(name, cookie))
        {
            results.FetchString(2, description, sizeof description);
            access = view_as<CookieAccess>(results.FetchInt(3));

            g_CookieMonster.CreateCookie(name, description, access);
        }
        
        g_CookieMonster.AppendCookieData(name, cookie_data);
        g_CookieMonster.client_data[client].PushString(name);
    }

    g_CookieMonster.SetState(client, Loaded);

    Call_StartForward(g_hOnClientCookiesCached);
    Call_PushCell(client);
    Call_Finish();
}

// TODO: Natives
// TODO: Menu
