# ZugLoot Media

`Griffy-Regular.ttf` — fantasy display face for the minimap ZL
badge (SIL Open Font License 1.1, by Neapolitan / google/fonts).
Source: https://github.com/google/fonts/tree/main/ofl/griffy

`CinzelDecorative-Bold.ttf` — spare fantasy face (same license, by
Natanael Gama). Kept as an alternate.

`ZL-Badge.tga` — the minimap badge, fully prerendered (no client-side
text): feathered black disc + Griffy gold `ZL` + halo glow, ink centered
by measured bbox. Uncompressed 32-bit TGA (client-readable). Regenerate:
PIL script paints the disc (solid core, smoothstep alpha rim), draws the
halo ring (8 dim-gold copies, blurred), then the main ink offset by the
measured bbox center — see bake script history.
