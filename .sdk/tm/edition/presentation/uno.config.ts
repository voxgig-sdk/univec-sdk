// Slidev 52.19.1 loads this list as a module namespace in development.
// Supply its default export explicitly so controls retain layout and auto-hide.
import Path from 'node:path'
import { createRequire } from 'node:module'
import slidevTokens from '@slidev/client/.generated/unocss-tokens.ts'

const clientRoot = Path.dirname(createRequire(import.meta.url).resolve('@slidev/client/package.json'))

export default {
  safelist: slidevTokens,
  // Include built-in icons and dynamic UI classes before the browser loads them.
  content: { filesystem: [Path.join(clientRoot, '**/*.{vue,ts}')] },
}
