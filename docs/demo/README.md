# The demo recording

The one thing at the top of the README has to land in twenty seconds, without
sound, for someone who has not read a word yet. So it shows the argument rather
than the feature list:

> The menu bar says **Work**. You `cd` into a pinned repo, run `claude`, and it
> comes up on **acme** anyway.

That is the only claim in the project that a screenshot cannot make, because the
point is the disagreement between two things on screen at once.

## The frame

Terminal on the left, the macOS menu bar visible along the top. Not fullscreen —
the menu bar item reading `Work` is half the shot, and a fullscreen terminal hides
it. Around 1280×720 of screen, captured at 2x.

Switch to a profile that is **not** the one you are about to pin to, before you
start recording. If the menu bar already says `acme`, nothing happens on screen.

## The beats

| at | on screen |
|---|---|
| 0:00 | prompt in `~/projects/acme`, menu bar reads `Work` |
| 0:02 | `lane lock acme` → `pinned ~/projects/acme to 'acme'` |
| 0:06 | `lane` → `active: work`, `pinned: acme` — the two disagree, in writing |
| 0:11 | `claude` → `lanes: ~/projects/acme is pinned to 'acme' — using it for this command.` |
| 0:15 | Claude Code starts, signed in as the acme account |
| 0:19 | hold. Menu bar still reads `Work`. |

Hold that last frame for a full second before you stop. A GIF loops, and without
the hold the payoff is gone before it registers.

## Recording it

`record.sh` types the commands for you at a readable pace and runs them for real,
so the output is the real output. Start your screen recorder, then:

```bash
cd ~/projects/acme
~/path/to/lanes/docs/demo/record.sh
```

It stops before `claude` renders its banner and tells you when to cut.

For the capture itself, macOS `Cmd+Shift+5` at 2x is enough. Then:

```bash
# 12 fps and a shared palette keep a 20s terminal clip near 1.5 MB
ffmpeg -i demo.mov -vf "fps=12,scale=1280:-1:flags=lanczos,split[a][b];\
[a]palettegen=max_colors=64[p];[b][p]paletteuse=dither=bayer" \
  -loop 0 docs/img/demo.gif
```

Check the size before committing. `.gitignore` keeps capture masters out of the
repository on purpose — `docs/marketing/` is for the `.mov` — and the README's
existing walkthrough is hosted by GitHub rather than committed for the same
reason. A GIF over about 3 MB belongs in a release asset or an issue attachment
that GitHub hosts, linked from the README, not in `docs/img/`.

Once `docs/img/demo.gif` exists, uncomment the image at the top of `README.md`.

## Do not fake it

An animated SVG or a hand-written "terminal" would be quicker and would look
almost right, and it would be a picture of software behaving as intended rather
than evidence that it does. Everything else in this repository is careful about
that distinction — the site's product shot says in a comment that it is a
reconstruction. Record the real thing.
