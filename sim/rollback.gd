class_name Rollback
extends RefCounted
## Rollback netcode for online matches (phase 12a). Each screen runs the whole match itself; only player input travels.
## Own input is scheduled `delay` ticks ahead (less to roll back). Another player's input that hasn't arrived yet is
## predicted (their last known input). When real input arrives for a tick that was already played with a different
## prediction, the match goes back to a snapshot of that tick and is played again up to now. Because the sim and
## the bots are deterministic, every screen ends in the same state once all input is known.
## No network here: the caller moves `outbox` messages to the others and feeds what arrives into remote_input().

const MAX_ROLLBACK := 30 # ticks (1 s): further behind than this we wait instead of guessing
const NONE := [-1, -1, -1, -1]

var m: Match
var me := 0
var delay := 2
var tick := 0 # the next tick to play
var outbox: Array = [] # [[tick, cmd]] of own input to send
var rollbacks := 0 # how often we had to go back (for tuning and tests)
var resimulated := 0 # ticks played again

var _inputs := {} # tick -> {slot: cmd} (confirmed)
var _used := {} # tick -> {slot: cmd} (what was actually played: confirmed or predicted)
var _last := {} # slot -> latest confirmed cmd (the prediction)
var _snaps := {} # tick -> snapshot before playing it
var _redo_from := -1 # earliest tick played with a wrong prediction
var _next_unknown := {} # slot -> first tick whose input hasn't arrived (all before it are known)


func _init(match_: Match, my_slot: int, input_delay := 2) -> void:
	m = match_
	me = my_slot
	delay = input_delay
	# nobody can have input for the first `delay` ticks: they are known to be empty for everyone
	for t in delay:
		var row := {}
		for s in m.humans:
			row[s] = NONE
		_inputs[t] = row
	for s in m.humans:
		_next_unknown[s] = delay


## Own input for now; it plays `delay` ticks from now on every screen (including this one).
func local_input(cmd: Array) -> void:
	var t := tick + delay
	_confirm(me, t, cmd)
	outbox.append([t, cmd])


func remote_input(slot: int, t: int, cmd: Array) -> void:
	_confirm(slot, t, cmd)


func _confirm(slot: int, t: int, cmd: Array) -> void:
	var row: Dictionary = _inputs.get(t, {})
	if row.has(slot):
		return
	row[slot] = cmd
	_inputs[t] = row
	var k := int(_next_unknown.get(slot, 0))
	while (_inputs.get(k, {}) as Dictionary).has(slot):
		k += 1
	_next_unknown[slot] = k
	if not _last.has(slot) or int(_last[slot][0]) <= t:
		_last[slot] = [t, cmd]
	if t < tick:
		var used: Dictionary = _used.get(t, {})
		if used.get(slot, NONE) != cmd and (_redo_from == -1 or t < _redo_from):
			_redo_from = t


## May we play the next tick? Not when someone's input is more than MAX_ROLLBACK ticks behind.
func can_advance() -> bool:
	return tick - waiting_since() < MAX_ROLLBACK


## The first tick for which some player's input is still missing (inputs may arrive out of order).
func waiting_since() -> int:
	var lowest := tick
	for s in m.humans:
		lowest = mini(lowest, int(_next_unknown.get(s, 0)))
	return lowest


## Plays one tick (after replaying any ticks that turned out wrong). Returns false when it has to wait.
func advance() -> bool:
	if not can_advance():
		return false
	_redo()
	_play(tick)
	tick += 1
	_forget_old()
	return true


func _redo() -> void:
	if _redo_from == -1 or _redo_from >= tick:
		_redo_from = -1
		return
	assert(_snaps.has(_redo_from), "rollback further back than the snapshots reach")
	m.sim.restore(_snaps[_redo_from])
	rollbacks += 1
	for t in range(_redo_from, tick):
		_play(t)
		resimulated += 1
	_redo_from = -1


func _play(t: int) -> void:
	_snaps[t] = m.sim.snapshot()
	var row: Dictionary = _inputs.get(t, {})
	var used := {}
	for s in m.humans:
		used[s] = row[s] if row.has(s) else _predict(s, t)
	_used[t] = used
	m.step_many(used)


func _predict(slot: int, t: int) -> Array:
	# the latest confirmed input before t (players tend to keep doing what they did)
	var k := t - 1
	while k >= 0:
		var row: Dictionary = _inputs.get(k, {})
		if row.has(slot):
			return row[slot]
		k -= 1
	return NONE


func _forget_old() -> void:
	var keep_from := tick - MAX_ROLLBACK - 2
	for t in _snaps.keys():
		if t < keep_from:
			_snaps.erase(t)
			_used.erase(t)


## After the last tick: replay anything still predicted once all input is in. Returns the state hash.
func settle() -> int:
	_redo()
	return m.sim.state_hash()


## Every player's confirmed input per tick, for the replay check after the match.
func confirmed_inputs(until: int) -> Dictionary:
	var out := {}
	for s in m.humans:
		var list: Array = []
		for t in until:
			list.append((_inputs.get(t, {}) as Dictionary).get(s, NONE))
		out[s] = list
	return out
