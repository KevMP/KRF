import {themes as prismThemes} from 'prism-react-renderer';
import type {Config} from '@docusaurus/types';
import type * as Preset from '@docusaurus/preset-classic';

const config: Config = {
  title: "Kevin's Roblox Framework",
  tagline: 'A complete framework for Roblox RPG gameplay',
  favicon: 'img/favicon.ico',

  future: {
    v4: true,
  },

  url: 'https://kevmp.github.io',
  baseUrl: '/roblox-rpg-framework/',

  organizationName: 'KevMP',
  projectName: 'roblox-rpg-framework',

  onBrokenLinks: 'throw',

  i18n: {
    defaultLocale: 'en',
    locales: ['en'],
  },

  presets: [
    [
      'classic',
      {
        docs: {
          sidebarPath: './sidebars.ts',
          routeBasePath: '/',
          editUrl: 'https://github.com/KevMP/roblox-rpg-framework/edit/main/docs-site/',
        },
        blog: false,
        theme: {
          customCss: './src/css/custom.css',
        },
      } satisfies Preset.Options,
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
          position: 'left',
          label: 'Learn KRF',
        },
        {
          to: '/api',
          label: 'API',
          position: 'left',
        },
        {
          href: 'https://github.com/KevMP/roblox-rpg-framework',
          label: 'GitHub',
          position: 'right',
        },
        {
          href: 'https://discord.gg/NEED-TO-MAKE-SERVER',
          label: 'Discord',
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
              label: 'KRF Intro',
              to: '/',
            }
          ],
        },
        {
          title: 'Learn KRF',
          items: [
            {
              label: 'Getting Started',
              to: '/learn/intro',
            },
          ],
        },
        {
          title: 'Community',
          items: [
            {
              label: 'GitHub',
              href: 'https://github.com/KevMP/roblox-rpg-framework',
            },
            {
              label: 'Discord',
              href: 'https://discord.gg/NEED-TO-MAKE-SERVER',
            },
          ],
        },
      ],
    },
    prism: {
      theme: prismThemes.github,
      darkTheme: prismThemes.dracula,
    },
  } satisfies Preset.ThemeConfig,
};

export default config;