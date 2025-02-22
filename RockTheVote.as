#include "MenuVote"
#include "GameVotes"

// TODO:
// - dont show log message for <4 plaers on classic restart
// - reopen menu should close again or not show messsage

class RtvState {
	bool didRtv = false;	// player wants to rock the vote?
	string nom; 			// what map this player nominated
	int afkTime = 0;		// AFK players ignored for rtv requirement
}

CClientCommand forcertv("forcertv", "Lets admin force a vote", @consoleCmd);
CClientCommand cancelrtv("cancelrtv", "Lets admin cancel an ongoing RTV vote", @consoleCmd);
CClientCommand pastmaplist("pastmaplist", "Show recently played maps (up to g_ExcludePrevMapsNom)", @consoleCmd);
CClientCommand pastmaplistfull("pastmaplistfull", "Show recently played maps (up to g_ExcludePrevMapsNomMeme)", @consoleCmd);
CClientCommand set_nextmap("set_nextmap", "Set the next map cycle", @consoleCmd);
CClientCommand map("map", "Force a map change", @consoleCmd);
CClientCommand vote("vote", "Start a vote or reopen the vote menu", @consoleCmd);
CClientCommand poll("poll", "Start a custom poll", @consoleCmd);

CCVar@ g_SecondsUntilVote;
CCVar@ g_MaxMapsToVote;
CCVar@ g_VotingPeriodTime;
CCVar@ g_PercentageRequired;
CCVar@ g_ExcludePrevMaps;			// limit before a map can be randomly added to the RTV menu again
CCVar@ g_ExcludePrevMapsNom;		// limit for nomming a regular map again
CCVar@ g_ExcludePrevMapsNomMeme;	// limit for nomming a hidden/meme map again
CCVar@ g_EnableGameVotes;			// enable text menu replacements for the default game votes
CCVar@ g_EnableForceSurvivalVotes;	// enable semi-survival vote (requires ForceSurvival plugin)

// maps that can be nominated with a normal cooldown
const string votelistFile = "scripts/plugins/cfg/mapvote.cfg"; 
array<string> g_normalMaps;

// maps that have a large nom cooldown and never randomly show up in the vote menu
const string hiddenMapsFile = "scripts/plugins/cfg/hidden_nom_maps.txt";
array<string> g_hiddenMaps;

// previously played maps, to prevent nom'ing maps that were played too recently
const string previousMapsFile = "scripts/plugins/store/previous_maps.txt";
array<string> g_previousMaps;

array<RtvState> g_playerStates;
array<string> g_everyMap; // sorted combination of normal and hidden maps
array<string> g_randomRtvChoices; // normal votable maps which aren't in the previous map list
array<string> g_randomCycleMaps; // map cycle maps which aren't in the previous map list
array<string> g_nomList; // maps nominated by players
dictionary g_prevMapPosition; // maps a map name to its position in the previous map list (for faster nom menus)
dictionary g_memeMapsHashed; // for faster meme map checks
MenuVote::MenuVote g_rtvVote;
uint g_maxNomMapNameLength = 0; // used for even spacing in the full console map list
CScheduledFunction@ g_timer = null;

const float levelChangeDelay = 5.0f; // time in seconds to show intermission view before changing levels



void PluginInit() {

	g_Module.ScriptInfo.SetAuthor("w00tguy");
	g_Module.ScriptInfo.SetContactInfo("https://github.com/wootguy");
	g_Hooks.RegisterHook(Hooks::Player::ClientDisconnect, @ClientLeave);
	g_Hooks.RegisterHook(Hooks::Player::ClientSay, @ClientSay);
	g_Hooks.RegisterHook(Hooks::Game::MapChange, @MapChange);

	@g_SecondsUntilVote = CCVar("secondsUntilVote", 120, "Delay before players can RTV after map has started", ConCommandFlag::AdminOnly);
	@g_MaxMapsToVote = CCVar("iMaxMaps", 7, "How many maps can players nominate and vote for later", ConCommandFlag::AdminOnly);
	@g_VotingPeriodTime = CCVar("secondsToVote", 40, "How long can players vote for a map before a map is chosen", ConCommandFlag::AdminOnly);
	@g_PercentageRequired = CCVar("iPercentReq", 66, "0-100, percent of players required to RTV before voting happens", ConCommandFlag::AdminOnly);
	@g_ExcludePrevMaps = CCVar("iExcludePrevMaps", 6, "How many maps to previous maps to remember", ConCommandFlag::AdminOnly);
	@g_ExcludePrevMapsNom = CCVar("iExcludePrevMapsNomOnly", 6, "Exclude recently played maps from nominations", ConCommandFlag::AdminOnly);
	@g_ExcludePrevMapsNomMeme = CCVar("iExcludePrevMapsNomOnlyMeme", 6, "Exclude recently played maps from nominations (hidden maps)", ConCommandFlag::AdminOnly);
	@g_EnableGameVotes = CCVar("gameVotes", 0, "Text menu replacements for the default game votes", ConCommandFlag::AdminOnly);
	@g_EnableForceSurvivalVotes = CCVar("forceSurvivalVotes", 0, "Enable semi-survival vote (requires ForceSurvival plugin)", ConCommandFlag::AdminOnly);

	reset();
	
	g_Scheduler.SetInterval("autoStartRtvCheck", 1.0f, -1);
	g_Scheduler.SetInterval("reduceKillPenalties", 60*60, -1);
}

