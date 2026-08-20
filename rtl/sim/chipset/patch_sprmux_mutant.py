#!/usr/bin/env python3
"""Generate a deliberately broken agnus_spritedma.v for the negative control.

tb_sprite_mux_load.sv claims the sprite-select multiplex is sound. That claim is
worthless unless the bench is shown to FAIL on a mux that is broken in exactly
the ways the hypothesis proposes. Each mutation below is a single-token edit of
the real RTL; `null` is the identity, and must still PASS, which proves the
patcher itself is not what breaks the design.

  null   identity -- control for the control
  win00  latch window hpos[2:1]==2'b01 -> 2'b00.  Moves both latches one hpos
         pair earlier, to $30/$31, where the `sprite` register still holds the
         PREVIOUS sprite.  Sprite k then makes its DMA decision from sprite
         k-1's comparison: the exact "one sprite briefly uses another's vpos
         compare" failure this round is hunting.
  alias  vstart read sprpos[sprsel] -> sprpos[sprsel^1].  Adjacent scan-slot
         aliasing on the shared comparator input.
  lock   scan lock sprsel[2]==hpos[0] -> sprsel[1]==hpos[0].  The scan is no
         longer phase-locked to the colour clock, so it drifts against the
         latch window.
  slow   scan advance gated by clk7_en, i.e. the mux runs 4x too slow to cover
         8 slots inside one latch window.  This is literally "the multiplex
         cannot keep up", and is the mutation whose failure rate should scale
         with the number of active sprites.

Usage: python patch_sprmux_mutant.py <null|win00|alias|lock|slow> <outfile>
"""
import sys, os

SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   '..', '..', 'agnus_spritedma.v')

MUT = {
    'null':  [],
    'win00': [("hpos[2:1]==2'b01", "hpos[2:1]==2'b00", 2)],
    'alias': [("assign vstart[7:0] = sprpos[sprsel];",
               "assign vstart[7:0] = sprpos[sprsel^3'd1];", 1)],
    'lock':  [("if (sprsel[2]==hpos[0])", "if (sprsel[1]==hpos[0])", 1)],
    'slow':  [("if (sprsel[2]==hpos[0])", "if (sprsel[2]==hpos[0] && clk7_en)", 1)],
}


def main(name, out):
    if name not in MUT:
        sys.exit("unknown mutant %r (have %s)" % (name, ', '.join(MUT)))
    txt = open(SRC, 'r', newline='').read()
    for old, new, want in MUT[name]:
        got = txt.count(old)
        if got != want:
            sys.exit("mutant %s: expected %d occurrences of %r, found %d "
                     "-- RTL moved, refresh the patch" % (name, want, old, got))
        txt = txt.replace(old, new)
    with open(out, 'w', newline='') as f:
        f.write(txt)
    print("wrote %s (mutant=%s)" % (out, name))


if __name__ == '__main__':
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
