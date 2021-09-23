MenuVote::MenuVote g_gameVote;
float g_lastGameVote = 0;
string g_lastVoteStarter; // used to prevent a single player from spamming votes by doubling their cooldown

const int VOTE_FAILS_UNTIL_BAN = 2; // if a player keeps starting votes that fail, they're banned from starting more votes
const int VOTE_FAIL_IGNORE_TIME = 60; // number of minutes to remember failed votes
const int VOTING_BAN_DURATION = 24*60; // number of minutes a ban lasts (banned from starting votes, not from the server)
const int GLOBAL_VOTE_COOLDOWN = 5; // just enough time to read results of the previous vote.
const int RESTART_MAP_PERCENT_REQ = 75;
const int SEMI_SURVIVAL_PERCENT_REQ = 67;

class PlayerVoteState
{
	array<DateTime> failedVoteTimes; // times that this player started a vote which failed
	DateTime voteBanExpireTime;
	bool isBanned = false;
	int killedCount = 0; // kill for longer duration if keep getting votekilled
	DateTime nextVoteAllow = DateTime(); // next time this player can start a vote
	
	PlayerVoteState() {}
	
	void handleVoteFail() {		
		// clear failed votes from long ago
		for (int i = int(failedVoteTimes.size())-1; i >= 0; i--) {
			int diff = int(TimeDifference(DateTime(), failedVoteTimes[i]).GetTimeDifference());
			
			if (diff > VOTE_FAIL_IGNORE_TIME*60) {
				failedVoteTimes.removeAt(i);
			}
		}
		
		failedVoteTimes.insertLast(DateTime());
		
		// this player wasted other's time. Punish.
		nextVoteAllow = DateTime() + TimeDifference(g_EngineFuncs.CVarGetFloat("mp_playervotedelay"));
		
		if (failedVoteTimes.size() >= VOTE_FAILS_UNTIL_BAN) {
			// player continues to start votes that fail. REALLY PUNISH.
			isBanned = true;
			failedVoteTimes.resize(0);
			voteBanExpireTime = DateTime() + TimeDifference(VOTING_BAN_DURATION*60);
		}
	}
	
	void handleVoteSuccess() {
		// player knows what the people want. Keep it up! But give someone else a chance to start a vote
		nextVoteAllow = DateTime() + TimeDifference(GLOBAL_VOTE_COOLDOWN*2);
		failedVoteTimes.resize(0);
	}
}

void reduceKillPenalties() {
	array<string>@ state_keys = g_voting_ban_states.getKeys();
	
	for (uint i = 0; i < state_keys.length(); i++)
	{
		PlayerVoteState@ state = cast<PlayerVoteState@>(g_voting_ban_states[state_keys[i]]);
		if (state.killedCount > 0) {
			state.killedCount -= 1;
		}
	}
}

dictionary g_voting_ban_states;

PlayerVoteState getPlayerVoteState(string steamId) {	
	if ( !g_voting_ban_states.exists(steamId) )
	{
		PlayerVoteState state;
		g_voting_ban_states[steamId] = state;
	}
	
	return cast<PlayerVoteState@>( g_voting_ban_states[steamId] );
}

string getPlayerUniqueId(CBasePlayer@ plr) {	
	string steamId = g_EngineFuncs.GetPlayerAuthId( plr.edict() );
	
	if (steamId == 'STEAM_ID_LAN') {
		steamId = plr.pev.netname;
	}
	
	return steamId;
}

CBasePlayer@ findPlayer(string uniqueId) {
	CBasePlayer@ target = null;
	
	for ( int i = 1; i <= g_Engine.maxClients; i++ )
	{
		CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(i);
		
		if (plr is null or !plr.IsConnected()) {
			continue;
		}
		
		if (getPlayerUniqueId(plr) == uniqueId) {
			@target = @plr;
			break;
		}
	}
	
	return target;
}

