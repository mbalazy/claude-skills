// Phase-2 fixture shared by f-expo and f-cli. Every screen exists to answer a question from
// the Android analysis; testIDs are stable and documented in the phase-2 report.
import { useEffect, useRef, useState } from 'react';
import {
  AccessibilityInfo,
  ActivityIndicator,
  Animated,
  BackHandler,
  Dimensions,
  Easing,
  FlatList,
  Image,
  Linking,
  Modal,
  PanResponder,
  PermissionsAndroid,
  PixelRatio,
  Platform,
  Pressable,
  ScrollView,
  StatusBar,
  StyleSheet,
  Switch,
  Text,
  TextInput,
  View,
  type LayoutChangeEvent,
} from 'react-native';
import RA, {
  useAnimatedStyle,
  useReducedMotion,
  useSharedValue,
  withRepeat,
  withTiming,
} from 'react-native-reanimated';
import { PROBE_PORT } from './rigswitch';

type Screen =
  | 'home' | 'profile' | 'settings' | 'badge' | 'network' | 'components' | 'inputs'
  | 'list' | 'anim' | 'back' | 'perm' | 'big' | 'gest';
const SCREENS: Screen[] = ['home', 'profile', 'settings', 'badge', 'network', 'components', 'inputs', 'list', 'anim', 'back', 'perm', 'big', 'gest'];

const logLayout = (tag: string) => (e: LayoutChangeEvent) => {
  const { x, y, width, height } = e.nativeEvent.layout;
  console.log(`[LAYOUT] ${tag} ${JSON.stringify({ x, y, width, height })}`);
};

function screenFromUrl(url: string | null): Screen | null {
  if (!url) return null;
  const m = url.match(/:\/\/screen\/(\w+)/);
  if (!m) return null;
  const s = m[1] as Screen;
  return SCREENS.includes(s) ? s : null;
}

function NavButton({ id, label, onPress }: { id: string; label: string; onPress: () => void }) {
  return (
    <Pressable testID={id} accessibilityRole="button" onPress={onPress} style={styles.navButton}>
      <Text style={styles.navButtonText}>{label}</Text>
    </Pressable>
  );
}

function Header({ title, id, onBack }: { title: string; id: string; onBack?: () => void }) {
  return (
    <View style={styles.header}>
      {onBack ? (
        <Pressable testID="Back-button" accessibilityRole="button" accessibilityLabel="Back" onPress={onBack}>
          <Text style={styles.back}>Back</Text>
        </Pressable>
      ) : null}
      <Text testID={id} accessibilityRole="header" style={styles.title}>
        {title}
      </Text>
    </View>
  );
}

function ProfileScreen({ onBack }: { onBack: () => void }) {
  const [q, setQ] = useState('');
  const [saved, setSaved] = useState(false);
  return (
    <View style={styles.screen}>
      <Header title="Profile" id="Profile-title" onBack={onBack} />
      <Text testID="Profile-name" style={styles.body}>Alice Example</Text>
      <TextInput testID="Profile-search" placeholder="Search notes" value={q} onChangeText={setQ}
        style={styles.input} autoCorrect={false} autoCapitalize="none" />
      <NavButton id="Profile-save" label={saved ? 'Saved' : 'Save'} onPress={() => setSaved(true)} />
    </View>
  );
}

function SettingsScreen({ onBack }: { onBack: () => void }) {
  const [on, setOn] = useState(true);
  return (
    <View style={styles.screen}>
      <Header title="Settings" id="Settings-title" onBack={onBack} />
      <View style={styles.row}>
        <Text style={styles.body}>Notifications</Text>
        <Switch testID="Settings-notifications" value={on} onValueChange={setOn} />
      </View>
    </View>
  );
}

