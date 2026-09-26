import { Html, Line, OrbitControls } from '@react-three/drei';
import { Canvas, type ThreeEvent, useFrame, useThree } from '@react-three/fiber';
import { type ReactElement, useCallback, useEffect, useMemo, useRef, useState } from 'react';
import * as THREE from 'three';
import { acceleratedRaycast, computeBoundsTree, disposeBoundsTree } from 'three-mesh-bvh';
import { toScene, type TwinAssetManifest } from './assetLoader';
import { TWIN_COMPONENTS, type ComponentId, type TwinComponent } from './components';
import type { SegmentId, TwinEnvironment, TwinState } from './twinStateMapper';

// BVH-accelerated raycasting for picking on the ~100k-triangle official shell.
THREE.BufferGeometry.prototype.computeBoundsTree = computeBoundsTree as unknown as typeof THREE.BufferGeometry.prototype.computeBoundsTree;
THREE.BufferGeometry.prototype.disposeBoundsTree = disposeBoundsTree;
THREE.Mesh.prototype.raycast = acceleratedRaycast;

export type TwinMode = 'ASSEMBLED' | 'EXPLODED' | 'X_RAY' | 'SIGNAL_FLOW' | 'LIVE_FRAMEBUFFER' | 'COMPONENT_STATE';
export const TWIN_MODES: readonly TwinMode[] = ['ASSEMBLED', 'EXPLODED', 'X_RAY', 'SIGNAL_FLOW', 'LIVE_FRAMEBUFFER', 'COMPONENT_STATE'];

export interface PerfResult {
  readonly frames: number;
  readonly frameMsP50: number;
  readonly frameMsP95: number;
  readonly fpsP50: number;
  readonly fpsP95: number;
  readonly drawCalls: number;
  readonly triangles: number;
  readonly renderer: string;
}

export interface HaloTwinSceneProps {
  readonly manifest: TwinAssetManifest;
  readonly shell: THREE.Object3D;
  readonly twin: TwinState;
  readonly mode: TwinMode;
  readonly selected: ComponentId | null;
  readonly onSelect: (id: ComponentId) => void;
  /** Object URL of the current live framebuffer, or null (display UNKNOWN). */
  readonly frameUrl: string | null;
  readonly reducedMotion: boolean;
  readonly perfRequest: number;
  readonly onPerf: (result: PerfResult) => void;
  readonly labels: Readonly<Record<string, string>>;
}

const MM = 0.001;
const EXPLODE_M = 0.035;
const envColour: Record<TwinEnvironment, string> = {
  SIMULATED: '#8f9cb0', EMULATED: '#f4b860', PC_REAL: '#4fb3ff', HALO_REAL: '#7fd6a0', UNKNOWN: '#3a4250', BLOCKED: '#d9534f',
};
const provColour: Record<string, string> = {
  OFFICIAL_LOCATION: '#7fd6a0', DOCUMENTED_PROXY: '#6aa0ff', INFERRED_PROXY: '#c77dff', UNKNOWN: '#6b7280',
};

function proxyGeometry(c: TwinComponent): THREE.BufferGeometry {
  const s = c.shape!;
  if (s.kind === 'box') return new THREE.BoxGeometry(s.sizeMm[0] * MM, s.sizeMm[1] * MM, s.sizeMm[2] * MM);
  if (s.kind === 'sphere') return new THREE.SphereGeometry(s.radiusMm * MM, 20, 14);
  const g = new THREE.CylinderGeometry(s.radiusMm * MM, s.radiusMm * MM, s.lengthMm * MM, 28);
  if (s.axis === 'x') g.rotateZ(Math.PI / 2);
  if (s.axis === 'z') g.rotateX(Math.PI / 2);
  return g;
}

/** Eases a 0..1 value towards a target; instant under reduced motion. */
function useEased(target: number, reducedMotion: boolean): React.MutableRefObject<number> {
  const value = useRef(target);
  const { invalidate } = useThree();
  useEffect(() => {
    if (reducedMotion) {
      value.current = target;
      invalidate();
    } else {
      invalidate();
    }
  }, [target, reducedMotion, invalidate]);
  useFrame((_, dt) => {
    if (value.current === target) return;
    const step = Math.min(1, dt * 6);
    value.current = Math.abs(target - value.current) < 0.002 ? target : value.current + (target - value.current) * step;
    invalidate();
  });
  return value;
}