void MapInit() {
	g_SoundSystem.PrecacheSound("fvox/one.wav");
	g_SoundSystem.PrecacheSound("fvox/two.wav");
	g_SoundSystem.PrecacheSound("fvox/three.wav");
	g_SoundSystem.PrecacheSound("fvox/four.wav");
	g_SoundSystem.PrecacheSound("fvox/five.wav");
	g_SoundSystem.PrecacheSound("gman/gman_choose1.wav");
	g_SoundSystem.PrecacheSound("gman/gman_choose2.wav");
	g_SoundSystem.PrecacheSound("buttons/blip3.wav");
	
	reset();
	
	string randomMap = g_randomCycleMaps[Math.RandomLong(0, g_randomCycleMaps.size()-1)];
	println("[RTV] Random next map: " + randomMap);
	g_EngineFuncs.ServerCommand("mp_nextmap_cycle " + randomMap + "\n");
}

HookReturnCode MapChange() {
	writePreviousMapsList();
	g_Scheduler.RemoveTimer(g_timer);
	return HOOK_CONTINUE;
}

void reset() {
	g_playerStates.resize(0);
	g_playerStates.resize(33);
	g_nomList.resize(0);
	g_Scheduler.RemoveTimer(g_timer);
	loadAllMapLists();
	g_rtvVote.reset();
	g_gameVote.reset();
	g_lastGameVote = 0;
}

void loadCrossPluginAfkState() {
	CBaseEntity@ afkEnt = g_EntityFuncs.FindEntityByTargetname(null, "PlayerStatusPlugin");
	
	if (afkEnt is null) {
		return;
	}
	
	CustomKeyvalues@ customKeys = afkEnt.GetCustomKeyvalues();
	
	for ( int i = 1; i <= g_Engine.maxClients; i++ )
	{
		CustomKeyvalue key = customKeys.GetKeyvalue("$i_afk" + i);
		if (key.Exists()) {
			g_playerStates[i].afkTime = key.GetInteger();
		}
	}
}

void autoStartRtvCheck() {
	loadCrossPluginAfkState();

	if (canAutoStartRtv()) {
		startVote("(Requisito de voto reducido a " + getRequiredRtvCount() + " debido a los desconectados/jugadores AFK)");
	}
}



void print(string text) { g_Game.AlertMessage( at_console, text); }

void println(string text) { print(text + "\n"); }

void delay_print(EHandle h_plr, string message) {
	CBasePlayer @ plr = cast < CBasePlayer @ > (h_plr.GetEntity());
	if (plr !is null) {
		g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, message);
	}
}

void delay_print(EHandle h_plr, array<string> messages) {
	CBasePlayer @ plr = cast<CBasePlayer@>(h_plr.GetEntity());
	if (plr !is null) {
		for (uint i = 0; i < messages.size(); i++) {
			g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, messages[i]);
		}
	}
}

void playSoundGlobal(string file, float volume, int pitch) {
	for (int i = 1; i <= g_Engine.maxClients; i++) {
		CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(i);
		
		if (plr is null or !plr.IsConnected()) {
			continue;
		}
		
		g_SoundSystem.PlaySound(plr.edict(), CHAN_VOICE, file, volume, ATTN_NONE, 0, pitch, plr.entindex());
	}
}

void change_map(string mapname) {
	g_Log.PrintF("[RTV] Cambiando de mapa a " + mapname + "\n");
	g_EngineFuncs.ServerCommand("changelevel " + mapname + "\n");
}

void intermission() {
	NetworkMessage message(MSG_ALL, NetworkMessages::SVC_INTERMISSION, null);
	message.End();
}



int getCurrentRtvCount(bool excludeAfks=true) {
	int count = 0;

	for (uint i = 0; i < g_playerStates.size(); i++) {
		count += g_playerStates[i].didRtv and (g_playerStates[i].afkTime == 0 || !excludeAfks) ? 1 : 0;
	}
	
	return count;
}

int getRequiredRtvCount(bool excludeAfks=true) {
	uint playerCount = 0;
	
	for (int i = 1; i <= g_Engine.maxClients; i++) {
		CBasePlayer@ p = g_PlayerFuncs.FindPlayerByIndex(i);
		
		if (p is null or !p.IsConnected()) {
			continue;
		}
		
		if (g_playerStates[i].afkTime > 0 && excludeAfks) {
			continue; // PlayerStatus plugin says this player is afk
		}
		
		playerCount++;
	}
	
	float percent = g_PercentageRequired.GetInt() / 100.0f;
	return int(Math.Ceil(percent * float(playerCount)));
}