// Layout: badge label 3dp high, anchor/frame 6dp apart; Layout-measure prints measureInWindow.
function BadgeScreen({ onBack }: { onBack: () => void }) {
  const pill = useRef<any>(null);
  const anchor = useRef<any>(null);
  const [out, setOut] = useState('');
  const measure = () => {
    const parts: string[] = [];
    const take = (name: string, r: any, done: () => void) =>
      r ? r.measureInWindow((x: number, y: number, w: number, h: number) => { parts.push(`${name} ${x.toFixed(1)},${y.toFixed(1)},${w.toFixed(1)},${h.toFixed(1)}`); done(); }) : done();
    take('pill', pill.current, () => take('anchor', anchor.current, () => {
      const s = parts.join(' | ');
      setOut(s);
      console.log(`[MEASURE] ${s}`);
    }));
  };
  return (
    <View style={styles.screen}>
      <Header title="Badge" id="Badge-title" onBack={onBack} />
      <View style={styles.badgeWrap}>
        <View ref={pill} testID="Badge-pill" style={styles.pill} onLayout={logLayout('BADGE_PILL')}>
          <Text style={styles.pillText} onLayout={logLayout('BADGE_TEXT')}>NEW</Text>
        </View>
      </View>
      <View style={styles.boxes}>
        <View ref={anchor} testID="Badge-anchor" style={styles.anchorBox} onLayout={logLayout('ANCHOR')} />
        <View testID="Badge-frame" style={styles.frameBox} onLayout={logLayout('FRAME')} />
      </View>
      <NavButton id="Layout-measure" label="Measure" onPress={measure} />
      <Text testID="Layout-out" style={styles.small}>{out}</Text>
    </View>
  );
}

function NetworkScreen({ onBack }: { onBack: () => void }) {
  const [status, setStatus] = useState('idle');
  const load = async (host: string) => {
    setStatus(`loading ${host}`);
    try {
      const r = await fetch(`http://${host}:${PROBE_PORT}/?tag=fixture-network&host=${host}`);
      setStatus(`status ${r.status} ${host}`);
      console.log(`[FIXTURE] network status ${r.status} ${host}`);
    } catch (e) {
      setStatus(`failed ${host}`);
      console.log(`[FIXTURE] network failed ${host} ${String(e)}`);
    }
  };
  return (
    <View style={styles.screen}>
      <Header title="Network" id="Network-title" onBack={onBack} />
      <NavButton id="Network-load" label="Load localhost" onPress={() => load('localhost')} />
      <NavButton id="Network-load-alias" label="Load 10.0.2.2" onPress={() => load('10.0.2.2')} />
      <Text testID="Network-status" style={styles.body}>{status}</Text>
    </View>
  );
}

// Every component type with a testID, plus accessibility compositions (busy, value, role
// without label), an invisible view, an occluded text, a modal, duplicate labels.
function ComponentsScreen({ onBack }: { onBack: () => void }) {
  const [sw, setSw] = useState(false);
  const [modal, setModal] = useState(false);
  const [taps, setTaps] = useState(0);
  return (
    <ScrollView testID="Comp-root" contentContainerStyle={styles.screen}>
      <Header title="Components" id="Comp-title" onBack={onBack} />
      <View testID="Comp-view" style={styles.box} />
      <View nativeID="Comp-nativeid-only" style={styles.box2} />
      <Text testID="Comp-text" style={styles.body}>Plain text</Text>
      <Text testID="Comp-text-outer" style={styles.body}>
        Outer <Text testID="Comp-text-inner" style={styles.bold}>inner</Text> tail
      </Text>
      <Image testID="Comp-image" source={require('./assets/icon.png')} style={styles.img} />
      <Pressable testID="Comp-pressable-nolabel" onPress={() => setTaps((t) => t + 1)} style={styles.box3} />
      <Pressable testID="Comp-pressable-text" onPress={() => setTaps((t) => t + 1)}>
        <Text style={styles.body}>Pressable child text</Text>
      </Pressable>
      <Pressable testID="Comp-label-only" accessibilityLabel="Labelled thing" onPress={() => setTaps((t) => t + 1)}>
        <Text style={styles.body}>Shown text differs</Text>
      </Pressable>
      <Text testID="Comp-taps" style={styles.body}>taps {taps}</Text>
      <Switch testID="Comp-switch" value={sw} onValueChange={setSw} />
      <View testID="Comp-busy" accessible accessibilityLabel="Loading data" accessibilityState={{ busy: true }} style={styles.box} />
      <View testID="Comp-value" accessible accessibilityLabel="Volume" accessibilityValue={{ text: '50 percent' }} style={styles.box} />
      <View testID="Comp-role-button" accessible accessibilityRole="button" style={styles.rowBox}>
        <Text>Child A</Text>
        <Text>Child B</Text>
      </View>
      <View testID="Comp-opacity0" style={[styles.box, { opacity: 0 }]} />
      <View style={styles.coverWrap}>
        <Text testID="Comp-covered" style={styles.body}>Covered text</Text>
        <View testID="Comp-cover" style={styles.cover} />
      </View>
      <Text style={styles.body}>Duplicate</Text>
      <Text style={styles.body}>Duplicate</Text>
      <ScrollView testID="Comp-hscroll" horizontal style={{ height: 60 }}>
        {Array.from({ length: 10 }, (_, i) => (
          <View key={i} testID={`Comp-hitem-${i}`} style={styles.hitem}><Text>Item {i}</Text></View>
        ))}
      </ScrollView>
      <NavButton id="Comp-modal-open" label="Open modal" onPress={() => setModal(true)} />
      <Modal testID="Comp-modal" visible={modal} transparent onRequestClose={() => setModal(false)}>
        <View style={styles.modalBack}>
          <View style={styles.modalCard}>
            <Text testID="Comp-modal-text" style={styles.body}>Modal content</Text>
            <NavButton id="Comp-modal-close" label="Close" onPress={() => setModal(false)} />
          </View>
        </View>
      </Modal>
    </ScrollView>
  );
}

