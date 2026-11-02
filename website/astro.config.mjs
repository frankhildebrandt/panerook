import { defineConfig } from 'astro/config';

export default defineConfig({
  site: 'https://frankhildebrandt.github.io',
  base: '/panerook',
  output: 'static',
  trailingSlash: 'always',
});
