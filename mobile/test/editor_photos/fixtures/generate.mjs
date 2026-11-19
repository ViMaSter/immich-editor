#!/usr/bin/env node
// Generates the reference fixtures for the Dart port of the web editor's pixel pipeline
// (CPU renderer and GPU shaders) from the web editor's own JavaScript.
//
//   node generate.mjs <web app public/edit directory> [output directory]
//
// The output directory defaults to the directory of this script. Needs Node >= 24.
// Everything is deterministic: rerunning with the same JavaScript gives the same files.
//
// FORMAT (version 1)
//
// recipes.json — array of
//   { name, input, normalized, describe, describeIds, isIdentity }
//   input        any JSON value fed to normalizeRecipe()
//   normalized   JSON.stringify(normalizeRecipe(input)) (a string; compare byte for byte)
//   describe     describeRecipe(input, filterNames())  (what the server shows)
//   describeIds  describeRecipe(input)                 (no names: filter ids)
//   isIdentity   isIdentity(input)
//
// geometry.json — { maxRectAt, constrainRect, defaultRect, effectiveRect, outputSize, outputMapping }
//   maxRectAt:     [{ W, H, angle, aspect, cx?, cy?, w, h }]
//   constrainRect: [{ rect: {cx, cy, w, h}, W, H, angle, out: {cx, cy, w, h} }]
//   defaultRect:   [{ W, H, angle, aspect (number|null), out: {cx, cy, w, h} }]
//   effectiveRect: [{ geometry, W0, H0, W, H, rect: {cx, cy, w, h} }]
//   outputSize:    [{ geometry, W0, H0, maxPixels (number|null = Infinity), width, height }]
//   outputMapping: [{ geometry, W0, H0, outWidth, outHeight, samples: [[u, v, x, y], …] }]
//   `geometry` is always normalised ({ rotate90, angle, aspect, crop: {cx, cy, w, h}|null }).
//
// pipeline/cases.json —
//   { version: 1,
//     source: { file, width, height },
//     masks:  { width, height, sky, subject, depth (file names), faces: [{x, y, w, h, score?}] },
//     cases:  [{ name, recipe (normalised), masks (bool), maxPixels (number|null = Infinity),
//                sourceWidth, sourceHeight (number|null = the image's own size),
//                width, height, file, faces?, rgba8?, rgb8? }] }
//   *.bin image files: raw little-endian Float32, interleaved RGB, row-major, no header
//     (source and outputs) or one channel (masks, in the upright source orientation).
//   Each case's `file` is the Float32 data returned by
//     render(source, recipe, { maxPixels, sourceSize, masks, tools: masks ? applyTools : null })
//   i.e. clamped to 0..1 but before 8-bit conversion. `faces` is transformMasks(...).faces
//   (face boxes in the output geometry) for cases with masks. `rgba8`/`rgb8` (some cases)
//   are toRGBA8()/toRGB8() of that output as raw bytes.
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const editDir = process.argv[2];
if (!editDir) {
    console.error('usage: node generate.mjs <web app public/edit directory> [output directory]');
    process.exit(2);
}
const outDir = resolve(process.argv[3] ?? dirname(fileURLToPath(import.meta.url)));
const load = name => import(pathToFileURL(join(resolve(editDir), name)).href);

const { defaultRecipe, describeRecipe, isIdentity, normalizeRecipe } = await load('recipe.js');
const geo = await load('geometry.js');
const { createImage, render, toRGB8, toRGBA8, transformMasks } = await load('pipeline.js');
const { applyTools } = await load('tools.js');
const { filterNames } = await load('filters.js');

const json = value => JSON.parse(JSON.stringify(value)); // exactly what the Dart side will read
const writeJson = (file, value) => writeFileSync(join(outDir, file), `${JSON.stringify(value, null, 1)}\n`);
const writeF32 = (file, array) => {
    const view = new DataView(new ArrayBuffer(array.length * 4));
    array.forEach((v, i) => view.setFloat32(i * 4, v, true));
    writeFileSync(join(outDir, file), new Uint8Array(view.buffer));
};

