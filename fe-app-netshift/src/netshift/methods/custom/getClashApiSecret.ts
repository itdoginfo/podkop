import { getConfigSections } from './getConfigSections';

export async function getClashApiSecret() {
  const sections = await getConfigSections();

  const settings = sections.find((section) => section['.type'] === 'settings');

  return settings?.yacd_secret_key || '';
}