bool canAutoStartRtv() {
	if (g_rtvVote.status == MVOTE_NOT_STARTED && g_Engine.time > g_SecondsUntilVote.GetInt()) {
		if (getCurrentRtvCount() >= getRequiredRtvCount() and getCurrentRtvCount() > 0) {
			return true;
		}
	}
	
	return false;
}

array<string> generateRtvList() {
	array<string> rtvList;
	
	for (uint i = 0; i < g_nomList.size(); i++) {
		rtvList.insertLast(g_nomList[i]);
	}
	
	if (g_randomRtvChoices.size() == 0) {
		g_Log.PrintF("[RTV] All maps are excluded by the previous map list! Make sure g_ExcludePrevMaps value is less than the total nommable maps.\n");
		return rtvList;
	}
	
	for (int failsafe = 0; failsafe < 1000; failsafe++) {	
		if (int(rtvList.size()) >= g_MaxMapsToVote.GetInt() or int(rtvList.size()) >= 8) {
			break;
		}
		
		string randomMap = g_randomRtvChoices[Math.RandomLong(0, g_randomRtvChoices.size()-1)];
		
		if (rtvList.find(randomMap) == -1) {
			rtvList.insertLast(randomMap);
		}
	}
	
	return rtvList;
}

void startVote(string reason="") {
	array<string> rtvList = generateRtvList();

	array<MenuOption> menuOptions;
	
		menuOptions.insertLast(MenuOption("\\d(Cerrar menu)"));
	menuOptions[0].isVotable = false;
	
	for (uint i = 0; i < rtvList.size(); i++) {
		menuOptions.insertLast(MenuOption(rtvList[i]));
	}

	MenuVoteParams voteParams;
	voteParams.title = "RTV Vote\n";
	voteParams.options = menuOptions;
	voteParams.voteTime = g_VotingPeriodTime.GetInt();
	voteParams.forceOpen = false;
	@voteParams.optionCallback = @mapChosenCallback;
	@voteParams.thinkCallback = @voteThinkCallback;
	@voteParams.finishCallback = @voteFinishCallback;
	
	g_rtvVote.start(voteParams, null);
	g_PlayerFuncs.ClientPrintAll(HUD_PRINTTALK, reason);
	g_PlayerFuncs.ClientPrintAll(HUD_PRINTTALK, "[RTV] ¡Votación comenzada!\n");
}

void voteThinkCallback(MenuVote::MenuVote@ voteMenu, int secondsLeft) {
	int voteTime = g_VotingPeriodTime.GetInt();
	
	if (secondsLeft == voteTime)	{ playSoundGlobal("gman/gman_choose1.wav", 1.0f, 100); }
	else if (secondsLeft == 8)		{ playSoundGlobal("gman/gman_choose2.wav", 1.0f, 100); }
	else if (secondsLeft == 5)		{ playSoundGlobal("fvox/five.wav", 0.8f, 85); }
	else if (secondsLeft == 4)		{ playSoundGlobal("fvox/four.wav", 0.8f, 85); }
	else if (secondsLeft == 3)		{ playSoundGlobal("fvox/three.wav", 0.8f, 85); }
	else if (secondsLeft == 2)		{ playSoundGlobal("fvox/two.wav", 0.8f, 85); }
	else if (secondsLeft == 1)		{ playSoundGlobal("fvox/one.wav", 0.8f, 85); }
}

void voteFinishCallback(MenuVote::MenuVote@ voteMenu, MenuOption@ chosenOption, int resultReason) {
	string nextMap = chosenOption.value;
	
	if (resultReason == MVOTE_RESULT_TIED) {
		g_PlayerFuncs.ClientPrintAll(HUD_PRINTTALK, "[RTV] \"" + nextMap + "\" ha sido elegido al azar entre los mapas empatados.\n");
	} else if (resultReason == MVOTE_RESULT_NO_VOTES) {
		g_PlayerFuncs.ClientPrintAll(HUD_PRINTTALK, "[RTV] \"" + nextMap + "\" fue elegido al azar debido a que nadié votó.\n");
	} else {
		g_PlayerFuncs.ClientPrintAll(HUD_PRINTTALK, "[RTV] \"" + nextMap + "\" ha sido elegido!\n");
	}
	
	playSoundGlobal("buttons/blip3.wav", 1.0f, 70);
	
	g_Log.PrintF("[RTV] chose " + nextMap + "\n");
	
	// rarely the next cycle map is changed to instead of the rtv map. No idea why.
	g_EngineFuncs.ServerCommand("mp_nextmap_cycle " + nextMap + "\n");
	
	g_Scheduler.SetTimeout("intermission", MenuVote::g_resultTime);
	@g_timer = g_Scheduler.SetTimeout("change_map", MenuVote::g_resultTime + levelChangeDelay, nextMap);
}