// ---- recipes.json -----------------------------------------------------------

const curve = n => Array.from({ length: n }, (_, i) => [i / (n - 1), ((i * 7) % n) / (n - 1)]);
const recipeInputs = [
    ['empty object', {}],
    ['null', null],
    ['array', [1, 2, 3]],
    ['string', 'vivid'],
    ['number', 42],
    ['default recipe', defaultRecipe()],
    ['clamped and unknown values dropped', { adjust: { contrast: 5, pop: -1, nonsense: 3 }, geometry: { angle: 90, rotate90: -1, aspect: 'weird' }, filter: { id: 'x'.repeat(99) } }],
    ['adjust strings', { adjust: { brightness: '0.5', contrast: ' -0.25 ', saturation: 'abc', warmth: '', tint: '0x10', hdr: '1e-1', shadows: 'Infinity', highlights: '-Infinity', skinTone: '\n\t0.3 ', blueTone: '.5', pop: '5.', vignette: '+.25' } }],
    ['adjust exotic number strings', { adjust: { brightness: '0b1', contrast: '0o7', saturation: '-0x1', warmth: '1_0', tint: 'NaN', skinTone: '\u00850.5', blueTone: '0x', hdr: '0X0', pop: '1.e-1', vignette: '﻿.75 ' } }],
    ['adjust booleans and null', { adjust: { brightness: true, contrast: false, saturation: null, pop: true, vignette: false } }],
    ['adjust arrays', { adjust: { brightness: [0.5], contrast: ['0.3'], saturation: [], warmth: [1, 2], tint: [[-0.2]], pop: [null], hdr: [[]], vignette: [true], skinTone: [{}] } }],
    ['adjust objects and strings as containers', { adjust: 'brightness', geometry: 'rotate', filter: ['vivid'], tools: 7, advanced: 'curves' }],
    ['rounding halves', { adjust: { brightness: 0.125, contrast: -0.125, saturation: 0.005, warmth: -0.005, tint: 0.015, skinTone: -0.015, blueTone: 0.285, pop: 0.335, hdr: 0.145, vignette: 0.995, shadows: 1.005, highlights: -0.555 } }],
    ['crop rounding', { geometry: { crop: { cx: 0.123456789, cy: 0.987654321, w: 0.333333333, h: 0.666666666 } } }],
    ['crop out of range', { geometry: { crop: { cx: -1, cy: 5, w: 0, h: 2 } } }],
    ['crop empty object', { geometry: { crop: {} } }],
    ['crop array', { geometry: { crop: [0.5, 0.5, 0.2, 0.2] } }],
    ['crop non-object', { geometry: { crop: 'full', angle: '3.5' } }],
    ['crop null and string fields', { geometry: { crop: { cx: null, cy: '0.25', w: '', h: '0.5' } } }],
    ['crop full frame off-centre', { geometry: { crop: { cx: 0.3, cy: 0.7, w: 1, h: 1 } } }],
    ['crop nearly full', { geometry: { crop: { cx: 0.5, cy: 0.5, w: 0.9995, h: 0.99949 } } }],
    ['rotate90 values', { geometry: { rotate90: 5, angle: 12.345, aspect: '16:9' } }],
    ['rotate90 negative half', { geometry: { rotate90: -2.5, angle: -0.005, aspect: 'original' } }],
    ['rotate90 half', { geometry: { rotate90: 2.5, angle: 0.005, aspect: 'square' } }],
    ['rotate90 string and huge angle', { geometry: { rotate90: '7', angle: -1e300, aspect: 'Original' } }],
    ['every aspect id', { geometry: { aspect: '9:16', angle: 44.999 } }],
    ['filter strengths', { filter: { id: 'mono', strength: 0.125 } }],
    ['filter strength string', { filter: { id: 'vivid', strength: '0.145' } }],
    ['filter unknown id', { filter: { id: 'unknown-filter', strength: 2 } }],
    ['filter id 40 chars', { filter: { id: 'f'.repeat(40), strength: -1 } }],
    ['filter id 41 chars', { filter: { id: 'f'.repeat(41) } }],
    ['filter id not a string', { filter: { id: 5, strength: null } }],
    ['filter learned', { filter: { id: 'learned-sepia', strength: 0.5 }, adjust: { pop: 0.2 } }],
    ['filter id with escapes', { filter: { id: 'a"b\\c\n\u0001\u001f\u007f é😀\ud800', strength: 1 } }],
    ['raw source', { source: { kind: 'raw', rawAssetId: 'abc-123', baselineId: 'base-1' } }],
    ['raw source without baseline', { source: { kind: 'raw', rawAssetId: 'abc-123', baselineId: 7 } }],
    ['raw source without asset id', { source: { kind: 'raw', rawAssetId: 5 } }],
    ['jpeg source with extras', { source: { kind: 'jpeg', rawAssetId: 'x', other: true } }],
    ['tools', { tools: { sky: { palette: 'ember', strength: 0.555 }, colorFocus: { strength: '0.5' }, portraitLight: { x: 0.0005, y: 0.3335, strength: 1.5 }, blur: { strength: 0.25, focus: { x: -1, y: 0.12345 } } } }],
    ['tools invalid', { tools: { sky: { palette: 'VIVID', strength: -1 }, colorFocus: 0.5, portraitLight: [], blur: { focus: 'centre' } } }],
    ['tools array', { tools: [] }],
    ['advanced scalars', { advanced: { exposure: 5, clarity: '0.5', dehaze: null, noise: '1', grain: true, sharpen: { amount: 2, radius: 0.1 } } }],
    ['advanced levels', { advanced: { levels: { inBlack: 0.6, inWhite: 0.2, gamma: 10, outBlack: -1, outWhite: '0.75' } } }],
    ['advanced levels null and empty', { advanced: { levels: { inBlack: null, inWhite: '', gamma: [], outBlack: undefined, outWhite: false } } }],
    ['advanced levels array', { advanced: { levels: [0.1, 0.9] } }],
    ['curves unsorted', { advanced: { curves: { rgb: [[0.8, 0.9], [0.2, 0.1], [0.5, 0.5]] } } }],
    ['curves duplicates and too close', { advanced: { curves: { r: [[0.5, 0.5], [0.5, 0.6], [0.503, 0.7], [0.506, 0.2], [0.505, 0.4], [0.512, 0.3]] } } }],
    ['curves too many', { advanced: { curves: { g: curve(20) } } }],
    ['curves out of range and odd points', { advanced: { curves: { b: [[-1, 2], [2, -1], ['0.3', '0.4'], [0.6], 0.7, null, { 0: 0.45, 1: 0.55 }, '57', [[0.2], [0.25]]] } } }],
    ['curves rounding', { advanced: { curves: { rgb: [[0.0005, 0.9995], [0.1234, 0.5678], [0.505, 0.5], [0.5, 0.25]] } } }],
    ['curves not arrays', { advanced: { curves: { rgb: 'abc', r: { 0: [0.5, 0.5] }, g: null, b: 3 } } }],
    ['curves as array', { advanced: { curves: [[0.5, 0.5]] } }],
    ['hsl', { advanced: { hsl: { red: { h: 2, s: -2, l: '0.5' }, blue: null, aqua: { h: 0.0005 }, unknown: { h: 1 } } } }],
    ['hsl array', { advanced: { hsl: [] } }],
    ['grading', { advanced: { grading: { shadows: { hue: 400, sat: 2 }, midtones: { hue: -10, sat: 0.25 }, highlights: { hue: 180.5, sat: '0.5' }, balance: 2, blending: -1 } } }],
    ['grading null hue', { advanced: { grading: { shadows: { hue: null }, midtones: { hue: '' }, highlights: { hue: 'x' } } } }],
    ['vignette', { advanced: { vignette: { amount: -2, midpoint: 2, roundness: -5, feather: null } } }],
    ['advanced identity after rounding', { advanced: { levels: { gamma: 1.0004 }, exposure: 0.0004 }, filter: { id: 'vivid', strength: 0 } }],
    ['advanced array', { advanced: [] }],
    ['unknown top-level keys', { foo: 1, v: 99, adjust: { pop: 0.3 }, __extra: { a: 1 } }],
    ['describe straighten and pop', { geometry: { angle: -4.7 }, adjust: { pop: 0.2 } }],
    ['describe everything', { geometry: { rotate90: 3, angle: 12, crop: { cx: 0.5, cy: 0.5, w: 0.5, h: 0.75 } }, adjust: Object.fromEntries(['hdr', 'brightness', 'contrast', 'whitePoint', 'highlights', 'shadows', 'blackPoint', 'saturation', 'warmth', 'tint', 'skinTone', 'blueTone', 'pop', 'vignette'].map((k, i) => [k, (i % 2 ? -1 : 1) * (i + 1) / 20])), filter: { id: 'teal', strength: 0.4 }, tools: { sky: { palette: 'stormy', strength: 0.1 }, colorFocus: { strength: 0.2 }, portraitLight: { strength: 0.3 }, blur: { strength: 0.4 } }, advanced: { grain: 0.1 } }],
    ['describe angle fraction', { geometry: { angle: 0.1 } }],
];