function Shell({ shell, mode }: { readonly shell: THREE.Object3D; readonly mode: TwinMode }): ReactElement {
  const material = useMemo(() => new THREE.MeshStandardMaterial({ color: '#1b2233', roughness: 0.55, metalness: 0.1 }), []);
  useEffect(() => {
    shell.traverse((o) => {
      if ((o as THREE.Mesh).isMesh) {
        const mesh = o as THREE.Mesh;
        mesh.material = material;
        mesh.geometry.computeBoundsTree?.();
        mesh.userData.componentId = 'shell';
      }
    });
  }, [shell, material]);
  const see = mode === 'X_RAY' || mode === 'SIGNAL_FLOW' ? 0.22 : mode === 'EXPLODED' || mode === 'LIVE_FRAMEBUFFER' ? 0.35 : 1;
  // Lighter shell when see-through, so the official outline stays readable.
  material.color.set(see < 0.3 ? '#6b7fa6' : '#1b2233');
  material.transparent = see < 1;
  material.opacity = see;
  material.depthWrite = see === 1;
  material.needsUpdate = true;
  return <primitive object={shell} />;
}

function Proxy({ c, manifest, mode, explode, twin, selected, onSelect, frameTexture, label }: {
  readonly c: TwinComponent;
  readonly manifest: TwinAssetManifest;
  readonly mode: TwinMode;
  readonly explode: React.MutableRefObject<number>;
  readonly twin: TwinState;
  readonly selected: boolean;
  readonly onSelect: (id: ComponentId) => void;
  readonly frameTexture: THREE.Texture | null;
  readonly label: string;
}): ReactElement {
  const group = useRef<THREE.Group>(null);
  const geometry = useMemo(() => proxyGeometry(c), [c]);
  const base = useMemo(() => new THREE.Vector3(...toScene(manifest, c.positionMm!)), [manifest, c]);
  const dir = useMemo(() => new THREE.Vector3(...c.explode).normalize(), [c]);
  const state = twin.components[c.id];
  const colour = mode === 'COMPONENT_STATE' ? envColour[state.environment] : provColour[c.provenance];
  useFrame(() => {
    if (group.current) group.current.position.copy(base).addScaledVector(dir, EXPLODE_M * explode.current);
  });
  const click = (e: ThreeEvent<MouseEvent>) => {
    e.stopPropagation();
    onSelect(c.id);
  };
  return <group ref={group} position={base}>
    <mesh geometry={geometry} onClick={click} userData={{ componentId: c.id }} name={`twin-${c.id}`}>
      <meshStandardMaterial color={colour} emissive={selected ? '#ffffff' : '#000000'} emissiveIntensity={selected ? 0.45 : 0}
        transparent={c.provenance === 'INFERRED_PROXY'} opacity={c.provenance === 'INFERRED_PROXY' ? 0.6 : 1} />
    </mesh>
    {c.id === 'display' ? <mesh position={[0, 0, -3.2 * MM]} rotation={[0, Math.PI, 0]}>
      <circleGeometry args={[3.8 * MM, 48]} />
      {/* key: a new material (and shader) when the live texture appears/disappears */}
      {frameTexture
        ? <meshBasicMaterial key={frameTexture.uuid} map={frameTexture} color="#ffffff" toneMapped={false} />
        : <meshBasicMaterial key="unknown" color="#0b0f16" />}
    </mesh> : null}
    {selected && mode === 'EXPLODED' ? <Html center distanceFactor={0.25} className="twin-3d-label">{label}</Html> : null}
  </group>;
}

/**
 * Illustrative virtual-image plane between the wearer's eye and the
 * display-side lens, facing the wearer (INFERRED placement: the optics are not
 * modelled). It carries the same live framebuffer texture as the display.
 */
function VirtualImage({ manifest, frameTexture }: { readonly manifest: TwinAssetManifest; readonly frameTexture: THREE.Texture | null }): ReactElement {
  const p = toScene(manifest, [40, 25, 142]);
  return <mesh position={p} rotation={[0, Math.PI, 0]} name="twin-virtual-image">
    <planeGeometry args={[0.03, 0.03]} />
    {frameTexture
      ? <meshBasicMaterial key={frameTexture.uuid} map={frameTexture} color="#ffffff" side={THREE.DoubleSide} toneMapped={false} />
      : <meshBasicMaterial key="unknown" color="#0b0f16" side={THREE.DoubleSide} transparent opacity={0.6} />}
  </mesh>;
}

