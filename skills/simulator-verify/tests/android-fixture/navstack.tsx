// Optional react-navigation variant of the fixture: a native stack with one push, to
// time a stack transition against the element-tree reads. Registered instead of App
// (index.js: `import NavApp from './navstack'`) in an app that also has
// @react-navigation/native, @react-navigation/native-stack and react-native-screens.
import React from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';
import { NavigationContainer } from '@react-navigation/native';
import { createNativeStackNavigator } from '@react-navigation/native-stack';

type Params = { NavHome: undefined; NavDetail: undefined };
const Stack = createNativeStackNavigator<Params>();

function Button({ id, label, onPress }: { id: string; label: string; onPress: () => void }) {
  return (
    <Pressable testID={id} accessibilityRole="button" onPress={onPress} style={styles.button}>
      <Text style={styles.label}>{label}</Text>
    </Pressable>
  );
}

function NavHome({ navigation }: any) {
  return (
    <View style={styles.screen}>
      <Text testID="NavHome-title" style={styles.title}>Stack home</Text>
      <Button id="Nav-push" label="Push detail" onPress={() => navigation.push('NavDetail')} />
    </View>
  );
}

function NavDetail({ navigation }: any) {
  return (
    <View style={styles.screen}>
      <Text testID="NavDetail-text" style={styles.title}>Pushed detail</Text>
      <Button id="Nav-pop" label="Back" onPress={() => navigation.goBack()} />
    </View>
  );
}

export default function NavApp() {
  return (
    <NavigationContainer>
      <Stack.Navigator>
        <Stack.Screen name="NavHome" component={NavHome} />
        <Stack.Screen name="NavDetail" component={NavDetail} options={{ animation: 'slide_from_right' }} />
      </Stack.Navigator>
    </NavigationContainer>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, padding: 20, backgroundColor: '#fff' },
  title: { fontSize: 22, marginBottom: 16, color: '#111' },
  button: { padding: 12, marginVertical: 6, backgroundColor: '#e3e8f0', borderRadius: 6 },
  label: { fontSize: 16, color: '#111' },
});
