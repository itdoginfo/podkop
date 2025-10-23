import { Podkop } from '../../types';

export async function getConfigSections(): Promise<Podkop.ConfigSection[]> {
  return uci.load('podkop').then(() => uci.sections('podkop'));
}