function maskPhone(d: string) {
  const s = d.replace(/\D/g, '').slice(0, 10);
  if (s.length <= 3) return s;
  if (s.length <= 6) return `(${s.slice(0, 3)}) ${s.slice(3)}`;
  return `(${s.slice(0, 3)}) ${s.slice(3, 6)}-${s.slice(6)}`;
}

function InputsScreen({ onBack }: { onBack: () => void }) {
  const [c, setC] = useState('');
  const [u, setU] = useState('');
  const [p, setP] = useState('');
  const [changes, setChanges] = useState(0);
  const [submits, setSubmits] = useState(0);
  return (
    <ScrollView contentContainerStyle={styles.screen} keyboardShouldPersistTaps="handled">
      <Header title="Inputs" id="Input-title" onBack={onBack} />
      <TextInput testID="Input-controlled" placeholder="Controlled" value={c}
        onChangeText={(t) => { setC(t); setChanges((n) => n + 1); }}
        onSubmitEditing={() => setSubmits((n) => n + 1)}
        style={styles.input} autoCorrect={false} autoCapitalize="none" />
      <Text testID="Input-controlled-mirror" style={styles.small}>[{c}]</Text>
      <TextInput testID="Input-uncontrolled" placeholder="Uncontrolled" defaultValue=""
        onChangeText={setU} style={styles.input} autoCorrect={false} autoCapitalize="none" />
      <Text testID="Input-uncontrolled-mirror" style={styles.small}>[{u}]</Text>
      <TextInput testID="Input-phone" placeholder="Phone" value={p} keyboardType="phone-pad"
        onChangeText={(t) => setP(maskPhone(t))} style={styles.input} />
      <Text testID="Input-phone-mirror" style={styles.small}>[{p}]</Text>
      <Text testID="Input-counts" style={styles.small}>changes {changes} submits {submits}</Text>
    </ScrollView>
  );
}

function ListScreen({ onBack }: { onBack: () => void }) {
  const data = Array.from({ length: 100 }, (_, i) => i);
  return (
    <View style={styles.screen}>
      <Header title="List" id="List-title" onBack={onBack} />
      <FlatList testID="List-flat" data={data} keyExtractor={(i) => String(i)}
        renderItem={({ item }) => (
          <View testID={`List-row-${item}`} style={styles.listRow}><Text>Row {item}</Text></View>
        )} />
    </View>
  );
}

