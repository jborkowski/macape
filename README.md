# macape

Reliable home-row modifiers for macOS, in user space.

`A S D F J K L ;` act as **Cmd / Opt / Ctrl / Shift** when held, and as their normal letters when tapped. No kext, no DriverKit, no Karabiner — just a small Swift daemon talking to `CGEventTap` with Accessibility permission.

## Install (Homebrew)

```bash
brew tap jborkowski/macape https://github.com/jborkowski/macape.git
brew install --HEAD jborkowski/macape/macape
```

First-install setup:

```bash
mkdir -p ~/.config/macape
cp "$(brew --prefix)/etc/macape/macape.conf.example" ~/.config/macape/macape.conf
brew services start jborkowski/macape/macape
```

### Granting Accessibility

macape needs Accessibility permission to intercept key events. Grant it once:

1. Open **System Settings → Privacy & Security → Accessibility**.
2. Add `$(brew --prefix)/opt/macape/bin/macape`.
3. `brew services restart jborkowski/macape/macape`.

Logs live at `$(brew --prefix)/var/log/macape.log`.

### Optional: Menu bar controller

`macape-bar` is a separate menu-bar app that talks to the daemon over a local unix socket. Install it if you want a GUI to enable/disable remapping, release stuck keys, reload config, and view live metrics.

```bash
brew install --HEAD jborkowski/macape/macape-bar
brew services start jborkowski/macape/macape-bar
```

## Configuration

Config file: `~/.config/macape/macape.conf` (INI-ish, `#` for comments).

```ini
hold_timeout_ms = 200
max_modifier_hold_ms = 10000

# Per-key override: key = modifier [hold_ms]
A = lcmd 180
S = lalt
D = lctl
F = lsft
J = rsft
K = rctl
L = ralt
; = rcmd

[layer space]
hold = space
j = left
k = down
l = up
; = right

# Optional one-way key swaps (instant remap, no hold/tap delay)
[swap]
caps_lock = escape
right_command = left_control
```

**Modifier names** (case-insensitive): `lcmd rcmd cmd command lmet rmet`, `lalt ralt alt option opt`, `lctl rctl ctl ctrl control`, `lsft rsft sft shift`. Left/right is accepted but currently collapsed to the same flag mask — apps that distinguish sides won't see the difference.

**Keycaps:** any letter `a–z`, plus `;` `'` `,` `.` `/` `[` `]` `\` `-` `=` `` ` ``, arrow aliases `left right up down`, and special keys `escape esc caps_lock tab return delete backspace left_command right_command left_control right_control left_option right_option left_shift right_shift fn`.

**Swaps:** add a `[swap]` section for instant one-way remaps (`source = target`). These run before home-row and layer logic — useful for `caps_lock = escape` or `right_command = left_control`. Swaps are not mutual; pressing the target key is unchanged.

If the config file is missing, the built-in defaults above apply.

## How it works

When you press a home-row key, macape doesn't commit yet — it parks the event in a deferred buffer. Hold/tap timing uses **hardware event timestamps** (`CGEvent.timestamp` in the mach-absolute clock domain), not callback wall time, so the configured `hold_timeout_ms` boundary is accurate regardless of OS delivery latency.

Each pending key gets a **deadline** (`press time + hold_timeout_ms`). A one-shot timer fires at that deadline for isolated holds; every subsequent key event also advances the clock first. Two outcomes:

- **You release the key before the deadline** → it was a tap. The letter is replayed (with its original timestamp), followed by anything that piled up in the buffer.
- **You keep holding past the deadline** → it's promoted to a modifier. The buffer is flushed with the modifier flag applied, and subsequent keys are flagged in-flight until release.

If you're already physically holding a real modifier (Cmd, Opt, Ctrl, Shift), macape gets out of the way so shortcuts like Cmd+A still work.

Hold **Space** and press `j/k/l/;` to emit arrow keys (configurable via `[layer space]`). While Space is held the layer always wins, so those keys never act as letters or home-row modifiers. The emitted arrows carry only real physical modifiers — synthetic home-row modifier flags are stripped, so a home-row Cmd won't turn into Cmd+Arrow; hold a real Cmd if you want Cmd+Arrow. Layer arrows use only real physical modifiers (Cmd/Opt/Ctrl/Shift you are actually holding), not synthetic home-row modifier flags — so `A(cmd)+space+j` becomes Left, not Cmd+Left; use a real Cmd for cmd+arrow.

## Stuck key recovery

macape watches for desync between its internal state and the OS keyboard state (lost key-ups, modifiers held past `max_modifier_hold_ms`, etc.). When detected, it force-releases modifiers and emits a `stuck` event. You can also trigger recovery manually via IPC `clearStuck`.

On **system wake** (lid open, resume from sleep), macape resets all virtual modifier/buffer state and re-enables the event tap — key-up events are often lost across sleep, and hold/tap clocks (`mach_absolute_time`) pause while asleep so stale timers must not fire on wake.

## IPC control

The daemon listens on `~/.config/macape/macape.sock` (newline-delimited JSON). Commands: `enable`, `disable`, `toggle`, `status`, `reload`, `metrics`, `clearStuck`.

```bash
macape --stats
```

## Build from source

```bash
swift build -c release
.build/release/macape -c ./macape.conf.example
```

To also build the optional menu-bar controller:

```bash
swift build -c release --product macape-bar
.build/release/macape-bar
```

Optional flags:

- `-c <path>` — use a custom config file (overrides `~/.config/macape/macape.conf`).
- `--stats` — print daemon status/metrics over IPC.
- `-h`, `--help` — usage.

## Caveats

> macape-bar is entirely optional — the daemon runs standalone without it.

- **Tap latency:** every home-row keypress is delayed until released or until `hold_timeout_ms` elapses. Typical typing taps are < 100 ms, so most people don't notice. If you do, lower `hold_timeout_ms` (say 150 ms) or tune per-key.
- **Accessibility is per-binary.** If you reinstall macape into a different path, re-grant.
- **No left/right distinction yet.** Both `lcmd` and `rcmd` produce the same flag bits — fine for shortcuts, irrelevant for apps that care about handedness.
- **Event taps can be disabled by macOS** if a callback takes too long. macape re-enables them automatically, resets state, and logs the event.

## License

MIT.
