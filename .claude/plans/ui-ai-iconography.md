# "Smart" iconography plan (reference only — do not build yet)

Context for a future session. Goal: visually signal that duplicate
grouping and best-pick selection are "smart"/automated, using the sparkle
("diamond") icon convention that's become the de facto visual shorthand
for automated/intelligent features in current app UI (Gemini, Notion AI,
Photoshop's generative tools, etc. all use a 4-point sparkle/star-burst
shape for this).

**Reality check, worth remembering while implementing this**: nothing in
this app is machine learning. Grouping is EXIF-timestamp clustering +
perceptual hashing (pHash/Hamming distance), and "best pick" is Laplacian-
variance sharpness + exposure histogram scoring. All deterministic,
explainable math, see `python-mvp1/README.md` for the reference
implementation. The icon is fine as a visual convention; just don't pair
it with literal text claims like "AI-powered," "trained model," or "machine
learning" anywhere in the UI, since those are specific, checkable claims
this app can't back up. "Smart" and "Auto" are accurate; "AI" in body copy
is not.

## Icon

Use Flutter's Material Icons `Icons.auto_awesome` (the sparkle/diamond
shape) as the single consistent "smart feature" marker throughout the app.
Don't mix in other "AI-coded" icons (brain, robot, etc.), one consistent
symbol reads as an intentional design language; several different ones
reads as scattered decoration.

Pair it with a consistent accent color, distinct from the existing best-pick
green (`#22c55e`), so "this was auto-selected/auto-grouped" has its own
recognizable visual identity. Suggested: a purple-to-blue gradient
(`#8b5cf6` → `#3b82f6`), consistent with how most apps color-code their
"smart" features today.

## Where to place it

1. **Scan/start button** on the home screen — small sparkle prefix on the
   "Scan for duplicates" CTA.
2. **Scan progress screen** — animated/pulsing sparkle while the scan runs,
   reinforces that something automated is happening in the background.
3. **"BEST" badge** on the recommended photo in each group card — add the
   sparkle icon alongside (or instead of) the current plain badge, this is
   the single highest-value placement since it's the actual output of the
   scoring algorithm.
4. **Group card header** — small sparkle next to the group title/timestamp,
   signals "this grouping was automatic," not manually sorted.
5. **Summary/results screen** — sparkle next to the "N duplicate groups
   found" headline after a scan completes.

## Where NOT to use it

- Not on manual controls: checkboxes, the delete button, settings, any
  element that reflects a user action rather than an algorithmic decision.
- Not on every screen — reserve it for the 4-5 spots above. Overuse dilutes
  it into generic decoration and undercuts the "this specific thing was
  computed for you" signal, which is the actual point of using it.

## Copy guidelines (pair with the icon, don't rely on the icon alone)

Use: "Smart pick," "Auto-selected," "Smart grouping," "Automatically found."
Avoid: "AI," "AI-powered," "trained on your photos," "neural," "machine
learning," or any phrasing that asserts a specific technical mechanism this
app doesn't use. If a future session adds a proper "How this works" or
"About" screen, it should describe the real algorithm (timestamp clustering
+ perceptual hashing + sharpness scoring), not imply something else.

## Not in scope for this pass

- No onboarding/marketing copy changes beyond what's listed above.
- No changes to `python-mvp1/` (reference implementation only).
- No app icon/branding changes, this is in-app iconography only.
