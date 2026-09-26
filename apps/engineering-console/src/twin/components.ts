// Halo twin component catalogue. Only the shell (frame, lenses, arms) is
// official geometry (Brilliant Labs halo/halo.stl). Every internal part is a
// proxy shape; its provenance says how its LOCATION is known. Inferred
// geometry is never presented as real.
//
// Sources (brilliantlabsAR/docs @ 808d317):
//   halo/hardware.md (text), halo/images/halo-*.jpeg (official renders),
//   halo/images/halo-exploded-view.jpeg (labelled exploded view).
// Positions are in the STL's millimetre frame (X width, Y up, Z front);
// the loader applies the asset manifest's transform (recentre, mm -> m).

export type Provenance = 'OFFICIAL_GEOMETRY' | 'OFFICIAL_LOCATION' | 'DOCUMENTED_PROXY' | 'INFERRED_PROXY' | 'UNKNOWN';

export type Capability = 'DISPLAY' | 'CAMERA' | 'BUTTON' | 'MICROPHONE' | 'SPEAKER' | 'BLE' | 'IMU' | 'POWER' | 'STRUCTURE' | 'ELECTRONICS';

export type ComponentId =
  | 'shell' | 'display' | 'camera' | 'button' | 'micLeft' | 'micRight'
  | 'speakerLeft' | 'speakerRight' | 'batteryLeft' | 'batteryRight' | 'mcu' | 'pcb' | 'imu';

export type ProxyShape =
  | { readonly kind: 'box'; readonly sizeMm: readonly [number, number, number] }
  | { readonly kind: 'sphere'; readonly radiusMm: number }
  | { readonly kind: 'cylinder'; readonly radiusMm: number; readonly lengthMm: number; readonly axis: 'x' | 'y' | 'z' };

export interface TwinComponent {
  readonly id: ComponentId;
  readonly capability: Capability;
  readonly provenance: Provenance;
  /** Where the location claim comes from (doc section or image). */
  readonly source: string;
  /** What is and is not known; shown verbatim in the UI. */
  readonly note: string;
  /** Proxy centre in the STL millimetre frame; null for the shell. */
  readonly positionMm: readonly [number, number, number] | null;
  readonly shape: ProxyShape | null;
  /** Unit direction used by the exploded view. */
  readonly explode: readonly [number, number, number];
}

const docs = 'brilliantlabsAR/docs@808d317';