void optionChosenCallback(MenuVote::MenuVote@ voteMenu, MenuOption@ chosenOption, CBasePlayer@ plr) {
	if (chosenOption !is null) {
		if (chosenOption.label == "\\d(Cerrar menu)") {
			g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCENTER, "Escribe \".vote\" para re-abrir el menu.\n");
			voteMenu.closeMenu(plr);
		}
	}
}

string yesVoteFailStr(int got, int req) {
	if (got > 0) {
		return "(" + got + "%% votó que sí pero " + req + "%% es necesario)";
	}
	
	return "(Nadie votó que si)";
}

void voteKillFinishCallback(MenuVote::MenuVote@ voteMenu, MenuOption@ chosenOption, int resultReason) {
	array<string> parts = chosenOption.value.Split("\\");
	string name = parts[1];
	
	g_lastGameVote = g_Engine.time;
	
	PlayerVoteState@ voterState = getPlayerVoteState(voteMenu.voteStarterId);
	
	if (chosenOption.label == "No") {
		int required = int(g_EngineFuncs.CVarGetFloat("mp_votekillrequired"));
		int got = voteMenu.getOptionVotePercent("Si");
		g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, "Votación para MATAR a \"" + name + "\" falló " + yesVoteFailStr(got, required) + ".\n");
		voterState.handleVoteFail();
	} else {
		string steamId = parts[0];
		CBasePlayer@ target = findPlayer(steamId);
		PlayerVoteState@ victimState = getPlayerVoteState(steamId);
		
		int killTime = 30;
		string timeStr = "30 segundos";
		
		if (victimState.killedCount >= 2) {
			killTime = 60*2;
			timeStr = "2 minutos";
		} else if (victimState.killedCount >= 1) {
			killTime = 60;
			timeStr = "1 minuto";
		}
		
		if (target !is null) {
			if (target.IsAlive()) {
				g_EntityFuncs.Remove(target);
			}
			target.m_flRespawnDelayTime = killTime;
		}
		
		voterState.handleVoteSuccess();
		g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, "Vote killing \"" + name + "\" por " + timeStr + ".\n");
		keep_votekilled_player_dead(steamId, name, DateTime(), killTime);
		victimState.killedCount += 1;
	}
}

void keep_votekilled_player_dead(string targetId, string targetName, DateTime killTime, int killDuration) {
	int diff = int(TimeDifference(DateTime(), killTime).GetTimeDifference());
	
	if (diff > killDuration) {
		g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, "La votación para matar a \"" + targetName + " expiró\".\n");
		return;
	}
	
	for ( int i = 1; i <= g_Engine.maxClients; i++ )
	{
		CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(i);
		
		if (plr is null or !plr.IsConnected()) {
			continue;
		}

		string steamId = getPlayerUniqueId( plr );
		
		if (steamId == targetId) {
			if (plr.IsAlive()) {
				g_EntityFuncs.Remove(plr);
				plr.m_flRespawnDelayTime = killDuration - diff;
				g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, "Matando a \"" + plr.pev.netname + "\" nuevamente. " + int(plr.m_flRespawnDelayTime) + " segundos restantes en la pena de muerte por voto.\n");
			}
			
		}
	}
	
	g_Scheduler.SetTimeout("keep_votekilled_player_dead", 1, targetId, targetName, killTime, killDuration);
}

void survivalVoteFinishCallback(MenuVote::MenuVote@ voteMenu, MenuOption@ chosenOption, int resultReason) {	
	PlayerVoteState@ voterState = getPlayerVoteState(voteMenu.voteStarterId);

	g_lastGameVote = g_Engine.time;

	if (chosenOption.value == "enable" || chosenOption.value == "disable") {
		voterState.handleVoteSuccess();
		
		if (chosenOption.value == "enable") {
			g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, "Votación para activar el modo supervivencia aprobado.\n");
			g_SurvivalMode.VoteToggle();
		} else if (chosenOption.value == "disable") {
			g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, "Votación para desactivar el modo supervivencia aprobado.\n");
			g_SurvivalMode.VoteToggle();
		}
	}
	else {
		int required = int(g_EngineFuncs.CVarGetFloat("mp_votesurvivalmoderequired"));
		int got = voteMenu.getOptionVotePercent("Si");
		g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, "Votación para activar/desactivar el modo supervivencia falló " + yesVoteFailStr(got, required) + ".\n");
		voterState.handleVoteFail();
	}
}

