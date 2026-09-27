// Vite/Vitest `?raw` imports: the file's text as a string. Used by tests that
// check the frontend against backend shell constants.
declare module '*?raw' {
  const content: string;
  export default content;
}