export const TWIN_COMPONENTS: readonly TwinComponent[] = [
  {
    id: 'shell', capability: 'STRUCTURE', provenance: 'OFFICIAL_GEOMETRY',
    source: `${docs} halo/halo.stl`,
    note: 'Official full assembly (front, both lenses, both arms open), converted to GLB. No internal parts in the official model.',
    positionMm: null, shape: null, explode: [0, 0, 0],
  },
  {
    id: 'display', capability: 'DISPLAY', provenance: 'OFFICIAL_LOCATION',
    source: `${docs} halo/hardware.md#display + halo/images/halo-display.jpeg`,
    note: 'Text: "mounted to the top of Halo\'s frame"; the official render shows it on the inner side above the wearer\'s right lens. Proxy shape; exact optics not modelled.',
    positionMm: [40, 43, 151], shape: { kind: 'cylinder', radiusMm: 4, lengthMm: 6, axis: 'z' }, explode: [0, 0.8, -0.6],
  },
  {
    id: 'camera', capability: 'CAMERA', provenance: 'OFFICIAL_LOCATION',
    source: `${docs} halo/hardware.md#camera + halo/images/halo-camera.jpeg`,
    note: 'Text: "front facing camera"; the official render places it at the upper front corner near the hinge. Side taken from the exploded view (display side).',
    positionMm: [9, 41, 161], shape: { kind: 'sphere', radiusMm: 2.5 }, explode: [-0.5, 0.4, 0.8],
  },
  {
    id: 'button', capability: 'BUTTON', provenance: 'OFFICIAL_LOCATION',
    source: `${docs} halo/hardware.md#button + halo/images/halo-button.jpeg`,
    note: 'Text: "placed under the left arm"; the official render shows it near the hinge with an LED. Proxy shape.',
    positionMm: [139, 37, 136], shape: { kind: 'box', sizeMm: [3, 2, 8] }, explode: [0.7, -0.7, 0],
  },
  {
    id: 'micLeft', capability: 'MICROPHONE', provenance: 'DOCUMENTED_PROXY',
    source: `${docs} halo/hardware.md#microphones + halo/images/halo-microphone.jpeg`,
    note: 'Dual T5838 MEMS microphones; the official render marks one port on each arm near the hinge. Approximate position.',
    positionMm: [141.5, 42, 142], shape: { kind: 'sphere', radiusMm: 1.6 }, explode: [1, 0.3, 0],
  },
  {
    id: 'micRight', capability: 'MICROPHONE', provenance: 'DOCUMENTED_PROXY',
    source: `${docs} halo/hardware.md#microphones + halo/images/halo-microphone.jpeg`,
    note: 'Dual T5838 MEMS microphones; the official render marks one port on each arm near the hinge. Approximate position.',
    positionMm: [3, 42, 142], shape: { kind: 'sphere', radiusMm: 1.6 }, explode: [-1, 0.3, 0],
  },
  {
    id: 'speakerLeft', capability: 'SPEAKER', provenance: 'DOCUMENTED_PROXY',
    source: `${docs} halo/hardware.md#speakers + halo/images/halo-speaker.jpeg`,
    note: 'Stereo bone-conduction speakers; the official render shows pads on the inner side of each arm. Approximate position and size.',
    positionMm: [133, 40, 66], shape: { kind: 'box', sizeMm: [3, 6, 20] }, explode: [-0.6, -0.8, 0],
  },
  {
    id: 'speakerRight', capability: 'SPEAKER', provenance: 'DOCUMENTED_PROXY',
    source: `${docs} halo/hardware.md#speakers + halo/images/halo-speaker.jpeg`,
    note: 'Stereo bone-conduction speakers; the official render shows pads on the inner side of each arm. Approximate position and size.',
    positionMm: [11.5, 40, 66], shape: { kind: 'box', sizeMm: [3, 6, 20] }, explode: [0.6, -0.8, 0],
  },
  {
    id: 'batteryLeft', capability: 'POWER', provenance: 'DOCUMENTED_PROXY',
    source: `${docs} halo/hardware.md#power + halo/images/halo-exploded-view.jpeg`,
    note: 'Two GRP1654M1 cells (150 mAh each); the exploded view labels a cell in each arm tip. Approximate position.',
    positionMm: [123.5, 12, 14], shape: { kind: 'cylinder', radiusMm: 8, lengthMm: 5.4, axis: 'x' }, explode: [0.5, -0.6, -0.6],
  },
  {
    id: 'batteryRight', capability: 'POWER', provenance: 'DOCUMENTED_PROXY',
    source: `${docs} halo/hardware.md#power + halo/images/halo-exploded-view.jpeg`,
    note: 'Two GRP1654M1 cells (150 mAh each); the exploded view labels a cell in each arm tip. Approximate position.',
    positionMm: [21, 12, 14], shape: { kind: 'cylinder', radiusMm: 8, lengthMm: 5.4, axis: 'x' }, explode: [-0.5, -0.6, -0.6],
  },
  {
    id: 'mcu', capability: 'BLE', provenance: 'DOCUMENTED_PROXY',
    source: `${docs} halo/hardware.md#bluetooth-mcu + halo/images/halo-exploded-view.jpeg ("AI Processor")`,
    note: 'Alif Balletto B1 (Cortex-M55, Ethos-U55, BLE 5.3). The exploded view labels the processor board in the display-side arm. Approximate position and size.',
    positionMm: [4, 42, 118], shape: { kind: 'box', sizeMm: [3, 6, 22] }, explode: [-1, 0.6, 0],
  },
  {
    id: 'pcb', capability: 'ELECTRONICS', provenance: 'DOCUMENTED_PROXY',
    source: `${docs} halo/images/halo-exploded-view.jpeg ("PCB")`,
    note: 'The exploded view labels a PCB in the other arm. Approximate position and size.',
    positionMm: [140, 42, 118], shape: { kind: 'box', sizeMm: [3, 6, 22] }, explode: [1, 0.6, 0],
  },
  {
    id: 'imu', capability: 'IMU', provenance: 'INFERRED_PROXY',
    source: `${docs} halo/hardware.md#motion-sensor-imu (no location given)`,
    note: 'BMA580 accelerometer + QMC6308 e-compass. No official location: placed on the documented PCB for navigation only. Not a real position.',
    positionMm: [140, 42, 104], shape: { kind: 'box', sizeMm: [3, 3, 3] }, explode: [1, 1, 0],
  },
];

export function findComponent(id: string): TwinComponent | undefined {
  return TWIN_COMPONENTS.find((c) => c.id === id);
}

/** Only the official STL may carry OFFICIAL_GEOMETRY; this guards edits. */
export function provenanceViolations(components: readonly TwinComponent[] = TWIN_COMPONENTS): string[] {
  return components.flatMap((c) => {
    const problems: string[] = [];
    if (c.provenance === 'OFFICIAL_GEOMETRY' && c.id !== 'shell') problems.push(`${c.id}: proxy marked OFFICIAL_GEOMETRY`);
    if (c.provenance === 'INFERRED_PROXY' && !/not a real position|no official location/i.test(c.note)) problems.push(`${c.id}: inferred proxy without explicit disclaimer`);
    if (c.id !== 'shell' && (c.shape === null || c.positionMm === null)) problems.push(`${c.id}: proxy without shape/position`);
    return problems;
  });
}