const hostX = 0.11;
const nodePositions = (manifest: TwinAssetManifest): Record<string, THREE.Vector3> => ({
  MIC: new THREE.Vector3(...toScene(manifest, [72, 42, 142])),
  STT: new THREE.Vector3(hostX, 0.035, 0.03),
  TRANSLATION: new THREE.Vector3(hostX, 0.0, 0.03),
  CAPTION: new THREE.Vector3(hostX, -0.035, 0.05),
  TTS: new THREE.Vector3(hostX, -0.035, 0.0),
  DISPLAY: new THREE.Vector3(...toScene(manifest, [40, 43, 151])),
  SPEAKER: new THREE.Vector3(...toScene(manifest, [72, 40, 66])),
});
const segmentEnds: Record<SegmentId, readonly [string, string]> = {
  MIC_STT: ['MIC', 'STT'], STT_TRANSLATION: ['STT', 'TRANSLATION'], TRANSLATION_CAPTION: ['TRANSLATION', 'CAPTION'],
  CAPTION_DISPLAY: ['CAPTION', 'DISPLAY'], TRANSLATION_TTS: ['TRANSLATION', 'TTS'], TTS_SPEAKER: ['TTS', 'SPEAKER'],
};

function SignalFlow({ manifest, twin, labels }: { readonly manifest: TwinAssetManifest; readonly twin: TwinState; readonly labels: Readonly<Record<string, string>> }): ReactElement {
  const nodes = useMemo(() => nodePositions(manifest), [manifest]);
  return <group name="twin-signal-flow">
    {(Object.keys(segmentEnds) as SegmentId[]).map((id) => {
      const [a, b] = segmentEnds[id];
      const active = twin.segments[id].active;
      return <Line key={id} name={`segment-${id}`} points={[nodes[a], nodes[b]]} color={active ? '#f4b860' : '#39424f'} lineWidth={active ? 3.5 : 1} dashed={!active} dashSize={0.004} gapSize={0.003} />;
    })}
    {Object.entries(nodes).map(([id, p]) => <group key={id} position={p}>
      <mesh><sphereGeometry args={[0.0035, 16, 12]} /><meshBasicMaterial color="#aab6c8" /></mesh>
      <Html center distanceFactor={0.28} className="twin-3d-label">{labels[`flow.${id}`] ?? id}</Html>
    </group>)}
  </group>;
}

function CameraRig({ mode, manifest, reducedMotion }: { readonly mode: TwinMode; readonly manifest: TwinAssetManifest; readonly reducedMotion: boolean }): null {
  const { camera, invalidate, controls } = useThree() as unknown as { camera: THREE.PerspectiveCamera; invalidate: () => void; controls: { target: THREE.Vector3; update: () => void } | null };
  const goal = useRef<{ pos: THREE.Vector3; look: THREE.Vector3 } | null>(null);
  useEffect(() => {
    // LIVE_FRAMEBUFFER: the wearer's point of view behind the display-side lens.
    const look = mode === 'LIVE_FRAMEBUFFER' ? new THREE.Vector3(...toScene(manifest, [40, 25, 142]))
      : mode === 'SIGNAL_FLOW' ? new THREE.Vector3(0.04, -0.005, 0.02) : new THREE.Vector3(0, 0, 0);
    const pos = mode === 'LIVE_FRAMEBUFFER'
      ? new THREE.Vector3(...toScene(manifest, [40, 27, 88]))
      : mode === 'SIGNAL_FLOW' ? new THREE.Vector3(0.07, 0.2, 0.36) : new THREE.Vector3(0.2, 0.12, 0.28);
    goal.current = { pos, look };
    if (reducedMotion) {
      camera.position.copy(pos);
      controls?.target.copy(look);
      controls?.update();
      camera.lookAt(look);
      goal.current = null;
    }
    invalidate();
  }, [mode, manifest, reducedMotion, camera, controls, invalidate]);
  useFrame((_, dt) => {
    const g = goal.current;
    if (!g) return;
    const k = Math.min(1, dt * 5);
    camera.position.lerp(g.pos, k);
    controls?.target.lerp(g.look, k);
    controls?.update();
    if (camera.position.distanceTo(g.pos) < 0.0005) goal.current = null;
    invalidate();
  });
  return null;
}

