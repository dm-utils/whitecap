class_name Match
extends RefCounted
## One match = MatchSim + bots + presentation data (names). The view and the tests drive it the same way:
## step(human_command) once per tick. With human_animal "" every entrant is a bot (tests, balance runs).

const SLICE_ANIMALS := ["crab", "octopus", "gull"]

var sim: MatchSim
var human := -1
var bot_level := "easy"
var names: Array = []
var replay: Array = [] # human commands per tick (compact), for replays and server checks later

var _bot_cfg: Dictionary


static func create(seed_value: int, human_animal: String, players := 6, level := "easy") -> Match:
	var m := Match.new()
	m.bot_level = level
	m._bot_cfg = BotBrain.level_config(level)
	# bots' animals and names come from their own stream, so they never shift the sim's RNG
	var pick := SimRng.new(seed_value ^ 0x5BD1E995)
	var entrants: Array = []
	if human_animal != "":
		entrants.append(human_animal)
		m.human = 0
	while entrants.size() < players:
		entrants.append(SLICE_ANIMALS[pick.range_i(SLICE_ANIMALS.size())])
	m.sim = MatchSim.new(seed_value, entrants)
	var bots: Dictionary = Content.load_json("res://data/bots.json")
	for e in m.sim.ents:
		if e.id == m.human:
			m.names.append("")
			continue
		e.is_bot = 1
		e.damage_pct = int(m._bot_cfg.damage_pct)
		var adj: Array = bots.names.adjectives
		var noun: Array = bots.names.nouns
		m.names.append("%s %s %d" % [adj[pick.range_i(adj.size())], noun[pick.range_i(noun.size())], 1 + pick.range_i(98)])
	return m


func step(human_cmd: Dictionary = {}) -> void:
	var cmds: Array = []
	for e in sim.ents:
		if not e.alive:
			cmds.append({})
		elif e.id == human:
			cmds.append(human_cmd)
		else:
			cmds.append(BotBrain.think(sim, e, _bot_cfg))
	if human >= 0:
		replay.append([int(human_cmd.get("m", -1)), int(human_cmd.get("a", -1)), int(human_cmd.get("s", -1)), int(human_cmd.get("sd", -1))])
	sim.step(cmds)


func finished() -> bool:
	return sim.finished == 1


## The player's result, the same for the screen and for the replay check: {place, kos, animal, seed, survived_s, players}.
func human_result() -> Dictionary:
	var me: MatchSim.Ent = sim.ents[human]
	return {
		"place": me.place if me.place > 0 else 1, "kos": me.kos, "animal": str(sim.animals[me.id].id), "seed": sim.seed_value,
		"survived_s": (me.died_tick if me.died_tick >= 0 else sim.tick) / 30, "players": sim.ents.size(),
	}


func human_out() -> bool:
	return human >= 0 and not sim.ents[human].alive
