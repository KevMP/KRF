import {themes as prismThemes} from 'prism-react-renderer';
import type {Config} from '@docusaurus/types';
import type * as Preset from '@docusaurus/preset-classic';

const config: Config = {
  title: "Kevin's Roblox Framework",
  tagline: 'A server-authoritative RPG gameplay runtime for Roblox',
  favicon: 'img/favicon.ico',

  future: {
    v4: true,
  },

  url: 'https://kevmp.github.io',
  baseUrl: '/KRF/',

  organizationName: 'KevMP',
  projectName: 'KRF',

  onBrokenLinks: 'throw',

  i18n: {
    defaultLocale: 'en',
    locales: ['en'],
  },

  presets: [
    [
      'classic',
      {
        docs: false,
        blog: false,
        theme: {
          customCss: './src/css/custom.css',
        },
      } satisfies Preset.Options,
    ],
  ],

  plugins: [
    [
      '@docusaurus/plugin-content-docs',
      {
        path: 'docs/documentation',
        routeBasePath: '/',
        sidebarPath: './sidebars.ts',
        editUrl: 'https://github.com/KevMP/KRF/edit/main/docs-site/',
      },
    ],
    [
      '@docusaurus/plugin-content-docs',
      {
        id: 'learn',
        path: 'docs/learn',
        routeBasePath: 'learn',
        sidebarPath: './sidebarsLearn.ts',
        editUrl: 'https://github.com/KevMP/KRF/edit/main/docs-site/',
      },
    ],
    [
      '@docusaurus/plugin-content-docs',
      {
        id: 'api',
        path: 'docs/api',
        routeBasePath: 'api',
        sidebarPath: './sidebarsApi.ts',
        editUrl: 'https://github.com/KevMP/KRF/edit/main/docs-site/',
      },
    ],
  ],

  themeConfig: {
    colorMode: {
      respectPrefersColorScheme: true,
    },
    navbar: {
      title: 'KRF',
      // logo: {
      //   alt: 'KRF Logo',
      //   src: 'img/logo.svg',
      // },
      items: [
        {
          type: 'docSidebar',
          sidebarId: 'docsSidebar',
          position: 'left',
          label: 'Docs',
        },
        {
          type: 'docSidebar',
          sidebarId: 'learnSidebar',
          docsPluginId: 'learn',
          position: 'left',
          label: 'Learn KRF',
        },
        {
          type: 'docSidebar',
          sidebarId: 'apiSidebar',
          docsPluginId: 'api',
          position: 'left',
          label: 'API',
        },
        {
          href: 'https://github.com/KevMP/KRF',
          label: 'GitHub',
          position: 'right',
        },
      ],
    },
    footer: {
      style: 'dark',
      links: [
        {
          title: 'Docs',
          items: [
            {
              label: 'KRF Overview',
              to: '/',
            }
          ],
        },
        {
          title: 'Learn KRF',
          items: [
            {
              label: 'Runtime Foundations',
              to: '/learn/intro',
            },
          ],
        },
        {
          title: 'API',
          items: [
            {
              label: 'Actor Runtime',
              to: '/api/Actor/actor-runtime',
            },
          ],
        },
        {
          title: 'Community',
          items: [
            {
              label: 'GitHub',
              href: 'https://github.com/KevMP/KRF',
            },
          ],
        },
      ],
    },
    prism: {
      theme: prismThemes.github,
      darkTheme: prismThemes.dracula,
      additionalLanguages: ['lua'],
    },
  } satisfies Preset.ThemeConfig,
};

export default config;
