extends Node2D
# Rock-Paper-Scissors maze, Assignment 3 version. Godot 4.x. Everything is drawn in code.
# Weapons: 0 = rock, 1 = paper, 2 = scissors.
#
# Assignment 3 additions (marked with "A3"):
#   - state machine: menu / play / pause / game over
#   - per-finger touch tracking + swipe on drag (fixes "swipe while switching weapon")
#   - pause button, auto-pause when the app loses focus
#   - 2 mazes, level-up, more enemies per level
#   - saved best score, sound effects generated in code, vibration, screen shake, particles

enum State { MENU, PLAY, PAUSE, OVER }

const MAZES := [
	["###########", "#.........#", "#.##.#.##.#", "#.#.....#.#", "#...###...#",
	"#.#.....#.#", "#.#.###.#.#", "#.........#", "#.#.###.#.#", "#.#.....#.#",
	"#...###...#", "#.#.....#.#", "#.##.#.##.#", "#.........#", "###########"],
	["###########", "#....#....#", "#.##.#.##.#", "#.........#", "#.##.#.##.#",
	"#....#....#", "##.#####.##", "#....#....#", "#.##.#.##.#", "#.#.....#.#",
	"#.#.###.#.#", "#.........#", "#.##.#.##.#", "#.........#", "###########"],
]
const SPAWNS: Array[Vector2i] = [Vector2i(1, 1), Vector2i(9, 1), Vector2i(1, 7),
	Vector2i(9, 7), Vector2i(5, 3), Vector2i(3, 7)]
const W := 11
const H := 15
const CELL := 44.0
const ORIGIN := Vector2(28, 120)
const START := Vector2i(5, 13)
const DIRS: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
const COLORS: Array[Color] = [Color("8d8aa8"), Color("f2e6c9"), Color("ff7a7a")]
const BG := Color("14102b")
const BTN_Y := 800.0
const PAUSE_BTN := Rect2(452, 8, 64, 64)  # A3: big enough for a thumb
const SWIPE_MIN := 24.0
const SAVE_PATH := "user://save.cfg"
const VIBRATE := true

class Mover:
	var cell := Vector2i.ZERO
	var dir := Vector2i.ZERO
	var p := 0.0
	var moving := false
	var kind := 0
	var dead := 0.0
	var spawn := Vector2i.ZERO
	func pos() -> Vector2:
		return Vector2(cell) + Vector2(dir) * p

var map: Array = MAZES[0]
var pellets := {}
var hero := Mover.new()
var enemies: Array[Mover] = []
var score := 0
var best := 0
var lives := 3
var level := 1
var weapon := 0
var inv := 0.0
var time := 0.0
var state: State = State.MENU
var new_best := false
var over_t := 0.0
var queued := Vector2i.ZERO
var queue_t := 0.0
var touches := {}  # A3: finger index -> swipe start position
var floaters: Array = []
var particles: Array = []
var shake := 0.0
var flash := 0.0
var banner := 0.0
var sfx := {}
var players: Array[AudioStreamPlayer] = []

func _ready() -> void:
	load_best()
	for i in 4:
		var pl := AudioStreamPlayer.new()
		add_child(pl)
		players.append(pl)
	sfx["pellet"] = make_tone(900.0, 0.03, 0.15)
	sfx["click"] = make_tone(700.0, 0.05, 0.3)
	sfx["kill"] = make_tone(500.0, 0.18, 0.4, 900.0)
	sfx["hit"] = make_tone(260.0, 0.35, 0.5, -400.0)
	sfx["level"] = make_tone(450.0, 0.45, 0.4, 700.0)
	sfx["over"] = make_tone(330.0, 0.7, 0.5, -280.0)

func beats(a: int, b: int) -> bool:
	return (a == 0 and b == 2) or (a == 2 and b == 1) or (a == 1 and b == 0)

func is_free(c: Vector2i) -> bool:
	return c.x >= 0 and c.y >= 0 and c.x < W and c.y < H and map[c.y][c.x] != "#"

func fill_pellets() -> void:
	for y in H:
		for x in W:
			if is_free(Vector2i(x, y)):
				pellets[Vector2i(x, y)] = true

