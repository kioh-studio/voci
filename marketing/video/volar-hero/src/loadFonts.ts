// loadFonts.ts — Inter (UI) + JetBrains Mono (keycaps/mono readouts) via @remotion/google-fonts.
// Called once at module load so both are ready before any frame renders.
import {loadFont as loadInter} from '@remotion/google-fonts/Inter';
import {loadFont as loadMono} from '@remotion/google-fonts/JetBrainsMono';

const inter = loadInter('normal', {weights: ['400', '500', '600'], subsets: ['latin']});
const mono = loadMono('normal', {weights: ['500', '600'], subsets: ['latin']});

export const interFontFamily = inter.fontFamily;
export const monoFontFamily = mono.fontFamily;