void mapChosenCallback(MenuVote::MenuVote@ voteMenu, MenuOption@ chosenOption, CBasePlayer@ plr) {
	if (chosenOption !is null) {
		if (chosenOption.label == "\\d(Cerrar menu)") {
			g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCENTER, "Escribe \"RTV\" para abrir el menu\n");
			g_PlayerFuncs.ClientPrint(plr, HUD_PRINTTALK, "[RTV] Escribe RTV para abrir el menu nuevamente.\n");
			voteMenu.closeMenu(plr);
		}
	}
}


// return 1 = show chat, 2 = hide chat
int tryRtv(CBasePlayer@ plr) {
	int eidx = plr.entindex();
	
	if (g_rtvVote.status == MVOTE_FINISHED) {
		return 1;
	}
	
	if (g_rtvVote.status == MVOTE_IN_PROGRESS) {
		g_rtvVote.reopen(plr);
		return 2;
	}
	
	if (g_Engine.time < g_SecondsUntilVote.GetInt()) {
		int timeLeft = int(Math.Ceil(float(g_SecondsUntilVote.GetInt()) - g_Engine.time));
		g_PlayerFuncs.SayTextAll(plr, "[RTV] RTV estará disponible en " + timeLeft + " segundos. \n");
		return 2;
	}
	
	if (g_playerStates[eidx].didRtv) {
		g_PlayerFuncs.SayText(plr, "[RTV] " + getCurrentRtvCount() + " de " + getRequiredRtvCount() + " jugadores hasta que comience la votación.\n");
		return 2;
	}
	
	g_playerStates[eidx].didRtv = true;	
	
	if (getCurrentRtvCount() >= getRequiredRtvCount()) {
		sayRtvCount(plr);
		startVote();
	} else {
		sayRtvCount(plr);
	}
	
	return 2;
}

void sayRtvCount(CBasePlayer@ plr=null) {
	string msg = "[RTV] " + getCurrentRtvCount() + " de " + getRequiredRtvCount() + " jugadores hasta que comience la votación.";
	
	if (plr !is null) {
//		msg += "  -" + plr.pev.netname;
		if (g_playerStates[plr.entindex()].afkTime > 0) {
			msg += " (AFK)";
		}
	}
		
	g_PlayerFuncs.ClientPrintAll(HUD_PRINTTALK, msg + "\n");
}

void cancelRtv(CBasePlayer@ plr) {
	if (g_rtvVote.status != MVOTE_IN_PROGRESS) {
		g_PlayerFuncs.SayText(plr, "[RTV] No hay una votación para cancelar.\n");
		return;
	}
	
	for (uint i = 0; i < g_playerStates.size(); i++) {
		g_playerStates[i].didRtv = false;
	}
	
	g_rtvVote.cancel();
	
	g_PlayerFuncs.SayTextAll(plr, "[RTV] La votación fue cancelada por " + plr.pev.netname + "\n");
}

// returns number of maps needed to play before it can be nom'd
int getMapExcludeTime(string mapname, bool printMessage=false, CBasePlayer@ plr=null) {
	if (!g_prevMapPosition.exists(mapname)) {
		return 0;
	}

	int lastPrevIdx = 0;
	g_prevMapPosition.get(mapname, lastPrevIdx);
	
	bool isMemeMap = g_memeMapsHashed.exists(mapname);
	int mapsAgo = g_previousMaps.size() - lastPrevIdx;

	if (isMemeMap && mapsAgo < g_ExcludePrevMapsNomMeme.GetInt()) {
		int leftToPlay = (g_ExcludePrevMapsNomMeme.GetInt() - mapsAgo) + 1;
		if (printMessage) {
			g_PlayerFuncs.SayText(plr, "[RTV] \"" + mapname + "\" excluido hasta que jueguen " + leftToPlay + " otros mapas nominados con mas de 4 jugadores.\n");
		}
		return leftToPlay;
	}
	else if (!isMemeMap && mapsAgo < g_ExcludePrevMapsNom.GetInt()) {
		int leftToPlay = (g_ExcludePrevMapsNom.GetInt() - mapsAgo) + 1;
		if (printMessage) {
			g_PlayerFuncs.SayText(plr, "[RTV] \"" + mapname + "\" excluido hasta que jueguen " + leftToPlay + " otros mapas nominados con mas de 4 jugadores.\n");
		}
		return leftToPlay;
	}
	
	return 0;
}

void nomMenuCallback(CTextMenu@ menu, CBasePlayer@ plr, int page, const CTextMenuItem@ item) {
	if (item is null or plr is null or !plr.IsConnected() or g_rtvVote.status != MVOTE_NOT_STARTED) {
		return;
	}

	string nomChoice;
	item.m_pUserData.retrieve(nomChoice);
	tryNominate(plr, nomChoice);
}