// Each animation is OFF until its toggle is pressed, so a tree read can be measured with one
// infinite animation at a time.
function AnimScreen({ onBack }: { onBack: () => void }) {
  const [spin, setSpin] = useState(false);
  const [loop, setLoop] = useState(false);
  const [rea, setRea] = useState(false);
  const [core, setCore] = useState<string>('?');
  const reaReduced = useReducedMotion();
  const v = useRef(new Animated.Value(0)).current;
  const sv = useSharedValue(0);
  useEffect(() => {
    AccessibilityInfo.isReduceMotionEnabled().then((b) => setCore(String(b)));
  }, []);
  useEffect(() => {
    if (!loop) return;
    const a = Animated.loop(Animated.timing(v, { toValue: 1, duration: 800, easing: Easing.linear, useNativeDriver: true }));
    a.start();
    return () => a.stop();
  }, [loop, v]);
  useEffect(() => {
    sv.value = rea ? withRepeat(withTiming(1, { duration: 800 }), -1, true) : 0;
  }, [rea, sv]);
  const reaStyle = useAnimatedStyle(() => ({ transform: [{ translateX: sv.value * 150 }] }));
  const rot = v.interpolate({ inputRange: [0, 1], outputRange: ['0deg', '360deg'] });
  // gap tests: one-shot transitions (frame-catch risk at waitForIdleTimeout=0)
  const slide = useRef(new Animated.Value(0)).current;
  const [slid, setSlid] = useState(false);
  const [smodal, setSmodal] = useState(false);
  const doSlide = () => { const to = slid ? 0 : 1; setSlid(!slid); Animated.timing(slide, { toValue: to, duration: 1500, easing: Easing.linear, useNativeDriver: true }).start(); };
  const sx = slide.interpolate({ inputRange: [0, 1], outputRange: [0, 200] });
  // transitions longer than the 2 s --settled gap: a steady 4 s slide, and a slide that
  // holds still for 2.5 s halfway (two reads 2 s apart can both land in the hold)
  const slow = useRef(new Animated.Value(0)).current;
  const doSlow = () => { slow.setValue(0); Animated.timing(slow, { toValue: 1, duration: 4000, easing: Easing.linear, useNativeDriver: true }).start(); };
  const doHold = () => {
    slow.setValue(0);
    Animated.sequence([
      Animated.timing(slow, { toValue: 0.5, duration: 300, easing: Easing.linear, useNativeDriver: true }),
      Animated.delay(2500),
      Animated.timing(slow, { toValue: 1, duration: 300, easing: Easing.linear, useNativeDriver: true }),
    ]).start();
  };
  const slowX = slow.interpolate({ inputRange: [0, 1], outputRange: [0, 200] });
  return (
    <View style={styles.screen}>
      <Header title="Anim" id="Anim-title" onBack={onBack} />
      <Text testID="Anim-reduce" style={styles.small}>reduceMotion core={core} reanimated={String(reaReduced)}</Text>
      <NavButton id="Anim-toggle-spinner" label={`spinner ${spin ? 'on' : 'off'}`} onPress={() => setSpin((s) => !s)} />
      <NavButton id="Anim-toggle-loop" label={`loop ${loop ? 'on' : 'off'}`} onPress={() => setLoop((s) => !s)} />
      <NavButton id="Anim-toggle-rea" label={`reanimated ${rea ? 'on' : 'off'}`} onPress={() => setRea((s) => !s)} />
      {spin ? <ActivityIndicator testID="Anim-spinner" size="large" /> : null}
      <Animated.View testID="Anim-loop" style={[styles.box, { transform: [{ rotate: rot }] }]} />
      <RA.View testID="Anim-rea" style={[styles.box3, reaStyle]} />
      <NavButton id="Anim-slide" label={`slide ${slid ? 'right' : 'left'}`} onPress={doSlide} />
      <Animated.View testID="Anim-slide-box" style={[styles.box, { transform: [{ translateX: sx }] }]} />
      <NavButton id="Anim-slow" label="slide 4 s" onPress={doSlow} />
      <NavButton id="Anim-hold" label="slide, hold 2.5 s, slide" onPress={doHold} />
      <Animated.View testID="Anim-slow-box" style={[styles.box, { transform: [{ translateX: slowX }] }]} />
      <NavButton id="Anim-modal-open" label="Slide modal" onPress={() => setSmodal(true)} />
      <Modal testID="Anim-modal" visible={smodal} animationType="slide" onRequestClose={() => setSmodal(false)}>
        <View style={styles.screen}><Text testID="Anim-modal-text" style={styles.body}>Slid in</Text>
        <NavButton id="Anim-modal-close" label="Close" onPress={() => setSmodal(false)} /></View>
      </Modal>
    </View>
  );
}