const names = filterNames();
writeJson('recipes.json', recipeInputs.map(([name, raw]) => {
    const input = json(raw === undefined ? null : raw);
    return {
        name,
        input,
        normalized: JSON.stringify(normalizeRecipe(input)),
        describe: describeRecipe(input, names),
        describeIds: describeRecipe(input),
        isIdentity: isIdentity(input),
    };
}));

// ---- geometry.json -----------------------------------------------------------

const geometries = [
    { rotate90: 0, angle: 0, crop: null },
    { rotate90: 1, angle: 0, crop: null },
    { rotate90: 2, angle: 7.5, crop: null },
    { rotate90: 3, angle: -12.25, crop: { cx: 0.4, cy: 0.6, w: 0.5, h: 0.45 } },
    { rotate90: 1, angle: 30, crop: { cx: 0.9, cy: 0.1, w: 0.8, h: 0.8 } },
    { rotate90: 0, angle: -45, crop: null },
    { rotate90: 0, angle: 3.33, aspect: '16:9', crop: { cx: 0.5, cy: 0.5, w: 1, h: 0.5625 } },
    { rotate90: 2, angle: 0, crop: { cx: 0.25, cy: 0.75, w: 0.5, h: 0.5 } },
    { rotate90: 3, angle: 44.99, crop: null },
    { rotate90: 0, angle: -1.5, crop: { cx: 0.01, cy: 0.99, w: 0.01, h: 0.01 } },
].map(g => normalizeRecipe({ geometry: g }).geometry);
const sizes = [[4000, 3000], [3000, 4000], [96, 64], [1001, 667]];
const rect = r => ({ cx: r.cx, cy: r.cy, w: r.w, h: r.h });