void openNomMenu(CBasePlayer@ plr, string mapfilter, array<string> maps) {
	int eidx = plr.entindex();
			
	@g_menus[eidx] = CTextMenu(@nomMenuCallback);
	
	string title = "\\yMapas que contienen \"" + mapfilter + "\"\n";
	if (mapfilter.Length() == 0) {
		title = "\\yNomina un mapa de la lista\n";
	}
	g_menus[eidx].SetTitle(title);
	
	for (uint i = 0; i < maps.size(); i++) {
		string label = maps[i] + "\\y";
		
		int mapsLeft = getMapExcludeTime(maps[i]);
		if (mapsLeft > 0) {
			label = "\\r" + label + "	\\d(" + mapsLeft + ")\\y";
		} else {
			label = "\\w" + label;
		}
		
		g_menus[eidx].AddItem(label, any(maps[i]));
	}
	
	if (!(g_menus[eidx].IsRegistered()))
		g_menus[eidx].Register();
		
	g_menus[eidx].Open(0, 0, plr);
}

bool tryNominate(CBasePlayer@ plr, string mapname) {
	if (g_rtvVote.status != MVOTE_NOT_STARTED) {
		return false;
	}

	bool dontAutoNom = int(mapname.Find("*")) != -1; // player just wants to search for maps with this string
	mapname.Replace("*", "");
	bool fullNomMenu = mapname.Length() == 0;

	if (fullNomMenu || dontAutoNom || g_everyMap.find(mapname) < 0) {
		array<string> similarNames;
		
		if (fullNomMenu) {
			similarNames = g_everyMap;
		}
		else {
			for (uint i = 0; i < g_everyMap.size(); i++) {
				if (int(g_everyMap[i].Find(mapname)) != -1) {
					similarNames.insertLast(g_everyMap[i]);
				}
			}
		}
		
		if (similarNames.size() == 0) {
			g_PlayerFuncs.SayText(plr, "[RTV] No se encontró ningun mapa que contenga \"" + mapname + "\" en su nombre.\n");
		}
		else if (similarNames.size() > 1 || dontAutoNom) {
			openNomMenu(plr, mapname, similarNames);
		}
		else if (similarNames.size() == 1) {
			return tryNominate(plr, similarNames[0]);
		}
		
		return false;
	}
	
	if (mapname == g_Engine.mapname) {
		g_PlayerFuncs.SayText(plr, "[RTV] ¡No puedes nominar el mapa actual!\n");
		return false;
	}
	
	int mapExcludeTime = getMapExcludeTime(mapname);
	if (getMapExcludeTime(mapname, true, plr) > 0) {
		return false;
	}
	
	if (g_nomList.find(mapname) != -1) {
		g_PlayerFuncs.SayText(plr, "[RTV] \"" + mapname + "\" ya fue nominado.\n");
		return false;
	}
	
	if (int(g_nomList.size()) >= g_MaxMapsToVote.GetInt()) {
		g_PlayerFuncs.SayText(plr, "[RTV] ¡Se alcanzó el número máximo de nominaciones!\n");
		return false;
	}
	
	int eidx = plr.entindex();
	string oldNomMap = g_playerStates[eidx].nom;
	g_playerStates[eidx].nom = mapname;
	
	g_nomList.insertLast(mapname);
	
	if (oldNomMap.IsEmpty()) {
		g_PlayerFuncs.SayTextAll(plr, "[RTV] " + plr.pev.netname + " nominó \"" + mapname + "\".\n");
	} else {
		g_nomList.removeAt(g_nomList.find(oldNomMap));
		g_PlayerFuncs.SayTextAll(plr, "[RTV] " + plr.pev.netname + " cambió su nominación a \"" + mapname + "\".\n");
	}
	
	return true;
}




void sendMapList(CBasePlayer@ plr) {
	const float delayStep = 0.1f; // chunks might arrive out of order any faster than this
	const uint chunkSize = 12;
	float delay = 0;
	array<string> buffer;
	
	g_Scheduler.SetTimeout("delay_print", delay, EHandle(plr), "\n\n-- Lista de mapas ------------------------------\n\n");
	delay += delayStep;
	
	// send in chunks to prevent overflows
	for (uint i = 0; i < g_everyMap.length(); i += 4) {
		string msg = "";
		for (uint k = 0; k < 4 && i + k < g_everyMap.length(); k++) {
			msg += g_everyMap[i + k];
			int padding = (g_maxNomMapNameLength + 1) - g_everyMap[i + k].Length();
			for (int p = 0; p < padding; p++) {
				msg += " ";
			}
		}

		buffer.insertLast(msg + "\n");
		if (buffer.size() >= chunkSize) {
			g_Scheduler.SetTimeout("delay_print", delay, EHandle(plr), buffer);
			buffer = array<string>();
			delay += delayStep;
		}
	}
	
	if (buffer.size() > 0) {
		g_Scheduler.SetTimeout("delay_print", delay, EHandle(plr), buffer);
		buffer = array<string>();
		delay += delayStep;
	}
	
	delay += delayStep;
	g_Scheduler.SetTimeout("delay_print", delay, EHandle(plr), "\n----------------------------------------------- \n(" + g_everyMap.length() +" mapas en total)\n\n");

	g_PlayerFuncs.SayText(plr, "[RTV] Lista de mapas escrita en consola.");
}