function BackScreen({ onBack }: { onBack: () => void }) {
  const [count, setCount] = useState(0);
  const [modal, setModal] = useState(false);
  const [closes, setCloses] = useState(0);
  useEffect(() => {
    const sub = BackHandler.addEventListener('hardwareBackPress', () => {
      setCount((n) => n + 1);
      console.log('[FIXTURE] hardwareBackPress');
      return true; // consumed: stays on this screen
    });
    return () => sub.remove();
  }, []);
  return (
    <View style={styles.screen}>
      <Header title="Back" id="Back-title" onBack={onBack} />
      <Text testID="Back-count" style={styles.body}>back presses {count}</Text>
      <Text testID="Back-modal-closes" style={styles.body}>modal closes {closes}</Text>
      <NavButton id="Back-open-modal" label="Open modal" onPress={() => setModal(true)} />
      <Modal testID="Back-modal" visible={modal} onRequestClose={() => { setModal(false); setCloses((n) => n + 1); }}>
        <View style={styles.screen}>
          <Text testID="Back-modal-text" style={styles.title}>Back modal</Text>
        </View>
      </Modal>
    </View>
  );
}

function PermScreen({ onBack }: { onBack: () => void }) {
  const [res, setRes] = useState('none');
  const ask = async (name: 'notif' | 'camera') => {
    if (Platform.OS !== 'android') { setRes('ios: n/a'); return; }
    const perm = name === 'notif'
      ? (PermissionsAndroid.PERMISSIONS as any).POST_NOTIFICATIONS
      : PermissionsAndroid.PERMISSIONS.CAMERA;
    const r = await PermissionsAndroid.request(perm);
    setRes(`${name}: ${r}`);
    console.log(`[FIXTURE] permission ${name} ${r}`);
  };
  return (
    <View style={styles.screen}>
      <Header title="Permissions" id="Perm-title" onBack={onBack} />
      <NavButton id="Perm-notif" label="Ask notifications" onPress={() => ask('notif')} />
      <NavButton id="Perm-camera" label="Ask camera" onPress={() => ask('camera')} />
      <Text testID="Perm-result" style={styles.body}>{res}</Text>
    </View>
  );
}

// ~250 accessibility-relevant nodes for timing tree reads.
function BigScreen({ onBack }: { onBack: () => void }) {
  return (
    <ScrollView contentContainerStyle={styles.screen}>
      <Header title="Big" id="Big-title" onBack={onBack} />
      {Array.from({ length: 60 }, (_, i) => (
        <View key={i} testID={`Big-card-${i}`} style={styles.card}>
          <Text testID={`Big-card-${i}-title`} style={styles.bold}>Card {i}</Text>
          <Text style={styles.small}>Subtitle for card number {i}</Text>
          <Pressable testID={`Big-card-${i}-action`} accessibilityRole="button" style={styles.chip}>
            <Text style={styles.small}>Open</Text>
          </Pressable>
        </View>
      ))}
    </ScrollView>
  );
}

