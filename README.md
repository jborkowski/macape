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

Grant Accessibility to the launched binary:

1. Open **System Settings → Privacy & Security → Accessibility**.
2. Add `$(brew --prefix)/opt/macape/bin/macape`.
3. `brew services restart jborkowski/macape/macape`.

Logs live at `$(brew --prefix)/var/log/macape.log`.

## Configuration

Config file: `~/.config/macape/macape.conf` (INI-ish, `#` for comments).

```ini
hold_timeout_ms = 200
tap_timeout_ms  = 200   # accepted for kanata parity; currently unused

# keycap = modifier
A = lcmd
S = lalt
D = lctl
F = lsft
J = rsft
K = rctl
L = ralt
; = rcmd
```

**Modifier names** (case-insensitive): `lcmd rcmd cmd command lmet rmet`, `lalt ralt alt option opt`, `lctl rctl ctl ctrl control`, `lsft rsft sft shift`. Left/right is accepted but currently collapsed to the same flag mask — apps that distinguish sides won't see the difference.

**Keycaps:** any letter `a–z`, plus `;` `'` `,` `.` `/` `[` `]` `\` `-` `=` `` ` ``.

If the config file is missing, the built-in defaults above apply.

## How it works

When you press a home-row key, macape doesn't commit yet — it parks the event in a small queue. Two things can happen:

- **You release the key before `hold_timeout_ms`** → it was a tap. The original letter is emitted, followed by anything that piled up in the queue (fast rollover stays correct).
- **You keep holding past the timeout** → it's promoted to a modifier. The queue is flushed with the modifier flag applied, and subsequent keys are flagged in-flight until release.

If you're already physically holding a real modifier (Cmd, Opt, Ctrl, Shift), macape gets out of the way so shortcuts like Cmd+A still work.

## Build from source

```bash
swift build -c release
.build/release/macape -c ./macape.conf.example
```

Optional flags:

- `-c <path>` — use a custom config file (overrides `~/.config/macape/macape.conf`).
- `-h`, `--help` — usage.

## Caveats

- **Tap latency:** every home-row keypress is delayed until released or until `hold_timeout_ms` elapses. Typical typing taps are < 100 ms, so most people don't notice. If you do, lower `hold_timeout_ms` (say 150 ms).
- **Accessibility is per-binary.** If you reinstall macape into a different path, re-grant.
- **No left/right distinction yet.** Both `lcmd` and `rcmd` produce the same flag bits — fine for shortcuts, irrelevant for apps that care about handedness.
- **Event taps can be disabled by macOS** if a callback takes too long. macape re-enables them automatically and logs the event.

## License

MIT.
