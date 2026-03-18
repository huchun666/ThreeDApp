/**
 * iOS: Native SceneKit GLB + offscreen snapshot → RN Image
 */

import React, { useRef, useState } from 'react';
import {
  findNodeHandle,
  Image,
  NativeModules,
  Platform,
  Pressable,
  ScrollView,
  StatusBar,
  StyleSheet,
  Text,
  useColorScheme,
  View,
  requireNativeComponent,
} from 'react-native';
import { SafeAreaProvider, useSafeAreaInsets } from 'react-native-safe-area-context';
import { generateInterlacedImage } from './src/native/interlaceImage';

const GLBSceneView =
  Platform.OS === 'ios'
    ? requireNativeComponent<{ collapsable?: boolean }>('GLBSceneView')
    : View;

const { GLBSnapshot } = NativeModules as {
  GLBSnapshot?: {
    capture: (tag: number) => Promise<string>;
    captureMulti?: (tag: number, count: number) => Promise<string[]>;
    captureMultiToFiles?: (tag: number, count: number) => Promise<string[]>;
  };
};

function App() {
  const isDark = useColorScheme() === 'dark';

  return (
    <SafeAreaProvider>
      <StatusBar barStyle={isDark ? 'light-content' : 'dark-content'} />
      <AppContent />
    </SafeAreaProvider>
  );
}