void semiSurvivalVoteFinishCallback(MenuVote::MenuVote@ voteMenu, MenuOption@ chosenOption, int resultReason) {	
	PlayerVoteState@ voterState = getPlayerVoteState(voteMenu.voteStarterId);

	g_lastGameVote = g_Engine.time;

	if (chosenOption.value == "enable" || chosenOption.value == "disable") {
		voterState.handleVoteSuccess();
		
		if (chosenOption.value == "enable") {
			g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, "Votación para activar el modo semi-supervivencia aprobado.\n");
			g_EngineFuncs.ServerCommand("as_command fsurvival.mode 2\n");
		} else if (chosenOption.value == "disable") {
			g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, "Votación para desactivar el modo semi-supervivencia aprobado.\n");
			g_EngineFuncs.ServerCommand("as_command fsurvival.mode 0\n");
		}
	}
	else {
		int required = int(g_EngineFuncs.CVarGetFloat("mp_votesurvivalmoderequired"));
		int got = voteMenu.getOptionVotePercent("Si");
		g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, "Votación para activar/desactivar el modo semi-supervivencia falló " + yesVoteFailStr(got, required) + ".\n");
		voterState.handleVoteFail();
	}
}

void restartVoteFinishCallback(MenuVote::MenuVote@ voteMenu, MenuOption@ chosenOption, int resultReason) {	
	PlayerVoteState@ voterState = getPlayerVoteState(voteMenu.voteStarterId);

	g_lastGameVote = g_Engine.time;

	if (chosenOption.label == "Si") {
		voterState.handleVoteSuccess();
		g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, "Votación para reiniciar el mapa aprobado. Reiniciando el mapa en 5 segundos.\n");
		@g_timer = g_Scheduler.SetTimeout("change_map", MenuVote::g_resultTime + (5-MenuVote::g_resultTime), "" + g_Engine.mapname);
	}
	else {
		int required = RESTART_MAP_PERCENT_REQ;
		int got = voteMenu.getOptionVotePercent("Si");
		g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, "Votación para reiniciar el mapa falló " + yesVoteFailStr(got, required) + ".\n");
		voterState.handleVoteFail();
	}
}

void customPollFinishCallback(MenuVote::MenuVote@ voteMenu, MenuOption@ chosenOption, int resultReason) {	
	PlayerVoteState@ voterState = getPlayerVoteState(voteMenu.voteStarterId);
	voterState.handleVoteSuccess();
	g_lastGameVote = g_Engine.time;
	
	int percent = voteMenu.getOptionVotePercentByValue(chosenOption.value);
	string relayResult = voteMenu.getResultString();	
	string chatResult = "[Encuesta] " + voteMenu.getTitle() + " " + chosenOption.label + " (" + percent + "%)\n";
	g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, chatResult.Replace("%", "%%") + "\n");
}

void gameVoteMenuCallback(CTextMenu@ menu, CBasePlayer@ plr, int page, const CTextMenuItem@ item) {
	if (item is null or plr is null or !plr.IsConnected()) {
		return;
	}

	string option;
	item.m_pUserData.retrieve(option);
	
	if (!tryStartGameVote(plr)) {
		return;
	}
	
	if (option == "kill") {
		g_Scheduler.SetTimeout("openVoteKillMenu", 0.0f, EHandle(plr));
	} else if (option == "survival") {
		g_Scheduler.SetTimeout("tryStartSurvivalVote", 0.0f, EHandle(plr));
	} else if (option == "semi-survival") {
		g_Scheduler.SetTimeout("tryStartSemiSurvivalVote", 0.0f, EHandle(plr));
	} else if (option == "restartmap") {
		g_Scheduler.SetTimeout("tryStartRestartVote", 0.0f, EHandle(plr));
	}
}