# ---------- save / sound / vibration (A3) ----------
func load_best() -> void:
	var cf := ConfigFile.new()
	if cf.load(SAVE_PATH) == OK:
		best = int(cf.get_value("score", "best", 0))

func save_best() -> void:
	var cf := ConfigFile.new()
	cf.set_value("score", "best", best)
	cf.save(SAVE_PATH)

# Builds a short beep in memory, so the project needs no audio files.
func make_tone(freq: float, dur: float, vol: float, slide := 0.0) -> AudioStreamWAV:
	var rate := 22050
	var n := int(rate * dur)
	var data := PackedByteArray()
	data.resize(n * 2)
	var phase := 0.0
	for i in n:
		var t := float(i) / rate
		phase += TAU * (freq + slide * t) / rate
		var env := 1.0 - float(i) / n
		var s := signf(sin(phase)) * 0.5 + sin(phase) * 0.5
		data.encode_s16(i * 2, int(clampf(s * env * vol, -1.0, 1.0) * 32767.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = rate
	w.stereo = false
	w.data = data
	return w

func play(sound: String) -> void:
	if not sfx.has(sound):
		return
	for pl in players:
		if not pl.playing:
			pl.stream = sfx[sound]
			pl.play()
			return

func buzz(ms: int) -> void:
	if VIBRATE:
		Input.vibrate_handheld(ms)

# ---------- game flow ----------
func new_game() -> void:
	score = 0
	lives = 3
	level = 1
	weapon = 0
	new_best = false
	floaters.clear()
	particles.clear()
	hero = Mover.new()
	load_level()
	state = State.PLAY
	touches.clear()
	play("click")

func load_level() -> void:
	map = MAZES[(level - 1) % MAZES.size()]
	pellets.clear()
	fill_pellets()
	pellets.erase(START)
	hero.cell = START
	hero.dir = Vector2i.ZERO
	hero.p = 0.0
	hero.moving = false
	queued = Vector2i.ZERO
	inv = 1.5
	banner = 1.6
	enemies.clear()
	var count := mini(3 + level, SPAWNS.size())
	for i in count:
		var e := Mover.new()
		e.cell = SPAWNS[i]
		e.spawn = SPAWNS[i]
		e.kind = i % 3
		enemies.append(e)

func end_game() -> void:
	state = State.OVER
	over_t = 0.0
	touches.clear()
	if score > best:
		best = score
		new_best = true
		save_best()
	play("over")

func toggle_pause() -> void:
	if state == State.PLAY:
		state = State.PAUSE
		play("click")
	elif state == State.PAUSE:
		state = State.PLAY
	touches.clear()

func do_action(id: String) -> void:
	match id:
		"play", "restart":
			new_game()
		"resume":
			toggle_pause()
		"menu":
			state = State.MENU
			touches.clear()
			play("click")

# Auto-pause when the player swipes the app away or gets a call (A3).
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_APPLICATION_PAUSED:
		if state == State.PLAY:
			state = State.PAUSE
			touches.clear()

# ---------- input ----------
func overlay_buttons() -> Array:
	match state:
		State.MENU:
			return [{"r": Rect2(120, 560, 300, 80), "t": "PLAY", "id": "play"}]
		State.PAUSE:
			return [{"r": Rect2(120, 400, 300, 70), "t": "RESUME", "id": "resume"},
				{"r": Rect2(120, 490, 300, 70), "t": "RESTART", "id": "restart"},
				{"r": Rect2(120, 580, 300, 70), "t": "MENU", "id": "menu"}]
		State.OVER:
			return [{"r": Rect2(120, 480, 300, 70), "t": "PLAY AGAIN", "id": "restart"},
				{"r": Rect2(120, 570, 300, 70), "t": "MENU", "id": "menu"}]
	return []

func on_press(idx: int, pos: Vector2) -> void:
	if state != State.PLAY:
		for b in overlay_buttons():
			var r: Rect2 = b["r"]
			if r.has_point(pos):
				if state == State.OVER and over_t < 0.6:
					return  # ignore the tap that was meant for the last swipe
				do_action(b["id"])
				return
		return
	if PAUSE_BTN.has_point(pos):
		toggle_pause()
		return
	if pos.y > BTN_Y:
		select_weapon(clampi(int(pos.x / 180.0), 0, 2))
		return
	touches[idx] = pos  # start of a swipe for this finger

func select_weapon(w: int) -> void:
	if w != weapon:
		weapon = w
		play("click")

func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			on_press(event.index, event.position)
		else:
			touches.erase(event.index)
	elif event is InputEventScreenDrag:
		# A3: the swipe fires while the finger is still moving, one finger at a time
		if touches.has(event.index):
			var d: Vector2 = event.position - touches[event.index]
			if d.length() > SWIPE_MIN:
				if absf(d.x) > absf(d.y):
					queue_dir(Vector2i(1 if d.x > 0.0 else -1, 0))
				else:
					queue_dir(Vector2i(0, 1 if d.y > 0.0 else -1))
				touches[event.index] = event.position
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.physical_keycode:
			KEY_RIGHT: queue_dir(Vector2i(1, 0))
			KEY_LEFT: queue_dir(Vector2i(-1, 0))
			KEY_DOWN: queue_dir(Vector2i(0, 1))
			KEY_UP: queue_dir(Vector2i(0, -1))
			KEY_1: select_weapon(0)
			KEY_2: select_weapon(1)
			KEY_3: select_weapon(2)
			KEY_P, KEY_ESCAPE: toggle_pause()
			KEY_SPACE, KEY_ENTER:
				if state == State.MENU or (state == State.OVER and over_t > 0.6):
					new_game()
				elif state == State.PAUSE:
					toggle_pause()

func queue_dir(d: Vector2i) -> void:
	if state != State.PLAY:
		return
	queued = d
	queue_t = 0.4  # swipe is remembered briefly, so you can turn at the next junction

# ---------- update ----------
func _process(delta: float) -> void:
	if state == State.PLAY:
		update_game(delta)
	elif state == State.OVER:
		over_t += delta
	shake = maxf(0.0, shake - delta * 2.5)
	flash = maxf(0.0, flash - delta * 2.0)
	position = Vector2(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * shake * 8.0
	queue_redraw()

func advance(m: Mover, speed: float, delta: float, is_hero: bool) -> void:
	if not m.moving:
		return
	m.p += speed * delta
	while m.p >= 1.0:
		m.cell += m.dir
		m.p -= 1.0
		if is_hero:
			on_hero_cell()
		else:
			pick_enemy_dir(m)
		if not m.moving:
			m.p = 0.0
			break

func on_hero_cell() -> void:
	if pellets.erase(hero.cell):
		score += 10
		play("pellet")
		if pellets.is_empty():
			level += 1  # A3: next maze, more enemies
			load_level()
			play("level")
			buzz(60)
			return
	# turn in mid-flight: take the queued direction as soon as that way is open
	if queued != Vector2i.ZERO and is_free(hero.cell + queued):
		hero.dir = queued
		queued = Vector2i.ZERO
	if not is_free(hero.cell + hero.dir):
		hero.moving = false

func pick_enemy_dir(m: Mover) -> void:
	var opts: Array[Vector2i] = []
	for d in DIRS:
		if is_free(m.cell + d) and d != -m.dir:
			opts.append(d)
	if opts.is_empty():
		for d in DIRS:
			if is_free(m.cell + d):
				opts.append(d)
	if randf() < 0.4:
		opts.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
			return Vector2(m.cell + a).distance_to(Vector2(hero.cell)) < Vector2(m.cell + b).distance_to(Vector2(hero.cell)))
		m.dir = opts[0]
	else:
		m.dir = opts.pick_random()

func burst(cell_pos: Vector2, col: Color) -> void:
	for i in 12:
		var a := randf() * TAU
		particles.append({"pos": cell_pos, "vel": Vector2.from_angle(a) * randf_range(1.5, 4.0), "t": 0.0, "col": col})

func update_game(delta: float) -> void:
	time += delta
	inv = maxf(0.0, inv - delta)
	banner = maxf(0.0, banner - delta)
	queue_t -= delta
	if queue_t <= 0.0:
		queued = Vector2i.ZERO
	# instant U-turn while sliding
	if hero.moving and queued != Vector2i.ZERO and queued == -hero.dir:
		hero.cell += hero.dir
		hero.dir = -hero.dir
		hero.p = 1.0 - hero.p
		queued = Vector2i.ZERO
	if not hero.moving and queued != Vector2i.ZERO:
		if is_free(hero.cell + queued):
			hero.dir = queued
			hero.moving = true
			hero.p = 0.0
		queued = Vector2i.ZERO
	advance(hero, 8.0, delta, true)

	var speed := 2.6 + minf(0.2 * level + score / 3000.0, 1.8)
	for e in enemies:
		if e.dead > 0.0:
			e.dead -= delta
			if e.dead <= 0.0:
				e.cell = e.spawn
				e.p = 0.0
				e.moving = false
				e.kind = randi() % 3
			continue
		if not e.moving:
			pick_enemy_dir(e)
			e.moving = true
		advance(e, speed, delta, false)
		if hero.pos().distance_to(e.pos()) < 0.6:
			if e.kind == weapon:
				continue  # same weapon: pass through
			if beats(weapon, e.kind):
				score += 100
				floaters.append({"pos": e.pos(), "text": "+100", "t": 0.0, "col": Color("ffd166")})
				burst(e.pos(), COLORS[e.kind])
				shake = maxf(shake, 0.3)
				buzz(40)
				play("kill")
				e.dead = 2.5
			elif inv <= 0.0:
				lives -= 1
				inv = 1.6
				shake = 1.0
				flash = 1.0
				buzz(150)
				play("hit")
				floaters.append({"pos": hero.pos(), "text": "-1 life", "t": 0.0, "col": Color("ff5d73")})
				hero.cell = START
				hero.dir = Vector2i.ZERO
				hero.p = 0.0
				hero.moving = false
				queued = Vector2i.ZERO
				if lives <= 0:
					end_game()
					return
	for f in floaters:
		f["t"] += delta
	floaters = floaters.filter(func(f): return f["t"] < 0.9)
	for pt in particles:
		pt["t"] += delta
		pt["pos"] += pt["vel"] * delta
	particles = particles.filter(func(pt): return pt["t"] < 0.5)

# ---------- drawing ----------
func to_px(c: Vector2) -> Vector2:
	return ORIGIN + (c + Vector2(0.5, 0.5)) * CELL

func draw_icon(kind: int, c: Vector2, r: float, col: Color) -> void:
	match kind:
		0: draw_circle(c, r * 0.65, col)
		1: draw_rect(Rect2(c - Vector2(r * 0.55, r * 0.7), Vector2(r * 1.1, r * 1.4)), col)
		2:
			draw_line(c + Vector2(-r, -r) * 0.7, c + Vector2(r, r) * 0.7, col, 5.0)
			draw_line(c + Vector2(-r, r) * 0.7, c + Vector2(r, -r) * 0.7, col, 5.0)

func text_at(t: String, y: float, size: int, col: Color, x := 0.0, align := HORIZONTAL_ALIGNMENT_CENTER, w := 540.0) -> void:
	draw_string(ThemeDB.fallback_font, Vector2(x, y), t, align, w, size, col)

func draw_button(r: Rect2, label: String, primary := false) -> void:
	draw_rect(r, Color("58e6c4") if primary else Color("3b3190"))
	draw_rect(r, Color("ffd166"), false, 3.0)
	text_at(label, r.position.y + r.size.y * 0.5 + 10.0, 28, BG if primary else Color.WHITE, r.position.x, HORIZONTAL_ALIGNMENT_CENTER, r.size.x)

func _draw() -> void:
	draw_rect(Rect2(-20, -20, 580, 1000), BG)
	for y in H:
		for x in W:
			if map[y][x] == "#":
				var r := Rect2(ORIGIN + Vector2(x, y) * CELL + Vector2(1, 1), Vector2(CELL - 2, CELL - 2))
				draw_rect(r, Color("2a2260"))
				draw_rect(r, Color("4a3b9c"), false, 2.0)
	for c in pellets:
		draw_circle(to_px(Vector2(c)), 4.0, Color("ffd166"))
	for e in enemies:
		if e.dead > 0.0:
			continue
		var c := to_px(e.pos())
		draw_circle(c, 18.0, BG)
		draw_arc(c, 18.0, 0.0, TAU, 32, COLORS[e.kind], 4.0)
		draw_icon(e.kind, c, 11.0, COLORS[e.kind])
	if not (inv > 0.0 and int(time * 10.0) % 2 == 1):
		var hc := to_px(hero.pos())
		draw_circle(hc, 18.0, Color("58e6c4"))
		draw_icon(weapon, hc, 11.0, BG)
	for pt in particles:
		var k: float = 1.0 - float(pt["t"]) / 0.5
		draw_circle(to_px(pt["pos"]), 5.0 * k, Color(pt["col"], k))
	for f in floaters:
		var fp := to_px(f["pos"]) - Vector2(0, f["t"] * 40.0)
		text_at(f["text"], fp.y, 22, f["col"], fp.x - 40.0, HORIZONTAL_ALIGNMENT_CENTER, 80.0)
	if banner > 0.0 and state == State.PLAY:
		draw_rect(Rect2(0, 410, 540, 80), Color(BG, 0.85))
		text_at("LEVEL " + str(level), 466, 44, Color("ffd166"))
	# HUD
	text_at("Score " + str(score), 50, 28, Color.WHITE, 24.0, HORIZONTAL_ALIGNMENT_LEFT)
	text_at("Level " + str(level), 84, 20, Color("c9c2f0"), 24.0, HORIZONTAL_ALIGNMENT_LEFT)
	text_at("Best " + str(best), 100, 20, Color("c9c2f0"), 0.0, HORIZONTAL_ALIGNMENT_RIGHT, 516.0)
	for i in 3:
		draw_circle(Vector2(240 + i * 30, 80), 10.0, Color("ff5d73") if i < lives else Color("3b3190"))
	# pause button
	draw_rect(PAUSE_BTN, Color("2a2260"))
	draw_rect(PAUSE_BTN, Color("4a3b9c"), false, 2.0)
	var pc := PAUSE_BTN.get_center()
	draw_rect(Rect2(pc.x - 12, pc.y - 13, 8, 26), Color.WHITE)
	draw_rect(Rect2(pc.x + 4, pc.y - 13, 8, 26), Color.WHITE)
	# weapon buttons
	for i in 3:
		var br := Rect2(10 + i * 180, BTN_Y, 160, 120)
		draw_rect(br, Color("3b3190") if i == weapon else Color("2a2260"))
		if i == weapon:
			draw_rect(br, Color("ffd166"), false, 4.0)
		draw_icon(i, br.get_center(), 30.0, COLORS[i])
	# red flash when the hero is hit
	if flash > 0.0:
		draw_rect(Rect2(-20, -20, 580, 1000), Color(1.0, 0.2, 0.3, flash * 0.35))
	if state != State.PLAY:
		draw_overlay()

func draw_overlay() -> void:
	draw_rect(Rect2(-20, -20, 580, 1000), Color(BG, 0.9))
	match state:
		State.MENU:
			text_at("Rock Paper Scissors", 140, 40, Color.WHITE)
			text_at("Maze chase", 180, 24, Color("c9c2f0"))
			var rules := [[0, 2], [2, 1], [1, 0]]
			for i in 3:
				var y := 260.0 + i * 60.0
				draw_icon(rules[i][0], Vector2(170, y), 16.0, COLORS[rules[i][0]])
				text_at("beats", y + 8.0, 22, Color("c9c2f0"), 0.0, HORIZONTAL_ALIGNMENT_CENTER, 540.0)
				draw_icon(rules[i][1], Vector2(370, y), 16.0, COLORS[rules[i][1]])
			text_at("Swipe to slide through the maze", 470, 22, Color("c9c2f0"))
			text_at("Pick a weapon with the buttons below", 502, 22, Color("c9c2f0"))
			text_at("Best " + str(best), 700, 28, Color("ffd166"))
		State.PAUSE:
			text_at("Paused", 330, 44, Color.WHITE)
		State.OVER:
			text_at("Game over", 290, 44, Color.WHITE)
			text_at("Score " + str(score) + "   Level " + str(level), 350, 28, Color("c9c2f0"))
			if new_best:
				text_at("NEW BEST!", 400, 30, Color("ffd166"))
			else:
				text_at("Best " + str(best), 400, 26, Color("c9c2f0"))
	var first := true
	for b in overlay_buttons():
		draw_button(b["r"], b["t"], first)
		first = false