const maxRectAt = [];
for (const [W, H] of [[4000, 3000], [3000, 4000], [96, 64], [1, 1]]) {
    for (const angle of [0, 3.5, -12, 30, 45, -45, 89.9]) {
        for (const aspect of [4 / 3, 1, 9 / 16, 16 / 9, 0.01, 100]) {
            maxRectAt.push({ W, H, angle, aspect, ...maxRect(W, H, angle, aspect) });
        }
        for (const [cx, cy] of [[W * 0.1, H * 0.2], [W * 0.95, H * 0.9], [-5, H / 3], [W / 2, H + 1]]) {
            maxRectAt.push({ W, H, angle, aspect: 1.5, cx, cy, ...maxRect(W, H, angle, 1.5, cx, cy) });
        }
    }
}
function maxRect(...args) {
    const { w, h } = geo.maxRectAt(...args);
    return { w, h };
}

const constrainRect = [];
for (const [W, H] of [[4000, 3000], [96, 64]]) {
    const s = W / 4000;
    const rects = [
        { cx: 3900, cy: 1500, w: 1000, h: 750 },
        { cx: 2000, cy: 1500, w: 4000, h: 3000 },
        { cx: 100, cy: 100, w: 5000, h: 1000 },
        { cx: -300, cy: 3500, w: 800, h: 1200 },
        { cx: 2000, cy: 1500, w: 300, h: 300 },
        { cx: 3990, cy: 10, w: 3999, h: 2999 },
    ].map(r => ({ cx: r.cx * s, cy: r.cy * s, w: r.w * s, h: r.h * s }));
    for (const r of rects) {
        for (const angle of [0, 5, -17.5, 45]) constrainRect.push({ rect: r, W, H, angle, out: rect(geo.constrainRect(r, W, H, angle)) });
    }
}