void voteKillMenuCallback(CTextMenu@ menu, CBasePlayer@ plr, int page, const CTextMenuItem@ item) {
	if (item is null or plr is null or !plr.IsConnected()) {
		return;
	}

	string option;
	item.m_pUserData.retrieve(option);
	
	g_Scheduler.SetTimeout("tryStartVotekill", 0.0f, EHandle(plr), option);
}

void openGameVoteMenu(CBasePlayer@ plr) {
	int eidx = plr.entindex();
	
	@g_menus[eidx] = CTextMenu(@gameVoteMenuCallback);
	g_menus[eidx].SetTitle("\\yVote Menu");
	
	string killReq = "\\d(" + int(g_EngineFuncs.CVarGetFloat("mp_votekillrequired")) + "% necesario)";
	string survReq = "\\d(" + int(g_EngineFuncs.CVarGetFloat("mp_votesurvivalmoderequired")) + "% necesario)";
	string semiSurvReq = "\\d(" + SEMI_SURVIVAL_PERCENT_REQ + "% necesario)";
	string restartReq = "\\d(" + RESTART_MAP_PERCENT_REQ + "% necesario)";
	
	g_menus[eidx].AddItem("\\wMatar jugador " + killReq + "\\y", any("kill"));
	
	bool canVoteSurvival = g_EngineFuncs.CVarGetFloat("mp_survival_voteallow") != 0	&&
						   g_EngineFuncs.CVarGetFloat("mp_survival_supported") != 0;
	bool canVoteSemiSurvival = g_EngineFuncs.CVarGetFloat("mp_survival_voteallow") != 0;
	
	if (!g_SurvivalMode.IsEnabled()) {
		g_menus[eidx].AddItem((canVoteSurvival ? "\\w" : "\\r") + "Activar supervivencia " + survReq + "\\y", any("survival"));
		if (g_EnableForceSurvivalVotes.GetInt() != 0)
			g_menus[eidx].AddItem((canVoteSemiSurvival ? "\\w" : "\\r") + "Activar modo semi-supervivencia " + semiSurvReq + "\\y", any("semi-survival"));
	} else {
		g_menus[eidx].AddItem((canVoteSurvival ? "\\w" : "\\r") + "Desactivar modo supervivencia " + survReq + "\\y", any("survival"));
	}
	
	g_menus[eidx].AddItem((g_SurvivalMode.IsActive() ? "\\w" : "\\r") + "Reiniciar mapa " + restartReq + "\\y", any("restartmap"));
	
	if (!(g_menus[eidx].IsRegistered()))
		g_menus[eidx].Register();
		
	g_menus[eidx].Open(0, 0, plr);
}

void openVoteKillMenu(EHandle h_plr) {
	CBasePlayer@ user = cast<CBasePlayer@>(h_plr.GetEntity());
	
	if (user is null) {
		return;
	}
	
	int eidx = user.entindex();
	
	array<MenuOption> targets;
	for ( int i = 1; i <= g_Engine.maxClients; i++ )
	{
		CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(i);
		
		if (plr is null or !plr.IsConnected()) {
			continue;
		}
		
		if (!plr.IsAlive()) {
			continue;
		}
		
		MenuOption option;
		option.label = "\\w" + plr.pev.netname;
		option.value = getPlayerUniqueId(plr);
		targets.insertLast(option);
	}
	
	if (targets.size() == 0) {
		g_PlayerFuncs.ClientPrintAll(HUD_PRINTTALK, "[Vote] No se puede votar para matar. Nadie esta vivo.\n");
	}
	
	targets.sort(function(a,b) { return a.label > b.label; });
	
	@g_menus[eidx] = CTextMenu(@voteKillMenuCallback);
	g_menus[eidx].SetTitle("\\yMatar a quien?\n");
	
	for (uint i = 0; i < targets.size(); i++) {
		g_menus[eidx].AddItem(targets[i].label + "\\y", any(targets[i].value));
	}
	
	if (!(g_menus[eidx].IsRegistered()))
		g_menus[eidx].Register();
		
	g_menus[eidx].Open(0, 0, user);
}