/** On request, renders a fixed number of frames and reports measured timings. */
function PerfProbe({ request, onPerf }: { readonly request: number; readonly onPerf: (r: PerfResult) => void }): null {
  const { gl, invalidate } = useThree();
  const run = useRef<{ left: number; last: number; samples: number[] } | null>(null);
  useEffect(() => {
    if (request === 0) return;
    run.current = { left: 180, last: performance.now(), samples: [] };
    invalidate();
  }, [request, invalidate]);
  useFrame(() => {
    const r = run.current;
    if (!r) return;
    const now = performance.now();
    r.samples.push(now - r.last);
    r.last = now;
    r.left -= 1;
    if (r.left > 0) {
      invalidate();
      return;
    }
    run.current = null;
    const sorted = r.samples.slice(10).sort((a, b) => a - b); // drop warm-up frames
    const pick = (p: number) => sorted[Math.min(sorted.length - 1, Math.ceil((p / 100) * sorted.length) - 1)];
    const ctx = gl.getContext();
    const info = ctx.getExtension('WEBGL_debug_renderer_info');
    const renderer = info ? String(ctx.getParameter(info.UNMASKED_RENDERER_WEBGL)) : String(ctx.getParameter(ctx.RENDERER));
    onPerf({
      frames: sorted.length,
      frameMsP50: pick(50),
      frameMsP95: pick(95),
      fpsP50: 1000 / pick(50),
      fpsP95: 1000 / pick(95),
      drawCalls: gl.info.render.calls,
      triangles: gl.info.render.triangles,
      renderer,
    });
  });
  return null;
}

function FrameTexture({ url, onTexture }: { readonly url: string | null; readonly onTexture: (t: THREE.Texture | null) => void }): null {
  const { invalidate } = useThree();
  useEffect(() => {
    if (!url) {
      onTexture(null);
      invalidate();
      return;
    }
    let cancelled = false;
    new THREE.TextureLoader().load(url, (t) => {
      if (cancelled) return t.dispose();
      t.colorSpace = THREE.SRGBColorSpace;
      t.magFilter = THREE.NearestFilter;
      t.minFilter = THREE.NearestFilter;
      onTexture(t);
      invalidate();
    }, undefined, () => {
      if (!cancelled) onTexture(null);
    });
    return () => { cancelled = true; };
  }, [url, onTexture, invalidate]);
  return null;
}

export default function HaloTwinScene(props: HaloTwinSceneProps): ReactElement {
  const { manifest, shell, twin, mode, selected, onSelect, frameUrl, reducedMotion, perfRequest, onPerf, labels } = props;
  const textureRef = useRef<THREE.Texture | null>(null);
  const [, setTextureVersion] = useState(0);
  const onTexture = useCallback((t: THREE.Texture | null) => {
    textureRef.current?.dispose();
    textureRef.current = t;
    setTextureVersion((v) => v + 1);
  }, []);
  const proxies = TWIN_COMPONENTS.filter((c) => c.id !== 'shell');
  return <Canvas frameloop="demand" dpr={[1, 2]} camera={{ position: [0.2, 0.12, 0.28], fov: 35, near: 0.001, far: 5 }}
    gl={{ antialias: true, preserveDrawingBuffer: true }} data-testid="halo-twin-canvas" aria-hidden="true">
    <color attach="background" args={['#0b0f16']} />
    <ambientLight intensity={0.6} />
    <directionalLight position={[0.3, 0.4, 0.5]} intensity={1.4} />
    <directionalLight position={[-0.3, 0.2, -0.4]} intensity={0.5} />
    <Shell shell={shell} mode={mode} />
    <ExplodeGroup mode={mode} reducedMotion={reducedMotion}>
      {(explode) => proxies.map((c) => <Proxy key={c.id} c={c} manifest={manifest} mode={mode} explode={explode} twin={twin}
        selected={selected === c.id} onSelect={onSelect} frameTexture={textureRef.current} label={labels[`c.${c.id}`] ?? c.id} />)}
    </ExplodeGroup>
    {mode === 'LIVE_FRAMEBUFFER' || mode === 'ASSEMBLED' ? <VirtualImage manifest={manifest} frameTexture={textureRef.current} /> : null}
    {mode === 'SIGNAL_FLOW' ? <SignalFlow manifest={manifest} twin={twin} labels={labels} /> : null}
    <FrameTexture url={frameUrl} onTexture={onTexture} />
    <OrbitControls makeDefault enableDamping={false} minDistance={0.05} maxDistance={0.8} />
    <CameraRig mode={mode} manifest={manifest} reducedMotion={reducedMotion} />
    <PerfProbe request={perfRequest} onPerf={onPerf} />
  </Canvas>;
}

function ExplodeGroup({ mode, reducedMotion, children }: { readonly mode: TwinMode; readonly reducedMotion: boolean; readonly children: (explode: React.MutableRefObject<number>) => React.ReactNode }): ReactElement {
  const explode = useEased(mode === 'EXPLODED' ? 1 : 0, reducedMotion);
  return <>{children(explode)}</>;
}
