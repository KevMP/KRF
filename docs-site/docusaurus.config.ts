import {themes as prismThemes} from 'prism-react-renderer';
import type {Config} from '@docusaurus/types';
import type * as Preset from '@docusaurus/preset-classic';

const deploymentPath = process.env.KRF_DOCS_BASE_PATH?.replace(/^\/+|\/+$/g, '');

const config: Config = {
  title: "Kevin's Roblox Framework",
  tagline: 'A server-authoritative RPG gameplay runtime for Roblox',

  future: {
    v4: true,
  },

  url: process.env.KRF_DOCS_ORIGIN || 'https://kevmp.github.io',
  baseUrl: deploymentPath ? `/${deploymentPath}/` : '/',

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
        id: 'reference',
        path: 'docs/reference',
        routeBasePath: 'reference',
        sidebarPath: './sidebarsReference.ts',
      },
    ],
    [
      '@docusaurus/plugin-content-docs',
      {
        id: 'tutorial',
        path: 'docs/tutorial',
        routeBasePath: 'tutorial',
        sidebarPath: './sidebarsTutorial.ts',
      },
    ],
  ],

  themeConfig: {
    colorMode: {
      respectPrefersColorScheme: true,
    },
    navbar: {
      title: 'KRF',
      items: [
        {
          type: 'doc',
          docId: 'index',
          docsPluginId: 'reference',
          position: 'left',
          label: 'Reference',
        },
        {
          type: 'doc',
          docId: 'index',
          docsPluginId: 'tutorial',
          position: 'left',
          label: 'Tutorial',
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
          title: 'Reference',
          items: [
            {
              label: 'Systems and APIs',
              to: '/reference/',
            }
          ],
        },
        {
          title: 'Tutorial',
          items: [
            {
              label: 'Build a cultivation game',
              to: '/tutorial/',
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