const defaultRect = [];
for (const [W, H] of sizes) {
    for (const angle of [0, 2.25, -30, 45]) {
        for (const aspect of [null, 1, 16 / 9, 2 / 3]) defaultRect.push({ W, H, angle, aspect, out: rect(geo.defaultRect(W, H, angle, aspect)) });
    }
}

const effectiveRect = [];
const outputSize = [];
const outputMapping = [];
for (const geometry of geometries) {
    for (const [W0, H0] of sizes) {
        const e = geo.effectiveRect(geometry, W0, H0);
        effectiveRect.push({ geometry, W0, H0, W: e.W, H: e.H, rect: rect(e.rect) });
        for (const maxPixels of [Infinity, 1e6, 600, 1]) {
            outputSize.push({ geometry, W0, H0, maxPixels: Number.isFinite(maxPixels) ? maxPixels : null, ...geo.outputSize(geometry, W0, H0, maxPixels) });
        }
        const { width, height } = geo.outputSize(geometry, W0, H0, 2e5);
        const map = geo.outputMapping(geometry, W0, H0, width, height);
        const samples = [];
        for (const u of [0, 1, Math.floor(width / 3), width - 1]) {
            for (const v of [0, 1, Math.floor(height / 2), height - 1]) samples.push([u, v, ...map(u, v, [0, 0])]);
        }
        outputMapping.push({ geometry, W0, H0, outWidth: width, outHeight: height, samples });
    }
}
writeJson('geometry.json', { maxRectAt, constrainRect, defaultRect, effectiveRect, outputSize, outputMapping });

// ---- pipeline/ ------------------------------------------------------------------

mkdirSync(join(outDir, 'pipeline'), { recursive: true });

// Deterministic noise in -0.5..0.5 (an integer hash, no Math.random)
const noise = (x, y, k = 0) => {
    let h = Math.imul(x + 1, 73856093) ^ Math.imul(y + 1, 19349663) ^ Math.imul(k + 1, 83492791);
    h = Math.imul(h ^ (h >>> 15), 2246822519);
    h ^= h >>> 13;
    return (h >>> 0) / 4294967296 - 0.5;
};
const hsv = (h, s, v) => {
    const f = n => {
        const k = (n + h / 60) % 6;
        return v - v * s * Math.max(0, Math.min(k, 4 - k, 1));
    };
    return [f(5), f(3), f(1)];
};
const clamp01 = v => Math.min(1, Math.max(0, v));

