import { NetShift } from '../../types';

export async function getConfigSections(): Promise<NetShift.ConfigSection[]> {
  return uci.load('netshift').then(() => uci.sections('netshift'));
}
