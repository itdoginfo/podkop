import { PodkopShellMethods } from '../shell';

// Features of the installed sing-box; none when it does not report them
export async function getSingBoxFeatures(): Promise<string[]> {
  const { data, success } = await PodkopShellMethods.getSingBoxFeatures();

  return success && Array.isArray(data) ? data : [];
}
