# Gantry — photographic campaign v5

Final: `gantry-two-modes-photo-v5.png`, 3000 × 2100.

The earlier photographs define the art direction: orange grazing light on black glass, angled
screen macros, ivory editorial panels, large short headlines and narrow light gutters.

Only the empty photographic monitor plate is generated, using built-in imagegen. Its exact prompt
is in `gantry-photo-source-v5-prompt.md`; its saved image is `gantry-photo-plate-v5.png`.

All app pixels come from the native AppKit exports documented in `native-source/README.md`.
`scripts/compose_photo_campaign.swift` places those actual images on the measured display plane
using CPU homography and bilinear sampling. A uniform photographic tone curve adjusts exposure
and black levels; no app controls, labels, progress indicators, AMS slots or icons are redrawn.
The mode-control annotation is located with the real exported view coordinates.

The pictured UI is macOS with demonstration printer data, as labeled. The composition does not
claim that generated Windows/Linux desktop shells are actual screenshots; none are fabricated.

Rebuild the final composition:

```sh
swiftc -O scripts/compose_photo_campaign.swift \
  -module-cache-path /private/tmp/gantry-swift-cache -o /private/tmp/gantry-compose-photo
/private/tmp/gantry-compose-photo design/marketing design/marketing/gantry-two-modes-photo-v5.png
```
