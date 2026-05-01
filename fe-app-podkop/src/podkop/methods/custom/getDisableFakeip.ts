import { getConfigSections } from './getConfigSections';

export async function getDisableFakeip(): Promise<boolean> {
  const sections = await getConfigSections();
  const settings = sections.find((section) => section['.type'] === 'settings');
  return settings?.disable_fakeip === '1';
}