// 72×48 test scene: sky gradient with a cloud (rows 0–11), grey ramp | hue sweep (12–23),
// colour patches incl. skin, sky, foliage (24–35), a "portrait" (skin disc on dark, sharp
// vertical edge, near-black/white columns) (36–45) and dyadic values that hit the
// rounding ties of toRGBA8/toRGB8 (46–47)
const SW = 72;
const SH = 48;
const source = createImage(SW, SH);
const patches = [[0.87, 0.67, 0.55], [0.6, 0.42, 0.33], [0.25, 0.45, 0.15], [0.42, 0.6, 0.25], [0.35, 0.55, 0.85], [0.85, 0.12, 0.1], [0.92, 0.85, 0.2], [0.75, 0.2, 0.7]];
for (let y = 0; y < SH; y++) {
    for (let x = 0; x < SW; x++) {
        let c;
        if (y < 12) {
            const t = y / 11;
            c = [0.3 + 0.4 * t, 0.5 + 0.32 * t, 0.85 + 0.1 * t];
            const cloud = Math.exp(-(((x - 46) / 8) ** 2 + ((y - 5) / 3) ** 2));
            c = c.map(v => v + (0.97 - v) * cloud + noise(x, y) * 0.02);
        } else if (y < 24) {
            if (x < 36) {
                const v = x / 35;
                c = [v, v, v];
            } else {
                c = hsv(((x - 36) / 36) * 360, 0.75, 0.85 - 0.3 * ((y - 12) / 11));
            }
        } else if (y < 36) {
            c = patches[Math.floor(x / 9)].map((v, i) => v + noise(x, y, i) * 0.06);
        } else if (y < 46) {
            const face = Math.hypot(x - 22, y - 41) < 5;
            c = face ? [0.82, 0.62, 0.5] : x < 48 ? [0.15, 0.13, 0.12] : [0.85, 0.86, 0.88];
            if (x >= 66) c = x % 2 ? [0.02, 0.02, 0.02] : [0.98, 0.98, 0.98];
            c = c.map((v, i) => v + noise(x, y, i + 3) * 0.05);
        } else {
            const v = (x % 33) / 32;
            c = [v, (v + 0.5) % 1, 1 - v];
        }
        source.data.set(c.map(clamp01), (y * SW + x) * 3);
    }
}
source.data.set([0, 0, 0], 0);
source.data.set([1, 1, 1], (SW - 1) * 3);
writeF32('pipeline/source.bin', source.data);

// Masks at half resolution (36×24) in the upright source orientation
const MW = 36;
const MH = 24;
const sky = new Float32Array(MW * MH);
const subject = new Float32Array(MW * MH);
const depth = new Float32Array(MW * MH);
for (let y = 0; y < MH; y++) {
    for (let x = 0; x < MW; x++) {
        const p = y * MW + x;
        sky[p] = clamp01((6.5 - y) / 2);
        subject[p] = clamp01((3.5 - Math.hypot(x - 11, y - 20.5)) / 1.5);
        depth[p] = clamp01(y / (MH - 1) * 0.8 + subject[p] * 0.2 + noise(x, y, 9) * 0.02);
    }
}
writeF32('pipeline/mask-sky.bin', sky);
writeF32('pipeline/mask-subject.bin', subject);
writeF32('pipeline/mask-depth.bin', depth);
const faces = [{ x: 16 / 72, y: 35 / 48, w: 12 / 72, h: 12 / 48, score: 0.93 }, { x: 0.8, y: 0.05, w: 0.12, h: 0.15 }];
const masks = { width: MW, height: MH, sky, subject, depth, faces };

