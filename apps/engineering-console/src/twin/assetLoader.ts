// Validated loading of the twin model. 3D assets are untrusted input: the
// browser only accepts the pipeline's GLB after checking the manifest schema,
// size, SHA-256 and GLB structure (no external URIs, no images/textures, only
// allow-listed extensions). Nothing is fetched from a URL found inside a model.

export const ASSET_SCHEMA = 'horizon.twin-asset.v1';
export const MAX_GLB_BYTES = 8 * 1024 * 1024;
export const ALLOWED_EXTENSIONS: readonly string[] = ['EXT_meshopt_compression', 'KHR_mesh_quantization'];

export interface TwinAssetManifest {
  readonly schema: typeof ASSET_SCHEMA;
  readonly asset: 'halo.glb';
  readonly sha256: string;
  readonly bytes: number;
  readonly provenance: 'OFFICIAL_GEOMETRY';
  readonly source: { readonly repo: string; readonly commit: string; readonly path: string; readonly sha256: string; readonly license: string; readonly copyright: string };
  readonly geometry: { readonly triangles: number; readonly inputTriangles: number; readonly transform: { readonly centreMm: readonly [number, number, number]; readonly scale: number } };
}

export class TwinAssetError extends Error {
  constructor(readonly code: 'assetMissing' | 'assetSchemaUnsupported' | 'assetTooLarge' | 'assetHashMismatch' | 'assetMalformed' | 'assetExternalUri' | 'assetExtensionNotAllowed' | 'assetHasImages') {
    super(code);
  }
}

const hex64 = /^[0-9a-f]{64}$/;

export function parseManifest(raw: unknown): TwinAssetManifest {
  if (typeof raw !== 'object' || raw === null) throw new TwinAssetError('assetSchemaUnsupported');
  const m = raw as Record<string, unknown>;
  if (m.schema !== ASSET_SCHEMA || m.asset !== 'halo.glb' || m.provenance !== 'OFFICIAL_GEOMETRY') throw new TwinAssetError('assetSchemaUnsupported');
  if (typeof m.sha256 !== 'string' || !hex64.test(m.sha256)) throw new TwinAssetError('assetSchemaUnsupported');
  if (typeof m.bytes !== 'number' || !Number.isSafeInteger(m.bytes) || m.bytes <= 0) throw new TwinAssetError('assetSchemaUnsupported');
  if (m.bytes > MAX_GLB_BYTES) throw new TwinAssetError('assetTooLarge');
  const g = m.geometry as Record<string, unknown> | undefined;
  const t = g?.transform as Record<string, unknown> | undefined;
  const centre = t?.centreMm;
  if (!Array.isArray(centre) || centre.length !== 3 || !centre.every((v) => typeof v === 'number' && Number.isFinite(v)) || typeof t?.scale !== 'number') {
    throw new TwinAssetError('assetSchemaUnsupported');
  }
  return raw as TwinAssetManifest;
}

/** Structural GLB validation (glTF 2.0 binary container). */
export function validateGlb(buffer: ArrayBuffer): Record<string, unknown> {
  if (buffer.byteLength > MAX_GLB_BYTES) throw new TwinAssetError('assetTooLarge');
  if (buffer.byteLength < 20) throw new TwinAssetError('assetMalformed');
  const view = new DataView(buffer);
  if (view.getUint32(0, true) !== 0x46546c67) throw new TwinAssetError('assetMalformed'); // 'glTF'
  if (view.getUint32(4, true) !== 2) throw new TwinAssetError('assetMalformed');
  if (view.getUint32(8, true) !== buffer.byteLength) throw new TwinAssetError('assetMalformed');
  const jsonLength = view.getUint32(12, true);
  if (view.getUint32(16, true) !== 0x4e4f534a || 20 + jsonLength > buffer.byteLength) throw new TwinAssetError('assetMalformed'); // 'JSON'
  let json: Record<string, unknown>;
  try {
    json = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(new Uint8Array(buffer, 20, jsonLength))) as Record<string, unknown>;
  } catch {
    throw new TwinAssetError('assetMalformed');
  }
  const asset = json.asset as Record<string, unknown> | undefined;
  if (asset?.version !== '2.0') throw new TwinAssetError('assetMalformed');
  for (const key of ['buffers', 'images']) {
    for (const item of (json[key] as Record<string, unknown>[] | undefined) ?? []) {
      if ('uri' in item) throw new TwinAssetError('assetExternalUri');
    }
  }
  if (((json.images as unknown[] | undefined) ?? []).length > 0 || ((json.textures as unknown[] | undefined) ?? []).length > 0) {
    throw new TwinAssetError('assetHasImages');
  }
  for (const key of ['extensionsUsed', 'extensionsRequired']) {
    for (const ext of (json[key] as unknown[] | undefined) ?? []) {
      if (typeof ext !== 'string' || !ALLOWED_EXTENSIONS.includes(ext)) throw new TwinAssetError('assetExtensionNotAllowed');
    }
  }
  return json;
}

export async function sha256Hex(buffer: ArrayBuffer): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', buffer);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

export interface FetchedAsset {
  readonly manifest: TwinAssetManifest;
  readonly buffer: ArrayBuffer;
  readonly fetchMs: number;
}

/** Fetches manifest + GLB from the same origin and validates both. */
export async function fetchTwinAsset(baseUrl: string, fetchImpl: typeof fetch = fetch.bind(globalThis)): Promise<FetchedAsset> {
  const started = performance.now();
  const manifestResponse = await fetchImpl(`${baseUrl}twin/halo.asset.json`, { cache: 'no-store' }).catch(() => null);
  if (!manifestResponse?.ok) throw new TwinAssetError('assetMissing');
  let manifestJson: unknown;
  try {
    manifestJson = await manifestResponse.json();
  } catch {
    throw new TwinAssetError('assetSchemaUnsupported');
  }
  const manifest = parseManifest(manifestJson);
  const glbResponse = await fetchImpl(`${baseUrl}twin/${manifest.asset}`, { cache: 'no-store' }).catch(() => null);
  if (!glbResponse?.ok) throw new TwinAssetError('assetMissing');
  const declared = Number(glbResponse.headers.get('content-length') ?? '0');
  if (declared > MAX_GLB_BYTES) throw new TwinAssetError('assetTooLarge');
  const buffer = await glbResponse.arrayBuffer();
  if (buffer.byteLength > MAX_GLB_BYTES) throw new TwinAssetError('assetTooLarge');
  if ((await sha256Hex(buffer)) !== manifest.sha256) throw new TwinAssetError('assetHashMismatch');
  validateGlb(buffer);
  return { manifest, buffer, fetchMs: performance.now() - started };
}

/** STL millimetre point -> twin scene metres, using the manifest transform. */
export function toScene(manifest: TwinAssetManifest, mm: readonly [number, number, number]): [number, number, number] {
  const { centreMm, scale } = manifest.geometry.transform;
  return [(mm[0] - centreMm[0]) * scale, (mm[1] - centreMm[1]) * scale, (mm[2] - centreMm[2]) * scale];
}