bool tryStartGameVote(CBasePlayer@ plr) {
	if (g_rtvVote.status != MVOTE_NOT_STARTED or g_gameVote.status == MVOTE_IN_PROGRESS) {
		g_PlayerFuncs.SayText(plr, "[Vote] Ya está en curso otra votación.\n");
		return false;
	}
	
	if (g_Engine.time < g_SecondsUntilVote.GetInt()) {
		int timeLeft = int(Math.Ceil(float(g_SecondsUntilVote.GetInt()) - g_Engine.time));
		g_PlayerFuncs.SayText(plr, "[Vote] La votación se iniciará en " + timeLeft + " segundos.\n");
		return false;
	}
	
	// global cooldown
	float voteDelta = g_Engine.time - g_lastGameVote;
	float cooldown = GLOBAL_VOTE_COOLDOWN;
	if (g_lastGameVote > 0 and voteDelta < cooldown) {
		g_PlayerFuncs.SayText(plr, "[Vote] Espera " + int((cooldown - voteDelta) + 0.99f) + " segundos antes de comenzar otra votación.\n");
		return false;
	}
	
	// player-specific cooldown
	PlayerVoteState@ voterState = getPlayerVoteState(getPlayerUniqueId(plr));
	int nextVoteDelta = int(TimeDifference(voterState.nextVoteAllow, DateTime()).GetTimeDifference());
	if (nextVoteDelta > 0) {
		g_PlayerFuncs.SayText(plr, "[Vote] Espera " + int(nextVoteDelta + 0.99f) + " segundos antes de comenzar otra votación.\n");
		return false;
	}
	
	if (voterState.isBanned) {
		int diff = int(TimeDifference(voterState.voteBanExpireTime, DateTime()).GetTimeDifference());
		if (diff > 0) {
			string timeleft = "" + ((diff + 59) / 60) + " minutos";
			if (diff > 60) {
				timeleft = "" + ((diff + 3599) / (60*60)) + " horas";
			}
			g_PlayerFuncs.SayText(plr, "[Vote] Ha iniciado demasiadas votaciones que fallaron. Espera " + timeleft + " segundos antes de comenzar otra votación.\n");
			return false;
		} else {
			voterState.isBanned = false;
		}
	}
	
	
	return true;
}

void tryStartVotekill(EHandle h_plr, string uniqueId) {
	CBasePlayer@ plr = cast<CBasePlayer@>(h_plr.GetEntity());
	if (plr is null) {
		return;
	}
	
	if (!tryStartGameVote(plr)) {
		return;
	}
	
	CBasePlayer@ target = findPlayer(uniqueId);
	
	if (target is null) {
		g_PlayerFuncs.SayTextAll(plr, "[Vote] Jugador no encontrado.\n");
		return;
	}	
	
	array<MenuOption> options = {
		MenuOption("Si", uniqueId + "\\" + target.pev.netname),
		MenuOption("No", uniqueId + "\\" + target.pev.netname),
		MenuOption("\\d(Cerrar menu)")
	};
	options[2].isVotable = false;
	
	MenuVoteParams voteParams;
	voteParams.title = "Matar a \"" + target.pev.netname + "\"?";
	voteParams.options = options;
	voteParams.percentFailOption = options[1];
	voteParams.voteTime = int(g_EngineFuncs.CVarGetFloat("mp_votetimecheck"));
	voteParams.percentNeeded = int(g_EngineFuncs.CVarGetFloat("mp_votekillrequired"));
	@voteParams.finishCallback = @voteKillFinishCallback;
	@voteParams.optionCallback = @optionChosenCallback;
	g_gameVote.start(voteParams, plr);
	
	g_lastVoteStarter = getPlayerUniqueId(plr);
	
	g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, "Votación para MATAR a \"" + target.pev.netname + "\" iniciada por \"" + plr.pev.netname + "\".\n");
	
	return;
}