void sendPastMapList(CBasePlayer@ plr) {
	int start = 0;
	if (int(g_previousMaps.length()) > g_ExcludePrevMapsNom.GetInt()) {
		start = g_previousMaps.length() - g_ExcludePrevMapsNom.GetInt();
	}
	
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "\n-- Mapas jugados previamente ------------------\n\n");
	for (uint i = start; i < g_previousMaps.length(); i++) {
		g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, " " + ((i-start) + 1) +	 ": "  + g_previousMaps[i] + "\n");
	}
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "-----------------------------------------------\n\n");
}

void sendPastMapList_full(CBasePlayer@ plr) {
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "\n-- Mapas jugados previamente ------------------\n\n");
	for (uint i = 0; i < g_previousMaps.length(); i++) {
		g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, " " + (i + 1) +	 ": "  + g_previousMaps[i] + "\n");
	}
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "-----------------------------------------------\n\n");
}

array<string> loadMapList(string path, bool ignoreDuplicates=false) {
	array<string> maplist;

	File@ file = g_FileSystem.OpenFile(path, OpenFile::READ);

	dictionary unique;

	if (file !is null && file.IsOpen()) {
		while (!file.EOFReached()) {
			string line;
			file.ReadLine(line);
			line.Trim();
			
			int commentIdx = line.Find("//");
			if (commentIdx != -1) {
				line = line.SubString(0, commentIdx);
				line.Trim();
			}

			if (line.IsEmpty())
				continue;

			array<string> parts = line.Split(" ");

			// allow either mapcycle or mapvote format
			string mapname;
			if (parts[0] == "addvotemap" && parts.size() > 1) {
				mapname = parts[1].ToLowercase();
			} else {
				mapname = parts[0].ToLowercase();
			}
			
			if (!ignoreDuplicates && unique.exists(mapname)) {
				g_Log.PrintF("[RTV] El mapa " + mapname + "está duplicado en lista: " + path + "\n");
				continue;
			}
			
			unique[mapname] = true;
			maplist.insertLast(mapname);
		}

		file.Close();
	} else {
		g_Log.PrintF("[RTV] No se encontró lista de mapas en: " + path + "\n");
	}
	
	return maplist;
}

void loadAllMapLists() {
	g_normalMaps = loadMapList(votelistFile);
	g_hiddenMaps = loadMapList(hiddenMapsFile);
	g_previousMaps = loadMapList(previousMapsFile, true);
	
	g_prevMapPosition.clear();
	g_memeMapsHashed.clear();
	
	// use a dictionary to check for maps to exclude faster
	for (uint i = 0; i < g_previousMaps.size(); i++) {
		g_prevMapPosition[g_previousMaps[i]] = i;
	}
	
	g_everyMap.resize(0);
	g_randomRtvChoices.resize(0);
	g_randomCycleMaps.resize(0);
	
	for (uint i = 0; i < g_hiddenMaps.size(); i++) {
		g_everyMap.insertLast(g_hiddenMaps[i]);
		g_memeMapsHashed[g_hiddenMaps[i]] = true;
		
		if (g_hiddenMaps[i].Length() > g_maxNomMapNameLength) {
			g_maxNomMapNameLength = g_hiddenMaps[i].Length();
		}
	}
	
	for (uint i = 0; i < g_normalMaps.size(); i++) {
		if (g_memeMapsHashed.exists(g_normalMaps[i])) {
			g_Log.PrintF("[RTV] El mapa \"" + g_normalMaps[i] + "\" debe estar en mapvote.cfg o hidden_nom_maps.txt, pero no en ambos.\n");
			continue;
		}
	
		g_everyMap.insertLast(g_normalMaps[i]);
		
		if (g_normalMaps[i].Length() > g_maxNomMapNameLength) {
			g_maxNomMapNameLength = g_normalMaps[i].Length();
		}
		if (!g_prevMapPosition.exists(g_normalMaps[i]) and g_normalMaps[i] != g_Engine.mapname) {
			g_randomRtvChoices.insertLast(g_normalMaps[i]);
		}
	}
	
	array<string> mapCycleMaps = g_MapCycle.GetMapCycle();
	for (uint i = 0; i < mapCycleMaps.size(); i++) {
		if (!g_prevMapPosition.exists(mapCycleMaps[i]) and mapCycleMaps[i] != g_Engine.mapname) {
			g_randomCycleMaps.insertLast(mapCycleMaps[i]);
		}
	}

	g_everyMap.sortAsc();
}