const adv = a => ({ advanced: a });
const pipelineCases = [
    ['identity', {}, { rgb8: true }],
    ['tone up', { adjust: { brightness: 0.4, contrast: 0.5, whitePoint: 0.3, blackPoint: -0.3, warmth: 0.5, tint: -0.4 } }, { rgb8: true }],
    ['tone down', { adjust: { brightness: -0.5, contrast: -0.6, whitePoint: -0.4, blackPoint: 0.4, warmth: -0.6, tint: 0.5, shadows: -0.6, highlights: 0.6, hdr: 0.3 } }],
    ['local tone', { adjust: { shadows: 0.8, highlights: -0.7, hdr: 0.9 } }],
    ['pop and vignette', { adjust: { pop: 0.9, vignette: 0.7, brightness: 0.1, saturation: -0.5, skinTone: 0.7, blueTone: -0.6 } }],
    ['colour', { adjust: { saturation: 0.6, skinTone: -0.8, blueTone: 0.9 } }],
    ['filter golden', { filter: { id: 'golden', strength: 0.7 } }],
    ['filter mono contrast', { filter: { id: 'mono-contrast', strength: 1 } }],
    ['filter learned sepia', { filter: { id: 'learned-sepia', strength: 0.8 }, adjust: { warmth: 0.1 } }],
    ['filter neon', { filter: { id: 'neon', strength: 1 } }],
    ['geometry', { geometry: { rotate90: 1, angle: 7.5, aspect: '4:3', crop: { cx: 0.45, cy: 0.55, w: 0.7, h: 0.6 } }, adjust: { contrast: 0.2 } }],
    ['geometry straighten', { geometry: { rotate90: 3, angle: -12, crop: null } }, { maxPixels: 1500 }],
    ['tiny crop', { geometry: { crop: { cx: 0.3, cy: 0.4, w: 0.06, h: 0.08 } }, adjust: { shadows: 0.5, pop: 0.5 }, tools: { blur: { strength: 1, focus: { x: 0, y: 0 } } }, advanced: { clarity: 0.5, noise: 0.5 } }, { masks: true }],
    ['geometry halved preview', { geometry: { rotate90: 2, angle: 3, crop: { cx: 0.5, cy: 0.5, w: 0.9, h: 0.8 } }, adjust: { brightness: 0.2 } }, { maxPixels: 300, sourceWidth: 144, sourceHeight: 96 }],
    ['advanced exposure clarity dehaze levels curves', adv({ exposure: 0.8, clarity: 0.7, dehaze: 0.6, levels: { inBlack: 0.05, inWhite: 0.9, gamma: 1.3, outBlack: 0.03, outWhite: 0.97 }, curves: { rgb: [[0.25, 0.18], [0.75, 0.85]], r: [[0, 0.05], [0.5, 0.56]], g: [[0.4, 0.35], [1, 0.95]], b: [[0.3, 0.4], [0.6, 0.6], [0.9, 0.8]] } })],
    ['advanced negative clarity dehaze hsl grading', adv({ exposure: -1.2, clarity: -0.5, dehaze: -0.7, hsl: { red: { h: 0.3, s: 0.5, l: -0.2 }, orange: { s: -0.4, l: 0.3 }, yellow: { h: -0.5 }, green: { h: 0.4, s: 0.6 }, aqua: { l: -0.5 }, blue: { h: -0.3, s: 0.8, l: -0.3 }, purple: { s: -1 }, magenta: { h: 1, l: 0.4 } }, grading: { shadows: { hue: 200, sat: 0.6 }, midtones: { hue: 90, sat: 0.3 }, highlights: { hue: 35, sat: 0.8 }, balance: 0.3, blending: 0.7 } })],
    ['advanced finish', adv({ sharpen: { amount: 0.8, radius: 2 }, noise: 0.7, grain: 0.6, vignette: { amount: 0.8, midpoint: 0.3, roundness: 0.5, feather: 0.4 } })],
    ['advanced finish inverse vignette', adv({ sharpen: { amount: 0.4, radius: 0.5 }, grain: 1, vignette: { amount: -0.6, midpoint: 0.7, roundness: -0.8, feather: 0.1 } }), { rgb8: true }],
    ['tool sky vivid', { tools: { sky: { palette: 'vivid', strength: 0.8 } } }, { masks: true }],
    ['tool sky ember', { tools: { sky: { palette: 'ember', strength: 1 } } }, { masks: true }],
    ['tool color focus', { tools: { colorFocus: { strength: 0.9 } } }, { masks: true }],
    ['tool portrait light', { tools: { portraitLight: { x: 0.2, y: 0.7, strength: 0.8 } } }, { masks: true }],
    ['tool blur', { tools: { blur: { strength: 1, focus: { x: 0.3, y: 0.85 } } } }, { masks: true }],
    ['tools with geometry', { geometry: { rotate90: 1, angle: 5, crop: { cx: 0.5, cy: 0.6, w: 0.8, h: 0.75 } }, tools: { sky: { palette: 'radiant', strength: 0.7 }, colorFocus: { strength: 0.4 }, portraitLight: { x: 0.6, y: 0.2, strength: 1 }, blur: { strength: 0.6, focus: { x: 0.4, y: 0.4 } } } }, { masks: true }],
    ['kitchen sink', { geometry: { rotate90: 2, angle: -4 }, adjust: { hdr: 0.4, brightness: 0.15, contrast: 0.3, whitePoint: 0.1, highlights: -0.3, shadows: 0.4, blackPoint: 0.1, saturation: 0.3, warmth: 0.2, tint: -0.1, skinTone: 0.3, blueTone: 0.3, pop: 0.4, vignette: 0.3 }, filter: { id: 'teal', strength: 0.5 }, tools: { sky: { palette: 'airy', strength: 0.5 }, portraitLight: { strength: 0.5 } }, advanced: { exposure: 0.2, clarity: 0.3, dehaze: 0.2, curves: { rgb: [[0.5, 0.55]] }, hsl: { blue: { s: 0.3 } }, grading: { highlights: { hue: 50, sat: 0.4 } }, sharpen: { amount: 0.3 }, noise: 0.2, grain: 0.2, vignette: { amount: 0.3 } } }, { masks: true, rgb8: true }],
];

