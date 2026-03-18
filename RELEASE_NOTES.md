## What's New

### Transcript Enhancement
Voice notes can now be cleaned up before hitting the clipboard. A new **Transcript** setting in the Prompt section offers three levels:
- **Raw** — current behavior, no changes
- **Clean** — removes filler words (um, uh, you know, basically, etc.)
- **Formatted** — Clean + capitalizes sentences, adds trailing punctuation, deduplicates adjacent words

`[ref:N]` markers are preserved through all enhancement levels.

### Recording Overlay
- Draggable floating overlay shows waveform and stop button during recording
- Snaps back to menu bar icon position when dragged near it
- New "Show recording overlay" toggle in Behavior settings

### UI Polish
- Redesigned settings with consistent two-column layout
- Scroll fade masks on long transcriptions
- Blur/scale morph transitions on page titles
- Hover effects on footer links
- Animated escape-key cancel
- Consolidated auto-copy toggles

### Fixes
- Fix popover unresponsiveness on rapid menu bar clicks
- Skip initial audio buffers to prevent phantom transcription
- Clamp oversized flow layout items to container width
- Fix processing audio indicator spacing
- Use Carbon RegisterEventHotKey to properly consume global shortcuts