void tryStartSurvivalVote(EHandle h_plr) {
	CBasePlayer@ plr = cast<CBasePlayer@>(h_plr.GetEntity());
	if (plr is null or !tryStartGameVote(plr)) {
		return;
	}
	
	if (g_EngineFuncs.CVarGetFloat("mp_survival_supported") == 0) {
		g_PlayerFuncs.SayText(plr, "[Vote] El modo de supervivencia no es compatible con este mapa.\n");
		return;
	}
	
	if (g_EngineFuncs.CVarGetFloat("mp_survival_voteallow") == 0) {
		g_PlayerFuncs.SayText(plr, "[Vote] Los votos del modo supervivencia están deshabilitados.");
		return;
	}
	
	bool survivalEnabled = g_SurvivalMode.IsEnabled();
	string title = (survivalEnabled ? "Desactivar" : "Activar") + " modo supervivencia?";
	
	array<MenuOption> options = {
		MenuOption("Si", survivalEnabled ? "Desactivar" : "Activar"),
		MenuOption("No", "no"),
		MenuOption("\\d(Cerrar menu)")
	};
	options[2].isVotable = false;
	
	MenuVoteParams voteParams;
	voteParams.title = title;
	voteParams.options = options;
	voteParams.percentFailOption = options[1];
	voteParams.voteTime = int(g_EngineFuncs.CVarGetFloat("mp_votetimecheck"));
	voteParams.percentNeeded = int(g_EngineFuncs.CVarGetFloat("mp_votesurvivalmoderequired"));
	@voteParams.finishCallback = @survivalVoteFinishCallback;
	@voteParams.optionCallback = @optionChosenCallback;
	g_gameVote.start(voteParams, plr);
	
	g_lastVoteStarter = getPlayerUniqueId(plr);
	
	string enableDisable = survivalEnabled ? "Desactivar" : "Activar";
	g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, "Votación para " + enableDisable + " modo supervivencia iniciado por \"" + plr.pev.netname + "\".\n");
	
	return;
}

void tryStartSemiSurvivalVote(EHandle h_plr) {
	CBasePlayer@ plr = cast<CBasePlayer@>(h_plr.GetEntity());
	if (plr is null or !tryStartGameVote(plr)) {
		return;
	}
	
	if (g_EngineFuncs.CVarGetFloat("mp_survival_voteallow") == 0) {
		g_PlayerFuncs.SayText(plr, "[Vote] Los votos del modo supervivencia están deshabilitados.");
		return;
	}
	
	bool survivalEnabled = g_SurvivalMode.IsEnabled();
	string title = (survivalEnabled ? "Desactivar" : "Activar") + " modo semi-supervivencia?";
	if (!survivalEnabled) {
		title += "\n(Reaparecer en oleadas)";
	}
	
	array<MenuOption> options = {
		MenuOption("Si", survivalEnabled ? "Desactivar" : "Activar"),
		MenuOption("No", "no"),
		MenuOption("\\d(Cerrar menu)")
	};
	options[2].isVotable = false;
	
	MenuVoteParams voteParams;
	voteParams.title = title;
	voteParams.options = options;
	voteParams.percentFailOption = options[1];
	voteParams.voteTime = int(g_EngineFuncs.CVarGetFloat("mp_votetimecheck"));
	voteParams.percentNeeded = SEMI_SURVIVAL_PERCENT_REQ;
	@voteParams.finishCallback = @semiSurvivalVoteFinishCallback;
	@voteParams.optionCallback = @optionChosenCallback;
	g_gameVote.start(voteParams, plr);
	
	g_lastVoteStarter = getPlayerUniqueId(plr);
	
	string enableDisable = survivalEnabled ? "Desactivar" : "Activar";
	g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, "Votación para " + enableDisable + " modo semi-supervivencia iniciado por \"" + plr.pev.netname + "\".\n");
	
	return;
}