void writePreviousMapsList() {
	string mapname = string(g_Engine.mapname).ToLowercase();

	if (g_PlayerFuncs.GetNumPlayers() < 4) {
		g_Log.PrintF("[RTV] No se escribió el mapa anterior - menos de 4 jugadores.\n");
		return;
	}
	if (g_normalMaps.find(mapname) < 0 && g_hiddenMaps.find(mapname) < 0) {
		g_Log.PrintF("[RTV] No se escribió el mapa anterior - " + mapname + " no está en la lista de mapas.\n");
		return; // prevent maps in a series from being added to the list
	}

	if (g_previousMaps.size() > 0 and g_previousMaps[g_previousMaps.size()-1] == mapname) {
		g_Log.PrintF("[RTV] No se escribe el mapa anterior en previamente jugados, los reinicios no cuentan.\n");
		return; // don't count map restarts
	}

	g_previousMaps.insertLast(string(g_Engine.mapname).ToLowercase());
	while ((int(g_previousMaps.length()) > g_ExcludePrevMaps.GetInt())) {
		g_previousMaps.removeAt(0);
	}

	File@ f = g_FileSystem.OpenFile(previousMapsFile, OpenFile::WRITE);

	if (f.IsOpen()) {
		int numWritten = 0;
		for (uint i = 0; i < g_previousMaps.size(); i++) {
			string name = g_previousMaps[i];
			name.Trim();
			if (name.Length() == 0) {
				continue;
			}

			f.Write(name + "\n");
		}
		f.Close();
	}
	else
		g_Log.PrintF("No se pudo abrir el archivo de mapas previamente jugados: " + previousMapsFile + "\n");
}

bool rejectNonAdmin(CBasePlayer@ plr) {
	bool isAdmin = g_PlayerFuncs.AdminLevel(plr) >= ADMIN_YES;
	
	if (!isAdmin) {
		g_PlayerFuncs.SayText(plr, "[RTV] Solo admins >:|\n");
		return true;
	}
	
	return false;
}