const slug = name => name.replace(/[^a-z0-9]+/gi, '-').toLowerCase();
const cases = pipelineCases.map(([name, input, options = {}]) => {
    const recipe = normalizeRecipe(json(input));
    const maxPixels = options.maxPixels ?? Infinity;
    const sourceSize = options.sourceWidth ? { width: options.sourceWidth, height: options.sourceHeight } : null;
    const out = render(source, recipe, { maxPixels, sourceSize, masks: options.masks ? masks : null, tools: options.masks ? applyTools : null });
    const file = `${slug(name)}.bin`;
    writeF32(`pipeline/${file}`, out.data);
    const entry = {
        name, recipe, masks: !!options.masks,
        maxPixels: Number.isFinite(maxPixels) ? maxPixels : null,
        sourceWidth: sourceSize?.width ?? null, sourceHeight: sourceSize?.height ?? null,
        width: out.width, height: out.height, file,
    };
    if (options.masks) {
        const moved = transformMasks(masks, recipe.geometry, sourceSize?.width ?? SW, sourceSize?.height ?? SH, out.width, out.height);
        entry.faces = moved.faces ?? [];
    }
    if (options.rgb8) {
        entry.rgba8 = `${slug(name)}.rgba8`;
        entry.rgb8 = `${slug(name)}.rgb8`;
        writeFileSync(join(outDir, 'pipeline', entry.rgba8), toRGBA8(out));
        writeFileSync(join(outDir, 'pipeline', entry.rgb8), toRGB8(out));
    }
    return entry;
});
writeJson('pipeline/cases.json', {
    version: 1,
    source: { file: 'source.bin', width: SW, height: SH },
    masks: { width: MW, height: MH, sky: 'mask-sky.bin', subject: 'mask-subject.bin', depth: 'mask-depth.bin', faces },
    cases,
});
console.log(`wrote ${recipeInputs.length} recipes, geometry cases and ${cases.length} pipeline cases to ${outDir}`);