// Gestures: a pad that tells a tap, a double tap (two presses within 300 ms) and a long
// press apart; a box that reports how far it was dragged and how long the finger rested
// before moving; a scroll view that reports its offset.
function GestScreen({ onBack }: { onBack: () => void }) {
  const [c, setC] = useState({ taps: 0, doubles: 0, longs: 0 });
  const last = useRef(0);
  const onPress = () => {
    const now = Date.now();
    const dbl = now - last.current < 300;
    last.current = dbl ? 0 : now;
    setC((p) => ({ taps: p.taps + 1, doubles: p.doubles + (dbl ? 1 : 0), longs: p.longs }));
  };
  const [drag, setDrag] = useState('none');
  const g = useRef({ t0: 0, moved: 0 });
  const pan = useRef(PanResponder.create({
    onStartShouldSetPanResponder: () => true,
    onMoveShouldSetPanResponder: () => true,
    onPanResponderGrant: () => { g.current = { t0: Date.now(), moved: 0 }; },
    onPanResponderMove: (_e, st) => {
      if (!g.current.moved && Math.hypot(st.dx, st.dy) > 10) g.current.moved = Date.now();
    },
    onPanResponderRelease: (_e, st) => {
      const held = g.current.moved ? g.current.moved - g.current.t0 : Date.now() - g.current.t0;
      setDrag(`dx ${Math.round(st.dx)} dy ${Math.round(st.dy)} held ${held}`);
    },
  })).current;
  const [sy, setSy] = useState(0);
  return (
    <View style={styles.screen}>
      <Header title="Gestures" id="Gest-title" onBack={onBack} />
      <Pressable testID="Gest-pad" accessibilityRole="button" onPress={onPress}
        onLongPress={() => setC((p) => ({ ...p, longs: p.longs + 1 }))} delayLongPress={500} style={styles.pad}>
        <Text style={styles.body}>pad</Text>
      </Pressable>
      <Text testID="Gest-counts" style={styles.small}>{`taps ${c.taps} doubles ${c.doubles} longs ${c.longs}`}</Text>
      <View testID="Gest-drag" style={styles.dragBox} {...pan.panHandlers} />
      <Text testID="Gest-drag-out" style={styles.small}>{`drag ${drag}`}</Text>
      <ScrollView testID="Gest-scroll" style={styles.scrollBox} scrollEventThrottle={16}
        onScroll={(e) => setSy(Math.round(e.nativeEvent.contentOffset.y))}>
        {Array.from({ length: 30 }, (_, i) => <Text key={i} style={styles.body}>{`row ${i}`}</Text>)}
      </ScrollView>
      <Text testID="Gest-scroll-y" style={styles.small}>{`scroll y ${sy}`}</Text>
    </View>
  );
}

