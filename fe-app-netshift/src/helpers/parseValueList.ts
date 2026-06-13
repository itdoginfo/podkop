export function parseValueList(value: string): string[] {
  return value
    .split(/\n/) // Split to array by newline separator
    .map((line) => line.split('//')[0]) // Remove comments
    .join(' ') // Build clean string
    .split(/[,\s]+/) // Split to array by comma and space
    .map((s) => s.trim()) // Remove extra spaces
    .filter(Boolean); // Leave nonempty items
}
