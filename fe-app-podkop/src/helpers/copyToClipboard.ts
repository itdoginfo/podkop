export function copyToClipboard(text: string) {
  const textarea = document.createElement('textarea');
  textarea.value = text;
  document.body.appendChild(textarea);
  textarea.select();
  try {
    document.execCommand('copy');
  } catch (_err) {
    console.error('copyToClipboard - e', _err);
  }
  document.body.removeChild(textarea);
}
