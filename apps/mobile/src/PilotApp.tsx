import React, { useCallback, useEffect, useState } from 'react';
import { ActivityIndicator, Linking, StatusBar, StyleSheet, Text, View } from 'react-native';
import { SafeAreaProvider } from 'react-native-safe-area-context';
import ReceiveMaterialApp from './ReceiveMaterialApp';
import {
  exchangeEnrollmentCode,
  fetchPilotConfiguration,
  getCachedPilotConfiguration,
  getEnrollmentCredential,
  parseEnrollmentLink,
  type PilotConfiguration,
} from './config/deviceEnrollment';

function EnrollmentScreen({ onConfigured }: { onConfigured: (configuration: PilotConfiguration) => void }) {
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState('Ask the controller to show the one-time enrollment QR.');

  const consumeLink = useCallback(async (url: string | null) => {
    if (!url) return;
    const enrollment = parseEnrollmentLink(url);
    if (!enrollment) return;
    setBusy(true);
    setMessage('Connecting this device…');
    try {
      const credential = await exchangeEnrollmentCode(enrollment);
      onConfigured(await fetchPilotConfiguration(credential));
    } catch (caught) {
      setMessage(caught instanceof Error ? caught.message : 'Enrollment failed. Ask for a new QR code.');
      setBusy(false);
    }
  }, [onConfigured]);

  useEffect(() => {
    void Linking.getInitialURL().then(consumeLink);
    const subscription = Linking.addEventListener('url', ({ url }) => void consumeLink(url));
    return () => subscription.remove();
  }, [consumeLink]);

  return <View style={styles.enrollmentScreen}>
    <StatusBar backgroundColor="#000" barStyle="light-content" />
    <View style={styles.scanMark}><View /><View /><View /><View /></View>
    <Text style={styles.title}>Scan setup QR</Text>
    <Text style={styles.hindi}>सेटअप QR स्कैन करें</Text>
    <Text style={styles.message}>{message}</Text>
    {busy ? <ActivityIndicator size="large" color="#f59e0b" /> : <Text style={styles.instruction}>Open the phone Camera and point it at the QR.</Text>}
  </View>;
}

export default function PilotApp() {
  const [configuration, setConfiguration] = useState<PilotConfiguration | null>(null);
  const [ready, setReady] = useState(false);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const credential = await getEnrollmentCredential();
      if (!credential) return null;
      try { return await fetchPilotConfiguration(credential); } catch { return getCachedPilotConfiguration(); }
    })().then((loaded) => {
      if (!cancelled) { setConfiguration(loaded); setReady(true); }
    }).catch(() => { if (!cancelled) setReady(true); });
    return () => { cancelled = true; };
  }, []);

  if (!ready) return <View style={styles.loading}><ActivityIndicator size="large" color="#f59e0b" /></View>;
  return <SafeAreaProvider>{configuration ? <ReceiveMaterialApp configuration={configuration} /> : <EnrollmentScreen onConfigured={setConfiguration} />}</SafeAreaProvider>;
}

const styles = StyleSheet.create({
  loading: { alignItems: 'center', backgroundColor: '#000', flex: 1, justifyContent: 'center' },
  enrollmentScreen: { alignItems: 'center', backgroundColor: '#000', flex: 1, justifyContent: 'center', padding: 28 },
  scanMark: { borderColor: '#f59e0b', borderRadius: 22, borderWidth: 8, height: 150, marginBottom: 34, width: 150 },
  title: { color: '#fff', fontSize: 34, fontWeight: '900' },
  hindi: { color: '#f59e0b', fontSize: 22, fontWeight: '800', marginTop: 4 },
  message: { color: '#aeb9c8', fontSize: 16, lineHeight: 24, marginVertical: 24, maxWidth: 310, textAlign: 'center' },
  instruction: { color: '#fff', fontSize: 17, fontWeight: '800', textAlign: 'center' },
});