export default function App() {
  const [screen, setScreen] = useState<Screen>('home');
  const [reduce, setReduce] = useState('?');
  useEffect(() => {
    Linking.getInitialURL().then((u) => {
      console.log(`[FIXTURE] initial url ${u}`);
      const s = screenFromUrl(u ?? null);
      if (s) setScreen(s);
    });
    const sub = Linking.addEventListener('url', ({ url }) => {
      console.log(`[FIXTURE] deep link ${url}`);
      const s = screenFromUrl(url);
      if (s) setScreen(s);
    });
    AccessibilityInfo.isReduceMotionEnabled().then((b) => setReduce(String(b)));
    return () => sub.remove();
  }, []);
  useEffect(() => {
    console.log(`[FIXTURE] screen ${screen}`);
  }, [screen]);
  const home = () => setScreen('home');
  const win = Dimensions.get('window');
  const scr = Dimensions.get('screen');
  return (
    <View style={styles.root}>
      <StatusBar barStyle="dark-content" />
      {screen === 'home' && (
        <ScrollView contentContainerStyle={styles.screen}>
          <Header title="Fixture Home" id="Home-title" />
          <Text testID="Home-dims" style={styles.small}>
            {`${Platform.OS} win ${win.width.toFixed(1)}x${win.height.toFixed(1)} screen ${scr.width.toFixed(1)}x${scr.height.toFixed(1)} ratio ${PixelRatio.get()} font ${PixelRatio.getFontScale()} reduce ${reduce}`}
          </Text>
          {SCREENS.filter((s) => s !== 'home').map((s) => (
            <NavButton key={s} id={`Home-${s}`} label={s[0].toUpperCase() + s.slice(1)} onPress={() => setScreen(s)} />
          ))}
        </ScrollView>
      )}
      {screen === 'profile' && <ProfileScreen onBack={home} />}
      {screen === 'settings' && <SettingsScreen onBack={home} />}
      {screen === 'badge' && <BadgeScreen onBack={home} />}
      {screen === 'network' && <NetworkScreen onBack={home} />}
      {screen === 'components' && <ComponentsScreen onBack={home} />}
      {screen === 'inputs' && <InputsScreen onBack={home} />}
      {screen === 'list' && <ListScreen onBack={home} />}
      {screen === 'anim' && <AnimScreen onBack={home} />}
      {screen === 'back' && <BackScreen onBack={home} />}
      {screen === 'perm' && <PermScreen onBack={home} />}
      {screen === 'big' && <BigScreen onBack={home} />}
      {screen === 'gest' && <GestScreen onBack={home} />}
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: '#ffffff', paddingTop: 40 },
  screen: { padding: 20, gap: 12 },
  header: { flexDirection: 'row', alignItems: 'center', gap: 16, marginTop: 8 },
  back: { fontSize: 17, color: '#0a58ca' },
  title: { fontSize: 28, fontWeight: '700' },
  body: { fontSize: 17 },
  small: { fontSize: 13 },
  bold: { fontSize: 17, fontWeight: '700' },
  input: { borderWidth: 1, borderColor: '#999', borderRadius: 8, padding: 10, fontSize: 17 },
  row: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
  rowBox: { flexDirection: 'row', gap: 12, padding: 8, backgroundColor: '#eee' },
  navButton: { backgroundColor: '#0a58ca', borderRadius: 10, paddingVertical: 12, alignItems: 'center' },
  navButtonText: { color: '#ffffff', fontSize: 17, fontWeight: '600' },
  badgeWrap: { alignItems: 'center', paddingVertical: 20 },
  pill: { backgroundColor: '#111111', borderRadius: 20, width: 120, height: 40, paddingTop: 2, paddingBottom: 8, justifyContent: 'center', alignItems: 'center' },
  pillText: { color: '#ffffff', fontSize: 16, fontWeight: '700' },
  boxes: { height: 160, position: 'relative' },
  anchorBox: { position: 'absolute', left: 20, top: 0, width: 300, height: 60, backgroundColor: 'rgb(255,0,0)' },
  frameBox: { position: 'absolute', left: 20, top: 66, width: 300, height: 80, backgroundColor: 'rgb(0,255,0)' },
  box: { width: 40, height: 40, backgroundColor: '#d33' },
  pad: { height: 90, backgroundColor: '#e3e8f0', borderRadius: 10, alignItems: 'center', justifyContent: 'center' },
  dragBox: { height: 120, backgroundColor: '#cfe8cf', borderRadius: 10 },
  scrollBox: { height: 150, borderWidth: 1, borderColor: '#999' },
  box2: { width: 40, height: 40, backgroundColor: '#3d3' },
  box3: { width: 40, height: 40, backgroundColor: '#33d' },
  img: { width: 48, height: 48 },
  coverWrap: { height: 40, position: 'relative' },
  cover: { position: 'absolute', left: 0, top: 0, right: 0, bottom: 0, backgroundColor: '#888' },
  hitem: { width: 120, height: 50, marginRight: 8, backgroundColor: '#eef', justifyContent: 'center', alignItems: 'center' },
  modalBack: { flex: 1, backgroundColor: 'rgba(0,0,0,0.4)', justifyContent: 'center', padding: 30 },
  modalCard: { backgroundColor: '#fff', padding: 20, borderRadius: 12, gap: 12 },
  listRow: { height: 56, justifyContent: 'center', borderBottomWidth: 1, borderColor: '#ddd' },
  card: { padding: 10, borderWidth: 1, borderColor: '#ccc', borderRadius: 8, gap: 4 },
  chip: { alignSelf: 'flex-start', paddingHorizontal: 10, paddingVertical: 4, backgroundColor: '#eef', borderRadius: 6 },
});