void tryStartRestartVote(EHandle h_plr) {
	CBasePlayer@ plr = cast<CBasePlayer@>(h_plr.GetEntity());
	if (plr is null or !tryStartGameVote(plr)) {
		return;
	}
	
	if (!g_SurvivalMode.IsActive()) {
		g_PlayerFuncs.SayText(plr, "[Vote] Los reinicios solo se permiten durante el modo supervivencia.\n");
		return;
	}
	
	array<MenuOption> options = {
		MenuOption("Si", "Si"),
		MenuOption("No", "no"),
		MenuOption("\\d(Cerrar menu)")
	};
	options[2].isVotable = false;
	
	MenuVoteParams voteParams;
	voteParams.title = "Reiniciar mapa?";
	voteParams.options = options;
	voteParams.percentFailOption = options[1];
	voteParams.voteTime = int(g_EngineFuncs.CVarGetFloat("mp_votetimecheck"));
	voteParams.percentNeeded = RESTART_MAP_PERCENT_REQ;
	@voteParams.finishCallback = @restartVoteFinishCallback;
	@voteParams.optionCallback = @optionChosenCallback;
	g_gameVote.start(voteParams, plr);
	
	g_lastVoteStarter = getPlayerUniqueId(plr);
	
	g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, "Votación para reiniciar el mapa iniciada por \"" + plr.pev.netname + "\".\n");
	
	return;
}

int doGameVote(CBasePlayer@ plr, const CCommand@ args, bool inConsole) {
	bool isAdmin = g_PlayerFuncs.AdminLevel(plr) >= ADMIN_YES;
	
	if (args.ArgC() >= 1)
	{
		if (args[0] == ".vote") {
			if (g_EnableGameVotes.GetInt() == 0) {
				g_PlayerFuncs.SayText(plr, "[Vote] Comando deshabilitado.\n");
				return 2;
			}
			
			if (g_gameVote.status == MVOTE_IN_PROGRESS) {
				g_gameVote.reopen(plr);
				return 2;
			}
			
			if (tryStartGameVote(plr)) {
				openGameVoteMenu(plr);
			}
			
			return 2;
		}
		if (args[0] == ".poll") {
			if (rejectNonAdmin(plr)) {
				return 2;
			}
			
			if (args.ArgC() <= 1) {
				g_PlayerFuncs.SayText(plr, 'Uso para encuesta de Sí/No:    .poll "Titulo"\n');
				g_PlayerFuncs.SayText(plr, 'Uso para encuesta con respuestas personalizadas:    .poll "Titulo" "Opción 1" "Opción 2" ...\n');
				return 2;
			}
			
			if (args.ArgC() > 10) {
				g_PlayerFuncs.SayText(plr, 'Las encuestas no pueden tener más de 8 opciones.\n');
				return 2;
			}
			
			if (g_gameVote.status == MVOTE_IN_PROGRESS) {
				g_PlayerFuncs.SayText(plr, "[Vote] Espera a que la votación actual termine.\n");
				return 2;
			}
			
			array<MenuOption> options = {
				MenuOption("\\d(Cerrar menu)")
			};
			options[0].isVotable = false;

			
			for (int i = 2; i < args.ArgC(); i++) {
				options.insertLast(MenuOption(args[i], i));
			}
			
			MenuVoteParams voteParams;
			
			if (args.ArgC() <= 2) {
				options = {
					MenuOption("Si"),
					MenuOption("No"),
					MenuOption("\\d(Cerrar menu)")
				};
				options[2].isVotable = false;
				voteParams.percentNeeded = 51;
			}
			
			voteParams.title = args[1];
			voteParams.options = options;
			voteParams.voteTime = int(g_EngineFuncs.CVarGetFloat("mp_votetimecheck"));
			voteParams.forceOpen = false;
			@voteParams.finishCallback = @customPollFinishCallback;
			@voteParams.optionCallback = @optionChosenCallback;
			g_gameVote.start(voteParams, plr);
			
			g_PlayerFuncs.ClientPrintAll(HUD_PRINTNOTIFY, "Encuesta iniciada por \"" + plr.pev.netname + "\".\n");
			
			return 2;
		}
	}
	
	return 0;
}
