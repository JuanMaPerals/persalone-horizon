#!/usr/bin/env node
// Official Halo STL -> validated, normalised, optimised GLB for the Studio twin.
//
// Runs as its own Node process (never in the browser): 3D assets are
// untrusted input, so parsing and conversion happen here, bounded, and the
// browser only loads the resulting GLB after checking its hash and structure.
//
//   node tools/twin/build-halo-asset.mjs --stl <halo.stl> --out public/twin
//
// Pipeline: official STL -> sanitize/validate -> normalise coordinates ->
// GLB -> weld + normals + measured simplification -> meshopt compression ->
// sha256 -> asset manifest (provenance, licence, metrics).
import { createHash } from 'node:crypto';
import { mkdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { basename, extname, join } from 'node:path';
import { Document, NodeIO } from '@gltf-transform/core';
import { EXTMeshoptCompression, KHRMeshQuantization } from '@gltf-transform/extensions';
import { meshopt, simplify, weld } from '@gltf-transform/functions';
import { MeshoptEncoder, MeshoptSimplifier } from 'meshoptimizer';

// Official source, pinned. A different file is refused unless explicitly
// allowed for experiments (and then marked as not official).
export const OFFICIAL = {
  repo: 'https://github.com/brilliantlabsAR/docs',
  commit: '808d31790030f9b939474f949601ca63106978ab',
  path: 'halo/halo.stl',
  sha256: 'cb5aef98a7b37e4b97eb4a95e6b5d8837ab287e33a97fd97569d0f19420b78f4',
  license: 'ISC',
  copyright: 'Copyright (c) 2024 Brilliant Labs Ltd.',
  description: 'Full Halo assembly: front, both lenses, both temple arms open (halo/hardware.md, Mechanical).',
};

export const LIMITS = {
  maxInputBytes: 32 * 1024 * 1024,
  maxTriangles: 500_000,
  maxAbsCoordinateMm: 10_000,
  allowedExtensions: ['.stl'],
};

// Simplification is accepted only while the geometric error stays below this
// fraction of the model's size (meshoptimizer relative error).
const SIMPLIFY = { ratio: 0.5, error: 0.0005 };

function fail(code, detail) {
  const error = new Error(`${code}: ${detail}`);
  error.code = code;
  throw error;
}

/** Strict binary-STL parser with limits. ASCII STL is refused. */
export function parseBinaryStl(bytes) {
  if (bytes.length < 84) fail('stlTooShort', `${bytes.length} bytes`);
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const count = view.getUint32(80, true);
  if (count === 0) fail('stlEmpty', 'no triangles');
  if (count > LIMITS.maxTriangles) fail('stlTooManyTriangles', `${count}`);
  if (84 + 50 * count !== bytes.length) fail('stlNotBinary', 'size does not match the triangle count (ASCII STL is not accepted)');
  const positions = new Float32Array(count * 9);
  for (let i = 0; i < count; i++) {
    const base = 84 + 50 * i + 12; // skip the facet normal: recomputed later
    for (let k = 0; k < 9; k++) {
      const value = view.getFloat32(base + 4 * k, true);
      if (!Number.isFinite(value) || Math.abs(value) > LIMITS.maxAbsCoordinateMm) {
        fail('stlBadCoordinate', `triangle ${i}`);
      }
      positions[i * 9 + k] = value;
    }
  }
  return { count, positions };
}

export function boundingBox(positions) {
  const min = [Infinity, Infinity, Infinity];
  const max = [-Infinity, -Infinity, -Infinity];
  for (let i = 0; i < positions.length; i += 3) {
    for (let k = 0; k < 3; k++) {
      const v = positions[i + k];
      if (v < min[k]) min[k] = v;
      if (v > max[k]) max[k] = v;
    }
  }
  return { min, max };
}

/**
 * The official STL is in millimetres with X = width, Y = up, Z = depth and
 * the front at +Z, which already matches glTF's Y-up convention. Normalising
 * only recentres on the bounding-box centre and converts to metres.
 */
export function normalise(positions, box) {
  const centre = box.min.map((v, k) => (v + box.max[k]) / 2);
  const out = new Float32Array(positions.length);
  for (let i = 0; i < positions.length; i += 3) {
    for (let k = 0; k < 3; k++) out[i + k] = (positions[i + k] - centre[k]) * 0.001;
  }
  return { positions: out, transform: { centreMm: centre.map((v) => +v.toFixed(4)), scale: 0.001, axes: 'X right(width) Y up Z front', units: 'm' } };
}

function countTriangles(document) {
  let triangles = 0;
  for (const mesh of document.getRoot().listMeshes()) {
    for (const prim of mesh.listPrimitives()) {
      const indices = prim.getIndices();
      triangles += (indices ? indices.getCount() : prim.getAttribute('POSITION').getCount()) / 3;
    }
  }
  return triangles;
}

export async function buildHaloAsset({ stlPath, outDir, allowUnofficial = false }) {
  if (!LIMITS.allowedExtensions.includes(extname(stlPath).toLowerCase())) fail('extensionNotAllowed', extname(stlPath));
  const size = statSync(stlPath).size;
  if (size > LIMITS.maxInputBytes) fail('inputTooLarge', `${size}`);
  const bytes = readFileSync(stlPath);
  const inputSha = createHash('sha256').update(bytes).digest('hex');
  const official = inputSha === OFFICIAL.sha256;
  if (!official && !allowUnofficial) fail('notOfficialAsset', inputSha);

  const started = performance.now();
  const stl = parseBinaryStl(bytes);
  const box = boundingBox(stl.positions);
  const { positions, transform } = normalise(stl.positions, box);

  const document = new Document();
  const buffer = document.createBuffer();
  const position = document.createAccessor('POSITION').setType('VEC3').setArray(positions).setBuffer(buffer);
  const material = document.createMaterial('halo-shell').setBaseColorFactor([0.09, 0.1, 0.13, 1]).setRoughnessFactor(0.55).setMetallicFactor(0.1);
  const primitive = document.createPrimitive().setAttribute('POSITION', position).setMaterial(material);
  const mesh = document.createMesh('halo-shell').addPrimitive(primitive);
  const node = document.createNode('halo-shell').setMesh(mesh);
  document.createScene('halo').addChild(node);
  document.getRoot().getAsset().generator = 'persalone-horizon twin pipeline v1';

  await MeshoptEncoder.ready;
  await MeshoptSimplifier.ready;
  await document.transform(weld());
  const weldedTriangles = countTriangles(document);
  await document.transform(simplify({ simplifier: MeshoptSimplifier, ratio: SIMPLIFY.ratio, error: SIMPLIFY.error }));
  // Smooth, area-weighted normals computed on the indexed mesh (the library's
  // normals() unwelds primitives, which defeats vertex reuse and meshopt).
  for (const mesh of document.getRoot().listMeshes()) {
    for (const prim of mesh.listPrimitives()) {
      const pos = prim.getAttribute('POSITION').getArray();
      const idx = prim.getIndices().getArray();
      const nrm = new Float32Array(pos.length);
      for (let t = 0; t < idx.length; t += 3) {
        const [a, b, c] = [idx[t] * 3, idx[t + 1] * 3, idx[t + 2] * 3];
        const e1 = [pos[b] - pos[a], pos[b + 1] - pos[a + 1], pos[b + 2] - pos[a + 2]];
        const e2 = [pos[c] - pos[a], pos[c + 1] - pos[a + 1], pos[c + 2] - pos[a + 2]];
        const n = [e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2], e1[0] * e2[1] - e1[1] * e2[0]];
        for (const v of [a, b, c]) for (let k = 0; k < 3; k++) nrm[v + k] += n[k];
      }
      for (let v = 0; v < nrm.length; v += 3) {
        const l = Math.hypot(nrm[v], nrm[v + 1], nrm[v + 2]) || 1;
        nrm[v] /= l; nrm[v + 1] /= l; nrm[v + 2] /= l;
      }
      prim.setAttribute('NORMAL', document.createAccessor('NORMAL').setType('VEC3').setArray(nrm).setBuffer(document.getRoot().listBuffers()[0]));
    }
  }
  const simplifiedTriangles = countTriangles(document);
  document.createExtension(KHRMeshQuantization).setRequired(true);
  await document.transform(meshopt({ encoder: MeshoptEncoder, level: 'medium' }));

  const io = new NodeIO().registerExtensions([EXTMeshoptCompression, KHRMeshQuantization]).registerDependencies({ 'meshopt.encoder': MeshoptEncoder });
  const glb = await io.writeBinary(document);
  const glbSha = createHash('sha256').update(glb).digest('hex');
  mkdirSync(outDir, { recursive: true });
  writeFileSync(join(outDir, 'halo.glb'), glb);

  const manifest = {
    schema: 'horizon.twin-asset.v1',
    asset: 'halo.glb',
    sha256: glbSha,
    bytes: glb.length,
    provenance: official ? 'OFFICIAL_GEOMETRY' : 'UNOFFICIAL_INPUT',
    source: { ...OFFICIAL, file: basename(stlPath), sha256: inputSha, bytes: size, official },
    geometry: {
      inputTriangles: stl.count,
      weldedTriangles,
      triangles: simplifiedTriangles,
      simplification: { ...SIMPLIFY, note: 'meshoptimizer relative error bound' },
      boundingBoxMm: { min: box.min.map((v) => +v.toFixed(3)), max: box.max.map((v) => +v.toFixed(3)) },
      transform,
    },
    encoding: { container: 'GLB', extensionsRequired: ['EXT_meshopt_compression', 'KHR_mesh_quantization'], textures: 0, externalUris: 0 },
    pipeline: {
      steps: ['sanitize/validate binary STL', 'normalise (recentre, mm->m)', 'build glTF', 'weld', 'simplify (meshopt, bounded error)', 'smooth normals (indexed)', 'quantize + EXT_meshopt_compression', 'sha256'],
      tools: { '@gltf-transform/core': '4.5.0', meshoptimizer: '1.3.0' },
      buildMs: Math.round(performance.now() - started),
    },
    limits: LIMITS,
  };
  writeFileSync(join(outDir, 'halo.asset.json'), `${JSON.stringify(manifest, null, 2)}\n`);
  return manifest;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const args = Object.fromEntries(process.argv.slice(2).reduce((acc, a, i, all) => (a.startsWith('--') ? [...acc, [a.slice(2), all[i + 1]?.startsWith('--') || all[i + 1] === undefined ? 'true' : all[i + 1]]] : acc), []));
  if (!args.stl || !args.out) {
    console.error('usage: build-halo-asset.mjs --stl <file.stl> --out <dir> [--allow-unofficial]');
    process.exit(64);
  }
  buildHaloAsset({ stlPath: args.stl, outDir: args.out, allowUnofficial: args['allow-unofficial'] === 'true' })
    .then((m) => {
      console.log(JSON.stringify({ sha256: m.sha256, bytes: m.bytes, triangles: m.geometry.triangles, inputTriangles: m.geometry.inputTriangles, buildMs: m.pipeline.buildMs }));
    })
    .catch((e) => {
      console.error(`TWIN_ASSET_REJECTED ${e.code ?? 'error'} ${e.message}`);
      process.exit(1);
    });
}
