/**
 * @format
 */

import 'react-native-get-random-values';
import { AppRegistry } from 'react-native';
import App from './App';
import { runReceiptSyncWork } from './src/sync/receiptBackgroundSync';
import { name as appName } from './app.json';

AppRegistry.registerComponent(appName, () => App);
AppRegistry.registerHeadlessTask('ChallanSeWorkManagerSync', () => async (data) => {
  await runReceiptSyncWork(String(data?.workId ?? ''));
});
