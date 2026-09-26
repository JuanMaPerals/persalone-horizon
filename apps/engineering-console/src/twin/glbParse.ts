// Parses an already validated GLB (see assetLoader.ts) into a three.js scene.
// Loaded lazily with the 3D chunk. Only embedded buffers and the allow-listed
// meshopt/quantization extensions reach this point.
import type { Object3D } from 'three';
import { GLTFLoader } from 'three/examples/jsm/loaders/GLTFLoader.js';
import { MeshoptDecoder } from 'three/examples/jsm/libs/meshopt_decoder.module.js';

export async function parseShell(buffer: ArrayBuffer): Promise<Object3D> {
  const loader = new GLTFLoader();
  loader.setMeshoptDecoder(MeshoptDecoder);
  const gltf = await loader.parseAsync(buffer, '');
  return gltf.scene;
}
