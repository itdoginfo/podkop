export function downloadAsTxt(text: string, filename: string) {
  const blob = new Blob([text], { type: 'text/plain;charset=utf-8' });

  const link = document.createElement('a');
  link.href = URL.createObjectURL(blob);

  const safeName = filename.endsWith('.txt') ? filename : `${filename}.txt`;
  link.download = safeName;

  document.body.appendChild(link);
  link.click();

  document.body.removeChild(link);
  URL.revokeObjectURL(link.href);
}
