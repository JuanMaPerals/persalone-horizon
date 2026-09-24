export const COMMUNITY_SCENARIO_SCHEMA = 'persalone.halo.community-scenario/v1' as const;

export type HudColor = 'cyan' | 'green' | 'amber' | 'white';
export type CommunityInteraction = 'tap' | 'doubleTap' | 'longPress';

export interface CommunityScenario {
  readonly id: string;
  readonly title: string;
  readonly purpose: string;
  readonly evidence: 'SIMULATED';
  readonly pages: readonly string[];
  readonly brightness: number;
  readonly fontSize: number;
  readonly textColor: HudColor;
  readonly capabilities: readonly string[];
  readonly interactions: readonly CommunityInteraction[];
}

export interface CommunityContribution {
  readonly schema: typeof COMMUNITY_SCENARIO_SCHEMA;
  readonly createdBy: 'HALO Community Lab';
  readonly scenario: CommunityScenario;
}

const colors = new Set<HudColor>(['cyan', 'green', 'amber', 'white']);
const interactions = new Set<CommunityInteraction>(['tap', 'doubleTap', 'longPress']);

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function boundedString(value: unknown, name: string, maxLength: number): string {
  if (typeof value !== 'string' || value.trim().length === 0 || value.length > maxLength) {
    throw new Error(`Invalid ${name}.`);
  }
  return value;
}

function boundedStringArray(value: unknown, name: string, maxItems: number, maxLength: number): readonly string[] {
  if (!Array.isArray(value) || value.length === 0 || value.length > maxItems) {
    throw new Error(`Invalid ${name}.`);
  }
  return value.map((item) => boundedString(item, name, maxLength));
}

export function parseCommunityContribution(raw: string): CommunityScenario {
  if (raw.length > 64_000) throw new Error('Contribution exceeds the 64 KB local import limit.');
  const decoded: unknown = JSON.parse(raw);
  if (!isRecord(decoded) || decoded.schema !== COMMUNITY_SCENARIO_SCHEMA || !isRecord(decoded.scenario)) {
    throw new Error('Unsupported community scenario schema.');
  }
  const scenario = decoded.scenario;
  if (scenario.evidence !== 'SIMULATED') {
    throw new Error('Community imports may only claim SIMULATED evidence.');
  }

  const textColor = boundedString(scenario.textColor, 'textColor', 12);
  if (!colors.has(textColor as HudColor)) throw new Error('Unsupported HUD color.');

  const brightness = scenario.brightness;
  const fontSize = scenario.fontSize;
  if (typeof brightness !== 'number' || brightness < 5 || brightness > 100) throw new Error('Brightness must be 5..100.');
  if (typeof fontSize !== 'number' || fontSize < 12 || fontSize > 30) throw new Error('Font size must be 12..30.');

  const importedInteractions = boundedStringArray(scenario.interactions, 'interactions', 3, 16);
  if (importedInteractions.some((item) => !interactions.has(item as CommunityInteraction))) {
    throw new Error('Unsupported interaction.');
  }

  return {
    id: boundedString(scenario.id, 'id', 80),
    title: boundedString(scenario.title, 'title', 120),
    purpose: boundedString(scenario.purpose, 'purpose', 400),
    evidence: 'SIMULATED',
    pages: boundedStringArray(scenario.pages, 'pages', 12, 800),
    brightness,
    fontSize,
    textColor: textColor as HudColor,
    capabilities: boundedStringArray(scenario.capabilities, 'capabilities', 12, 80),
    interactions: importedInteractions as readonly CommunityInteraction[],
  };
}

export function serializeCommunityContribution(scenario: CommunityScenario): string {
  const contribution: CommunityContribution = {
    schema: COMMUNITY_SCENARIO_SCHEMA,
    createdBy: 'HALO Community Lab',
    scenario,
  };
  return JSON.stringify(contribution, null, 2);
}

export const communityScenarios: readonly CommunityScenario[] = [
  {
    id: 'live-translation',
    title: 'Live Translation',
    purpose: 'Exercise the same HUD interaction model planned for the G5 translation runtime without claiming physical Halo evidence.',
    evidence: 'SIMULATED',
    pages: [
      'Listening…\nSpanish → English',
      '“Necesito confirmar la reunión de mañana.”',
      '“I need to confirm tomorrow’s meeting.”',
      'Tap to continue · long press to stop',
    ],
    brightness: 62,
    fontSize: 20,
    textColor: 'cyan',
    capabilities: ['microphone', 'STT', 'translation', 'HUD', 'TTS', 'speaker'],
    interactions: ['tap', 'longPress'],
  },
  {
    id: 'vision-phone-bridge',
    title: 'Vision / Phone Bridge',
    purpose: 'Model a camera → phone bridge → model → paged HUD response flow for community experiments.',
    evidence: 'SIMULATED',
    pages: [
      'Camera frame ready\nTap to submit',
      'Context result\nObject: transit sign\nConfidence: simulated',
      'Next action\nPlatform 2 · 4 min\nTap for details',
    ],
    brightness: 48,
    fontSize: 18,
    textColor: 'green',
    capabilities: ['camera', 'phone bridge', 'model API', 'HUD', 'pagination'],
    interactions: ['tap', 'doubleTap'],
  },
  {
    id: 'cognitive-assist',
    title: 'Cognitive Assistance',
    purpose: 'Prototype glanceable prompts, memory cues and low-cognitive-load interaction without retaining personal data.',
    evidence: 'SIMULATED',
    pages: [
      'Context cue\nConversation: project review',
      'Remember\nAsk about the delivery date',
      'Next\nSummarise only if requested',
    ],
    brightness: 54,
    fontSize: 21,
    textColor: 'amber',
    capabilities: ['context', 'memory policy', 'HUD', 'tap navigation'],
    interactions: ['tap', 'longPress'],
  },
  {
    id: 'round-layout',
    title: 'Round Display Layout',
    purpose: 'Stress-test pagination and typography for a 256×256 circular near-eye display before hardware validation.',
    evidence: 'SIMULATED',
    pages: [
      'Circular layout\n256 × 256\nSafe center region',
      'Longer content uses multiple blocks instead of shrinking text below a readable threshold.',
      'Tap advances one block\nDouble tap returns to start',
    ],
    brightness: 58,
    fontSize: 18,
    textColor: 'white',
    capabilities: ['HUD', 'pagination', 'typography', 'accessibility'],
    interactions: ['tap', 'doubleTap'],
  },
];