// return 0 = chat not handled, 1 = handled and show chat, 2 = handled and hide chat
int doCommand(CBasePlayer@ plr, const CCommand@ args, bool inConsole) {
	bool isAdmin = g_PlayerFuncs.AdminLevel(plr) >= ADMIN_YES;
	
	if (args.ArgC() >= 1)
	{
		if (args.Arg(0).ToLowercase() == "rtv" and args.ArgC() == 1) {
			return tryRtv(plr);
		}
		else if (args.Arg(0).ToLowercase() == "nom" || args.Arg(0).ToLowercase() == ".nom" || args.Arg(0).ToLowercase() == "!nom" || args.Arg(0).ToLowercase() == "/nom" || args.Arg(0).ToLowercase() == "nominate" || args.Arg(0).ToLowercase() == ".nominate" || args.Arg(0).ToLowercase() == "!nominate" || args.Arg(0).ToLowercase() == "/nominate") {
			string mapname = args.ArgC() >= 2 ? args[1].ToLowercase() : "";
			tryNominate(plr, mapname);
			return 2;
		}
		else if (args.Arg(0).ToLowercase() == "unnom" || args.Arg(0).ToLowercase() == ".unnom" || args.Arg(0).ToLowercase() == "!unnom" || args.Arg(0).ToLowercase() == "/unnom" || args.Arg(0).ToLowercase() == "unom" || args.Arg(0).ToLowercase() == ".unom" || args.Arg(0).ToLowercase() == "!unom" || args.Arg(0).ToLowercase() == "/unom" || args.Arg(0).ToLowercase() == "denom" || args.Arg(0).ToLowercase() == ".denom" || args.Arg(0).ToLowercase() == "!denom" || args.Arg(0).ToLowercase() == "/denom") {
			RtvState@ state = g_playerStates[plr.entindex()];
			if (g_rtvVote.status != MVOTE_NOT_STARTED) {
				g_PlayerFuncs.SayText(plr, "[RTV] ¡Muy tarde para hacer eso ahora!\n");
			}
			else if (state.nom.Length() > 0) {
				g_nomList.removeAt(g_nomList.find(state.nom));
				g_PlayerFuncs.SayTextAll(plr, "[RTV] " + plr.pev.netname + " eliminó \"" + state.nom + "\" de su nominación.\n");
				state.nom = "";
			} else {
				g_PlayerFuncs.SayText(plr, "[RTV] ¡Aún no has nominado nada!\n");
			}
			return 2;
		}
		else if (args.Arg(0).ToLowercase() == "listnom" || args.Arg(0).ToLowercase() == ".listnom" || args.Arg(0).ToLowercase() == "!listnom" || args.Arg(0).ToLowercase() == "/listnom" || args.Arg(0).ToLowercase() == "nomlist" || args.Arg(0).ToLowercase() == ".nomlist" || args.Arg(0).ToLowercase() == "!nomlist" || args.Arg(0).ToLowercase() == "/nomlist" || args.Arg(0).ToLowercase() == "noms" || args.Arg(0).ToLowercase() == ".noms" || args.Arg(0).ToLowercase() == "!noms" || args.Arg(0).ToLowercase() == "/noms") {
			if (g_nomList.size() > 0) {
				string msg = "[RTV] Nominaciones actuales: ";
				
				for (uint i = 0; i < g_nomList.size(); i++) {
					msg += (i != 0 ? ", " : "") + g_nomList[i];
				}
				
				g_PlayerFuncs.SayText(plr, msg + "\n");
			} else {
				g_PlayerFuncs.SayText(plr, "[RTV] Aún no se ha nominado nada.\n");
			}
			
			return 2;
		}
		else if (args.Arg(0).ToLowercase() == "maplist" || args.Arg(0).ToLowercase() == "listmaps") {
			sendMapList(plr);
			return 2;
		}
		else if (args.Arg(0).ToLowercase() == ".pastmaplist") {
			sendPastMapList(plr);
			return 2;
		}
		else if (args.Arg(0).ToLowercase() == ".pastmaplistfull") {
			sendPastMapList_full(plr);
			return 2;
		}
		else if (args.Arg(0).ToLowercase() == ".forcertv") {
			if (rejectNonAdmin(plr)) {
				return 2;
			}
			
			if (g_rtvVote.status != MVOTE_NOT_STARTED) {
				g_PlayerFuncs.SayText(plr, "[RTV] ¡Actualmente hay una votación!\n");
			} else {
				startVote("[RTV] " + plr.pev.netname + " a forzado un RTV.");
			}
			return 2;
		}
		else if (args.Arg(0).ToLowercase() == ".cancelrtv") {
			if (rejectNonAdmin(plr)) {
				return 2;
			}
			
			cancelRtv(plr);
			return 2;
		}
		else if (args.Arg(0).ToLowercase() == ".map") {
			if (rejectNonAdmin(plr)) {
				return 2;
			}
			
			if (args.ArgC() < 2) {
				g_PlayerFuncs.SayText(plr, "Modo de uso: .map <mapname>\n");
				return 2;
			}
			
			string nextmap = args[1].ToLowercase();
			if (!g_EngineFuncs.IsMapValid(nextmap)) {
				g_PlayerFuncs.SayText(plr, "¡El mapa \"" + nextmap + "\" no existe!\n");
				return 2;
			}
			
			NetworkMessage message(MSG_ALL, NetworkMessages::SVC_INTERMISSION, null);
			message.End();
			
			@g_timer = g_Scheduler.SetTimeout("change_map", levelChangeDelay, nextmap);
			
			g_PlayerFuncs.SayTextAll(plr, "" + plr.pev.netname + " cambió de mapa a: " + nextmap + "\n");
		}
		else if (args.Arg(0).ToLowercase() == ".set_nextmap") {
			if (rejectNonAdmin(plr)) {
				return 2;
			}
			
			if (args.ArgC() < 2) {
				g_PlayerFuncs.SayText(plr, "Modo de uso: .set_nextmap <mapname>\n");
				return 2;
			}
			
			string nextmap = args[1].ToLowercase();
			if (!g_EngineFuncs.IsMapValid(nextmap)) {
				g_PlayerFuncs.SayText(plr, "¡El mapa \"" + nextmap + "\" no existe!\n");
				return 2;
			}
			
			string old = g_MapCycle.GetNextMap();
			if (old == nextmap) {
				g_PlayerFuncs.SayText(plr, old + " ¡Ya está configurado como el siguiente mapa!\n");
			} else {
				g_EngineFuncs.ServerCommand("mp_nextmap_cycle " + nextmap + "\n");
				g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, "" + plr.pev.netname + " cambió el siguiente mapa de " + old + " al " + nextmap + "\n");
			}
			
			return 2;
		}
	}
	
	return doGameVote(plr, args, inConsole);
}

HookReturnCode ClientSay( SayParameters@ pParams ) {
	CBasePlayer@ plr = pParams.GetPlayer();
	const CCommand@ args = pParams.GetArguments();
	
	int chatHandled = doCommand(plr, args, false);
	
	if (chatHandled == 2) {
		pParams.ShouldHide = true;
	}
	return HOOK_CONTINUE;
}

HookReturnCode ClientLeave(CBasePlayer@ plr) {
	RtvState@ state = g_playerStates[plr.entindex()];
	state.didRtv = false;
	state.afkTime = 0;
	
	if (state.nom.Length() > 0) {
		g_nomList.removeAt(g_nomList.find(state.nom));
		g_PlayerFuncs.SayTextAll(plr, "[RTV] \"" + state.nom + "\" Ya no está nominado.\n");
		state.nom = "";
	}
	
	return HOOK_CONTINUE;
}

void consoleCmd( const CCommand@ args ) {
	CBasePlayer@ plr = g_ConCommandSystem.GetCurrentPlayer();
	doCommand(plr, args, true);
}