function AppContent() {
  const insets = useSafeAreaInsets();
  const glbRef = useRef<React.ComponentRef<typeof GLBSceneView>>(null);
  const [uri, setUri] = useState<string | null>(null);
  const [multiUris, setMultiUris] = useState<string[]>([]);
  const [interlacedOutputPath, setInterlacedOutputPath] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  const onCapture = async () => {
    if (Platform.OS !== 'ios' || !GLBSnapshot?.capture) {
      setErr('仅 iOS 支持');
      return;
    }
    const tag = findNodeHandle(glbRef.current);
    if (tag == null) {
      setErr('无法获取原生节点，请稍后重试');
      return;
    }
    setBusy(true);
    setErr(null);
    try {
      const b64 = await GLBSnapshot.capture(tag);
      setUri(`data:image/jpeg;base64,${b64}`);
      setMultiUris([]);
    } catch (e: unknown) {
      setErr(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  const onCaptureMulti = async () => {
    if (Platform.OS !== 'ios' || !GLBSnapshot?.captureMulti) {
      setErr('当前构建未开启多机位接口');
      return;
    }
    const tag = findNodeHandle(glbRef.current);
    if (tag == null) {
      setErr('无法获取原生节点，请稍后重试');
      return;
    }
    setBusy(true);
    setErr(null);
    try {
      const list = await GLBSnapshot.captureMulti(tag, 9);
      setMultiUris(list.map(b64 => `data:image/jpeg;base64,${b64}`));
      if (list.length > 0) {
        setUri(`data:image/jpeg;base64,${list[0]}`);
      }
    } catch (e: unknown) {
      setErr(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  const onCaptureMultiInterlace = async () => {
    if (Platform.OS !== 'ios' || !GLBSnapshot?.captureMultiToFiles) {
      setErr('当前构建未开启多机位落盘接口');
      return;
    }
    const tag = findNodeHandle(glbRef.current);
    if (tag == null) {
      setErr('无法获取原生节点，请稍后重试');
      return;
    }
    setBusy(true);
    setErr(null);
    try {
      // 1) 多机位截图 -> 写入临时目录（返回本地路径）
      const paths = await GLBSnapshot.captureMultiToFiles(tag, 9);

      // 2) 生成交织图（按列）
      const outputPath = await generateInterlacedImage(paths);
      setInterlacedOutputPath(outputPath);

      // 3) 预览：也把多机位缩略图展示出来（便于确认输入）
      setMultiUris(paths.map(p => `file://${p}`));
      setUri(paths.length > 0 ? `file://${paths[0]}` : null);
    } catch (e: unknown) {
      setErr(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  if (Platform.OS !== 'ios') {
    return (
      <View style={[styles.center, { paddingTop: insets.top }]}>
        <Text style={styles.hint}>请在 iOS 模拟器或真机上运行以查看 GLB 与截图。</Text>
      </View>
    );
  }

  return (
    <ScrollView
      style={styles.scroll}
      contentContainerStyle={[styles.scrollContent, { paddingBottom: insets.bottom + 24 }]}>
      <View style={{ height: insets.top }} />
      {/* <Text style={styles.title}>GLB 原生预览（SceneKit）</Text> */}
      <View style={styles.glbWrap}>
        <GLBSceneView
          ref={glbRef}
          style={StyleSheet.absoluteFill}
          collapsable={false}
        />
      </View>
      <Pressable
        style={[styles.btnSecondary, busy && styles.btnDisabled]}
        onPress={onCaptureMulti}
        disabled={busy}>
        <Text style={styles.btnText}>多机位截图 × 9</Text>
      </Pressable>
      <Pressable
        style={[styles.btnSecondary, busy && styles.btnDisabled]}
        onPress={onCaptureMultiInterlace}
        disabled={busy}>
        <Text style={styles.btnText}>{busy ? '处理中…' : '多机位截图 → 生成交织图'}</Text>
      </Pressable>
      <Pressable
        style={[styles.btn, busy && styles.btnDisabled]}
        onPress={onCapture}
        disabled={busy}>
        <Text style={styles.btnText}>{busy ? '截图中…' : '单机位截图'}</Text>
      </Pressable>
      {interlacedOutputPath ? (
        <>
          <Text style={styles.subtitle}>交织结果（本地缓存 PNG）</Text>
          <Text style={styles.pathText}>{interlacedOutputPath}</Text>
          <Image
            source={{ uri: `file://${interlacedOutputPath}` }}
            style={styles.preview}
            resizeMode="contain"
          />
        </>
      ) : null}

      {err ? <Text style={styles.error}>{err}</Text> : null}
      {multiUris.length > 0 ? (
        <>
          <Text style={styles.subtitle}>多机位预览（{multiUris.length} 张）</Text>
          <View style={styles.multiRow}>
            {multiUris.map((u, idx) => (
              <Image
                key={idx}
                source={{ uri: u }}
                style={styles.multiThumb}
                resizeMode="cover"
              />
            ))}
          </View>
        </>
      ) : null}
      {uri ? (
        <>
          <Text style={styles.subtitle}>单机位预览（本机展示，未上传）</Text>
          <Image source={{ uri }} style={styles.preview} resizeMode="contain" />
        </>
      ) : null}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  scroll: { flex: 1, backgroundColor: '#111' },
  scrollContent: { paddingHorizontal: 16 },
  center: { flex: 1, justifyContent: 'center', padding: 24, backgroundColor: '#111' },
  hint: { color: '#aaa', textAlign: 'center', fontSize: 16 },
  title: { color: '#fff', fontSize: 18, fontWeight: '600', marginBottom: 12 },
  subtitle: { color: '#ccc', marginTop: 20, marginBottom: 8 },
  glbWrap: {
    height: 420,
    borderRadius: 12,
    overflow: 'hidden',
    backgroundColor: '#fff',
  },
  btn: {
    marginTop: 16,
    backgroundColor: '#0a84ff',
    paddingVertical: 14,
    borderRadius: 10,
    alignItems: 'center',
  },
  btnDisabled: { opacity: 0.6 },
  btnText: { color: '#fff', fontSize: 16, fontWeight: '600' },
  error: { color: '#ff6b6b', marginTop: 12 },
  btnSecondary: {
    marginTop: 10,
    backgroundColor: '#333',
    paddingVertical: 12,
    borderRadius: 10,
    alignItems: 'center',
  },
  pathText: {
    color: '#8ab4ff',
    fontSize: 12,
    marginBottom: 8,
  },
  preview: {
    width: '100%',
    height: 280,
    backgroundColor: '#222',
    borderRadius: 12,
  },
  multiRow: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    marginTop: 12,
    marginHorizontal: -4,
  },
  multiThumb: {
    width: 100,
    height: 100,
    marginHorizontal: 4,
    marginBottom: 8,
    borderRadius: 8,
    backgroundColor: '#222',
    borderWidth: 1,
    borderColor: '#555',
  },
});

export default App;
